import Foundation
import IOKit.hid
import IOKit.hidsystem

private func hidDeviceMatched(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    let monitor = Unmanaged<HIDRemoteMonitor>.fromOpaque(context).takeUnretainedValue()
    // The manager is scheduled on the main run loop, so this fires on the main
    // thread: run it directly (no redundant re-dispatch) so match, removal, and the
    // present-device generation update in true IOHID delivery order. The device
    // generation is therefore live before any of that device's input reports are
    // snapshotted, so a first report can never be dropped for racing the match.
    monitor.deviceDidMatch(result: result, device: device)
}

private func hidDeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    let monitor = Unmanaged<HIDRemoteMonitor>.fromOpaque(context).takeUnretainedValue()
    // Runs on the main thread (see the match callback). Handling removal directly
    // invalidates the device generation before any still-queued input-report async
    // block executes, so a late report is rejected and cannot follow the balancing
    // `.up` with a stale `.down`.
    monitor.deviceDidRemove(device: device)
}

private func hidInputReport(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard let context, result == kIOReturnSuccess, reportLength > 0 else { return }
    let monitor = Unmanaged<HIDRemoteMonitor>.fromOpaque(context).takeUnretainedValue()
    // The manager is scheduled on the main run loop, so this callback already runs
    // on the main thread: snapshot the present-device generation here, then hand
    // the report to the same ordered main-queue domain as match/removal. Reports
    // captured with no present device (generation nil) are dropped, and any report
    // whose generation has since been invalidated by a removal is rejected on
    // execution — so a late report can never re-open the key after a balanced up.
    guard let generation = monitor.currentReportGeneration else { return }
    let data = Data(bytes: report, count: reportLength)
    DispatchQueue.main.async {
        monitor.handleReport(reportID: reportID, data: data, generation: generation)
    }
}

final class HIDRemoteMonitor {
    private let settings: AppSettings
    private let eventSuppressor = KeyboardEventSuppressor()
    private var manager: IOHIDManager?
    private var lifecycle = RemoteDeviceLifecycle()
    private var activeDevice: IOHIDDevice?
    private var activeDeviceIsSeized = false
    private var activeUsages = Set<UInt16>()
    private var repeatTimers: [UInt16: DispatchSourceTimer] = [:]
    private var permissionMonitor: DispatchSourceTimer?
    private var voiceKeyIsDown = false
    private var reconfiguring = false
    private var reportedReading = false
    /// Runtime action gate. When true (bridge runtime disabled) the monitor keeps
    /// reading the device and still parses the voice-key edge (so the double-click
    /// detector can restore the bridge), but injects no keyboard/mouse/system
    /// actions and runs no repeats. Independent of `customMappingEnabled`, which
    /// governs whether the monitor reads at all.
    private var actionsSuppressed = false
    private(set) var status = "按键映射未启用"
    var onStatus: ((String) -> Void)?
    /// Emits the RC003 microphone (F5) key edge so the local-mic arbiter has a
    /// reliable remote-source pre-marker while custom mapping is ON (this monitor
    /// already reads the device in that case). Never consumes or alters keys.
    var onVoiceKeyEdge: ((RemoteEventEdge) -> Void)?
    /// Fired SYNCHRONOUSLY, on the main run loop, immediately BEFORE every forced
    /// balancing `.up` and on every adopted-device generation change — even when
    /// reader health does not flip (e.g. a present-device removal keeps the watcher
    /// healthy). The coordinator resets only the double-click detector here so a
    /// synthetic `.up` cannot complete an in-flight double-click; the balancing
    /// `.up` that follows still reaches the local-mic arbiter.
    var onGestureInvalidate: (() -> Void)?
    /// Fired on the main run loop whenever this monitor starts or stops actually
    /// reading the RC003 device, so the coordinator can re-select the single F5
    /// reader (HID monitor vs. standalone fallback) by real health instead of the
    /// `customMappingEnabled` checkbox.
    var onReaderHealthChange: (() -> Void)?

    /// Whether the HID pipeline is a healthy F5 reader: the manager is open, so it
    /// watches the current AND all future RC003 devices (Apple `IOHIDManagerOpen`
    /// semantics). This is the authoritative reader-health signal used to pick the
    /// single F5 reader. It is true even when no RC003 is present right now (a
    /// healthy watcher — a missing remote must not disable the physical-Fn path).
    /// It is false only when the pipeline is closed: custom mapping off, a
    /// permission gate blocked `start()` (e.g. first install without
    /// Accessibility), the HID open failed, a matched device could not be opened
    /// (fail-close), or a runtime revocation stopped the monitor. A successful
    /// device match and a device removal do NOT flip it — the open manager stays a
    /// healthy watcher across connect/disconnect.
    var isReadingRemoteKeys: Bool { lifecycle.pipelineReady }

    /// Whether the RC003 is currently being read exclusively (seized). Only then
    /// can the disabled bridge fully suppress ordinary keys; otherwise the UI must
    /// honestly warn that native key behaviour may remain.
    var isExclusivelyReading: Bool { activeDevice != nil && activeDeviceIsSeized }

    /// The present-device generation an input-report callback tags its report with,
    /// or `nil` when no device is present (so the report is dropped).
    fileprivate var currentReportGeneration: UInt64? { lifecycle.activeGeneration }

    /// Toggles the runtime action gate. Suppressing immediately cancels any active
    /// repeat and drops held-usage state so nothing is left injected; the monitor
    /// keeps reading and still emits the voice-key edge. Un-suppressing resumes
    /// normal mapping on the next report.
    func setActionsSuppressed(_ suppressed: Bool) {
        guard suppressed != actionsSuppressed else { return }
        actionsSuppressed = suppressed
        guard suppressed else { return }
        repeatTimers.values.forEach { $0.cancel() }
        repeatTimers.removeAll()
        // Forget held usages so a later release does not try to re-arm the
        // suppressor, and so no repeat can resume. Injected key/system events are
        // atomic down+up pairs, so there is no held synthetic key to release.
        activeUsages.removeAll()
        AppLogger.shared.write("HID ACTIONS suppressed")
    }

    init(settings: AppSettings) {
        self.settings = settings
    }

    static var inputMonitoringAccess: IOHIDAccessType {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    }

    static var isInputMonitoringGranted: Bool {
        inputMonitoringAccess == kIOHIDAccessTypeGranted
    }

    @discardableResult
    static func requestInputMonitoringAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func start() {
        // Suppress health notifications from the teardown below so a restart does
        // not transiently flap the reader selection; the deferred sync reports the
        // single final state (reading or not) to the coordinator instead.
        reconfiguring = true
        stop()
        defer {
            reconfiguring = false
            syncReaderHealth()
        }
        guard settings.customMappingEnabled else {
            updateStatus("按键由 macOS 原生处理")
            return
        }
        let inputGranted = Self.isInputMonitoringGranted
        let accessibilityGranted = KeyboardInjector.isAccessibilityTrusted
        AppLogger.shared.write(
            "HID PERMISSIONS input=\(inputGranted) accessibility=\(accessibilityGranted)"
        )
        guard HIDPermissionGate.canMonitor(
            mappingEnabled: settings.customMappingEnabled,
            inputMonitoringGranted: inputGranted,
            accessibilityGranted: accessibilityGranted
        ) else {
            if !inputGranted {
                updateStatus("需要输入监控权限；返回/Delete 等自定义动作不会生效")
            } else {
                updateStatus("需要辅助功能权限；返回/Delete 等自定义动作不会生效")
            }
            return
        }

        let suppressionReady = eventSuppressor.start()
        AppLogger.shared.write("HID FILTER ready=\(suppressionReady)")

        guard let hidIdentity = VoiceBridgeDeviceProfiles.xiaomiRC003.hidIdentity else {
            eventSuppressor.stop()
            updateStatus("RC003 设备配置缺少 HID 标识")
            return
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [
            kIOHIDVendorIDKey as String: hidIdentity.vendorID,
            kIOHIDProductIDKey as String: hidIdentity.productID,
        ] as CFDictionary
        IOHIDManagerSetDeviceMatching(manager, matching)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, hidDeviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, hidDeviceRemoved, context)
        IOHIDManagerRegisterInputReportCallback(manager, hidInputReport, context)
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            eventSuppressor.stop()
            updateStatus("无法读取遥控器（错误 \(result)）")
            return
        }
        self.manager = manager
        // Pipeline open: a healthy watcher for the current and all future RC003
        // devices, even before any device matches.
        lifecycle.openPipeline()
        startPermissionMonitor()
        updateStatus("等待 RC003 按键设备")
        AppLogger.shared.write("HID START mode=adaptive")
    }

    func stop() {
        permissionMonitor?.cancel()
        permissionMonitor = nil
        repeatTimers.values.forEach { $0.cancel() }
        repeatTimers.removeAll()
        activeUsages.removeAll()
        forceReleaseVoiceKey()
        eventSuppressor.stop()
        if let activeDevice {
            IOHIDDeviceClose(activeDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            self.activeDevice = nil
            activeDeviceIsSeized = false
        }
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
        }
        // Pipeline closed: no watcher, no present device, no live generation.
        lifecycle.closePipeline()
        syncReaderHealth()
    }

    /// Notifies the coordinator only when the reading state actually flips, so a
    /// no-op stop or a mid-restart teardown does not churn the reader selection.
    private func syncReaderHealth() {
        guard !reconfiguring else { return }
        let reading = isReadingRemoteKeys
        guard reading != reportedReading else { return }
        reportedReading = reading
        onReaderHealthChange?()
    }

    fileprivate func deviceDidMatch(result: IOReturn, device: IOHIDDevice) {
        // Ignore a stale match after the pipeline closed, or a second match while
        // a device is already owned under a live generation.
        guard manager != nil, !lifecycle.devicePresent else { return }

        var openSucceeded = false
        var seized = false
        if result == kIOReturnSuccess {
            let seizeResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            if seizeResult == kIOReturnSuccess {
                openSucceeded = true
                seized = true
            } else {
                let monitorResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
                if monitorResult == kIOReturnSuccess {
                    openSucceeded = true
                } else {
                    AppLogger.shared.write(
                        "HID DEVICE OPEN FAILED seize=\(seizeResult) monitor=\(monitorResult)"
                    )
                }
            }
        } else {
            AppLogger.shared.write("HID DEVICE MATCH FAILED result=\(result)")
        }

        switch lifecycle.matched(openSucceeded: openSucceeded) {
        case .ignored:
            return
        case .unreadable:
            // The target device is present but not readable. Do NOT keep claiming
            // the reader is healthy: fail the pipeline closed so reader health
            // flips and the coordinator falls back to the standalone reader (or
            // fails closed when neither reader is available). This handler runs
            // inside the IOHID matching callback, so closing the manager here would
            // tear it down mid-callback — defer the fail-close to the next main-queue
            // turn.
            updateStatus("无法读取 RC003（错误 \(result)）")
            DispatchQueue.main.async { [weak self] in self?.failReaderClosed(result: result) }
            return
        case .present:
            activeDevice = device
            activeDeviceIsSeized = seized
            // A freshly adopted device is a new generation: drop any in-flight
            // double-click so a gesture straddling a reconnect cannot be completed
            // by edges from two different device generations.
            onGestureInvalidate?()
            if seized {
                updateStatus("RC003 按键映射已连接（独占模式）")
                AppLogger.shared.write("HID CONNECTED mode=seized")
            } else {
                let suffix = eventSuppressor.isRunning ? "兼容模式" : "兼容模式；系统原动作可能保留"
                updateStatus("RC003 按键映射已连接（\(suffix)）")
                AppLogger.shared.write("HID CONNECTED mode=monitored")
            }
            // A successful match keeps the (already-open) pipeline healthy, so this
            // is a no-op flip; call it for consistency with the health model.
            syncReaderHealth()
        }
    }

    fileprivate func deviceDidRemove(device: IOHIDDevice) {
        guard let activeDevice, CFEqual(activeDevice, device) else { return }
        // Invalidate the device generation FIRST so any late/queued input report
        // tagged with it is dropped, THEN force-release: this invalidates the
        // double-click gesture (even when no key is held, since this is a generation
        // change that does not flip reader health) and, if a voice key is held,
        // balances it with an `.up` that can no longer be followed by a stale `.down`.
        _ = lifecycle.removed()
        IOHIDDeviceClose(activeDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        self.activeDevice = nil
        activeDeviceIsSeized = false
        activeUsages.removeAll()
        forceReleaseVoiceKey()
        repeatTimers.values.forEach { $0.cancel() }
        repeatTimers.removeAll()
        updateStatus("RC003 按键设备已断开")
        AppLogger.shared.write("HID DISCONNECTED")
        // The manager stays open and keeps watching for the RC003 to return, so
        // reader health is unchanged (a healthy watcher with no device present).
        syncReaderHealth()
    }

    fileprivate func handleReport(reportID: UInt32, data: Data, generation: UInt64) {
        guard manager != nil, settings.customMappingEnabled else { return }
        // Reject a report whose device has since been removed or superseded: its
        // generation is no longer the present one. This is what stops a late report
        // from re-arming a key after a removal already balanced it with an `.up`.
        guard lifecycle.accepts(generation: generation) else { return }
        guard runtimePermissionsAreValid() else {
            releaseForRevokedPermissions()
            return
        }
        guard let usages = RemoteHIDReportParser.usages(reportID: reportID, data: data) else {
            return
        }
        let pressed = usages.subtracting(activeUsages)
        let released = activeUsages.subtracting(usages)
        activeUsages = usages

        // Always parse and emit the voice-key edge, even when actions are
        // suppressed: the double-click detector needs it to restore the bridge.
        let voiceKeyUsage = RemoteVoiceFunctionMappingPolicy.remoteVoiceKeyUsage
        if pressed.contains(voiceKeyUsage), !voiceKeyIsDown {
            voiceKeyIsDown = true
            onVoiceKeyEdge?(.down)
        } else if released.contains(voiceKeyUsage), voiceKeyIsDown {
            voiceKeyIsDown = false
            onVoiceKeyEdge?(.up)
        }

        // Bridge runtime disabled: the edge above still flows, but inject no
        // ordinary key/mouse/system action and start no repeat.
        guard !actionsSuppressed else { return }

        for usage in pressed.sorted() {
            guard let button = RemoteButton.usageMap[usage] else { continue }
            let action = settings.action(for: button)
            if !activeDeviceIsSeized {
                eventSuppressor.arm(button: button, edge: .down)
            }
            if !KeyboardInjector.send(action) {
                stop()
                updateStatus("辅助功能权限已失效；已释放遥控器")
                return
            }
            startRepeatIfNeeded(usage: usage, button: button, action: action)
            AppLogger.shared.write("HID BUTTON down=\(button.rawValue) action=\(action.rawValue)")
        }

        for usage in released {
            if !activeDeviceIsSeized, let button = RemoteButton.usageMap[usage] {
                eventSuppressor.arm(button: button, edge: .up)
            }
            repeatTimers.removeValue(forKey: usage)?.cancel()
        }
    }

    private func startRepeatIfNeeded(
        usage: UInt16,
        button: RemoteButton,
        action: ButtonAction
    ) {
        let repeatable: Set<RemoteButton> = [
            .up, .down, .left, .right, .back, .volumeUp, .volumeDown,
        ]
        guard repeatable.contains(button), action != .disabled else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval: DispatchTimeInterval = button == .back ? .milliseconds(50) : .milliseconds(100)
        timer.schedule(deadline: .now() + .milliseconds(350), repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, self.activeUsages.contains(usage) else { return }
            guard self.runtimePermissionsAreValid() else {
                self.releaseForRevokedPermissions()
                return
            }
            if !self.activeDeviceIsSeized {
                self.eventSuppressor.arm(button: button, edge: .down)
            }
            if !KeyboardInjector.send(action) {
                self.releaseForRevokedPermissions()
            }
        }
        repeatTimers[usage] = timer
        timer.resume()
    }

    /// Forced (non-report) voice-key release: stop, device removal, permission
    /// revoke, or fail-close. Drives the shared ordering contract so the gesture is
    /// invalidated FIRST (always), then — only if the key is currently held — a
    /// balancing `.up` is emitted. A genuine key-up parsed from a report never comes
    /// through here, so a real second tap still toggles.
    private func forceReleaseVoiceKey() {
        for effect in RemoteVoiceKeyForcedRelease.effects(keyHeld: voiceKeyIsDown) {
            switch effect {
            case .invalidateGesture:
                onGestureInvalidate?()
            case .balancingUp:
                voiceKeyIsDown = false
                onVoiceKeyEdge?(.up)
            }
        }
    }

    private func runtimePermissionsAreValid() -> Bool {
        Self.inputMonitoringAccess == kIOHIDAccessTypeGranted &&
            KeyboardInjector.isAccessibilityTrusted
    }

    private func startPermissionMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, self.manager != nil else { return }
            if !self.runtimePermissionsAreValid() {
                self.releaseForRevokedPermissions()
            }
        }
        permissionMonitor = timer
        timer.resume()
    }

    private func releaseForRevokedPermissions() {
        stop()
        updateStatus("系统权限已失效；已释放遥控器")
        AppLogger.shared.write("HID RELEASED permission_revoked")
    }

    /// Deferred fail-close for a matched-but-unreadable device (see `deviceDidMatch`).
    /// Closing the manager flips reader health to unhealthy, so the coordinator
    /// re-selects the standalone reader (or fails closed). Skipped if a readable
    /// device has since been adopted or the monitor already stopped.
    private func failReaderClosed(result: IOReturn) {
        guard manager != nil, !lifecycle.devicePresent else { return }
        stop()
        updateStatus("无法读取 RC003（错误 \(result)）")
        AppLogger.shared.write("HID READER FAILED result=\(result)")
    }

    private func updateStatus(_ value: String) {
        status = value
        onStatus?(value)
    }
}
