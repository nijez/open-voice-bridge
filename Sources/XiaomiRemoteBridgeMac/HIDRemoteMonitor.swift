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
    private enum NativeMappingState { case restored, pending, applied, restoreFailed }

    private let settings: AppSettings
    private let eventSuppressor = KeyboardEventSuppressor()
    private let nativeMapper: RemoteButtonNativeMapper
    private var nativeMappingState = NativeMappingState.restored
    private var nativeMappingRetryToken: UInt64 = 0
    private var manager: IOHIDManager?
    private var lifecycle = RemoteDeviceLifecycle()
    private var activeDevice: IOHIDDevice?
    private var activeDeviceIsSeized = false
    private var activeUsages = Set<UInt16>()
    private var repeatTimers: [UInt16: DispatchSourceTimer] = [:]
    private var multiActionHeldBindings: [UInt16: HeldButtonBinding] = [:]
    private var permissionMonitor: DispatchSourceTimer?
    private var voiceKeyIsDown = false
    private var heldVoiceChord = HeldKeyChordLatch()
    private var reconfiguring = false
    private var reportedReading = false
    /// Runtime action gate. When true (bridge runtime disabled) the monitor keeps
    /// reading the device and still parses the voice-key edge (so the double-click
    /// detector can restore the bridge), but injects no keyboard/mouse/system
    /// actions and runs no repeats. Independent of `customMappingEnabled`, which
    /// governs whether the monitor reads at all.
    private var actionsSuppressed = false
    private lazy var multiActionCoordinator = MultiActionRuntimeCoordinator(
        isUsageActive: { [weak self] usage in
            self?.activeUsages.contains(usage) == true
        },
        deliverOutputs: { [weak self] context, outputs in
            self?.deliverMultiActionOutputs(
                outputs,
                usage: context.usage,
                button: context.button,
                binding: context.binding
            ) ?? false
        },
        deliveryDidFail: { [weak self] in
            self?.failClosedForDeliveryError()
        }
    )
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
    /// Final live-system mapping audit immediately before adopting a matching
    /// device. This closes the race where the IOHID service appears after the
    /// settings/model callback that initially prepared a custom voice binding.
    var canAdoptDevice: (() -> Bool)?

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
    var isVoiceKeyPressed: Bool { voiceKeyIsDown }

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
        guard suppressed else {
            if let activeDevice, !activeDeviceIsSeized,
               let generation = lifecycle.activeGeneration {
                beginNativeMapping(to: activeDevice, generation: generation)
            }
            return
        }
        cancelNativeMappingRetry()
        repeatTimers.values.forEach { $0.cancel() }
        repeatTimers.removeAll()
        resetMultiActionRuntimes()
        releaseHeldVoiceChord()
        // The reset above cancels pending gestures and balances held output.
        // Forget physical usages so a later release
        // cannot re-arm one-shot suppression or resume a cancelled repeat.
        activeUsages.removeAll()
        restoreNativeMapping()
        if nativeMappingState == .restoreFailed {
            updateStatus("RC003 原生按键映射恢复失败；请重新连接遥控器")
        }
        AppLogger.shared.write("HID ACTIONS suppressed")
    }

    init(
        settings: AppSettings,
        nativeMapper: RemoteButtonNativeMapper = RemoteButtonNativeMapper()
    ) {
        self.settings = settings
        self.nativeMapper = nativeMapper
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
        guard nativeMappingState == .restored else {
            updateStatus("RC003 原生按键映射恢复失败；请重新连接遥控器")
            return
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
        cancelNativeMappingRetry()
        permissionMonitor?.cancel()
        permissionMonitor = nil
        repeatTimers.values.forEach { $0.cancel() }
        repeatTimers.removeAll()
        resetMultiActionRuntimes()
        activeUsages.removeAll()
        releaseHeldVoiceChord()
        forceReleaseVoiceKey()
        restoreNativeMapping()
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

        guard result != kIOReturnSuccess || canAdoptDevice?() != false else {
            updateStatus("语音键系统映射无法安全协调；已拒绝读取设备")
            AppLogger.shared.write("HID DEVICE ADOPTION rejected voice_mapping_audit")
            return
        }

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
            if !seized && !actionsSuppressed,
               let generation = lifecycle.activeGeneration {
                beginNativeMapping(to: device, generation: generation)
                return
            }
            reportConnected()
        }
    }

    private func beginNativeMapping(to device: IOHIDDevice, generation: UInt64) {
        cancelNativeMappingRetry()
        // A disappearing service may outlive its removal callback briefly. Clear
        // any prior-generation rollback entry before adopting a new service.
        guard nativeMapper.restore() else {
            nativeMappingState = .restoreFailed
            failNativeMapping(generation: generation, token: nativeMappingRetryToken, reason: "restore")
            return
        }
        guard let location = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber else {
            nativeMappingState = .restoreFailed
            failNativeMapping(generation: generation, token: nativeMappingRetryToken, reason: "missing_location")
            return
        }
        nativeMappingState = .pending
        let token = nativeMappingRetryToken
        attemptNativeMapping(
            to: device,
            locationID: location.uint64Value,
            generation: generation,
            attempt: 0,
            token: token
        )
    }

    private func attemptNativeMapping(
        to device: IOHIDDevice,
        locationID: UInt64,
        generation: UInt64,
        attempt: Int,
        token: UInt64
    ) {
        guard nativeMappingAttemptIsCurrent(device: device, generation: generation, token: token) else {
            return
        }
        switch nativeMapper.applyResult(
            locationID: locationID,
            includeHardwareVoiceMapping: shouldMapVoiceToHardwareFn
        ) {
        case .applied:
            nativeMappingState = .applied
            reportConnected()
        case .failed:
            nativeMappingState = .restoreFailed
            failNativeMapping(generation: generation, token: token, reason: "safety_failure")
        case .serviceNotReady:
            let delay = RemoteButtonNativeMappingRetryPolicy.delay(afterAttempt: attempt)
            nativeMappingState = .pending
            updateStatus("正在等待 RC003 系统按键服务")
            AppLogger.shared.write(
                "HID NATIVE MAPPING waiting attempt=\(attempt + 1) delay_ms=\(Int(delay * 1_000))"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.attemptNativeMapping(
                    to: device,
                    locationID: locationID,
                    generation: generation,
                    attempt: attempt + 1,
                    token: token
                )
            }
        }
    }

    private var shouldMapVoiceToHardwareFn: Bool {
        if case .hardwareFn = settings.binding(for: .microphone) { return true }
        return false
    }

    private func nativeMappingAttemptIsCurrent(
        device: IOHIDDevice,
        generation: UInt64,
        token: UInt64
    ) -> Bool {
        guard token == nativeMappingRetryToken,
              manager != nil,
              settings.customMappingEnabled,
              !actionsSuppressed,
              !activeDeviceIsSeized,
              lifecycle.activeGeneration == generation,
              let activeDevice
        else { return false }
        return CFEqual(activeDevice, device)
    }

    private func failNativeMapping(generation: UInt64, token: UInt64, reason: String) {
        // Never tear down IOHIDManager from inside its own device-match callback.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  token == self.nativeMappingRetryToken,
                  self.lifecycle.activeGeneration == generation
            else { return }
            AppLogger.shared.write("HID NATIVE MAPPING failed reason=\(reason)")
            self.stop()
            self.updateStatus("无法安全屏蔽 RC003 原生按键；已停止自定义映射")
        }
    }

    private func cancelNativeMappingRetry() {
        nativeMappingRetryToken &+= 1
    }

    private func reportConnected() {
        if activeDeviceIsSeized {
            updateStatus("RC003 按键映射已连接（独占模式）")
            AppLogger.shared.write("HID CONNECTED mode=seized")
        } else {
            let suffix = actionsSuppressed ? "兼容模式；原生按键已恢复" : "兼容模式；设备级按键屏蔽"
            updateStatus("RC003 按键映射已连接（\(suffix)）")
            AppLogger.shared.write("HID CONNECTED mode=monitored")
        }
        // A successful match keeps the (already-open) pipeline healthy, so this
        // is a no-op flip; call it for consistency with the health model.
        syncReaderHealth()
    }

    private func restoreNativeMapping() {
        nativeMappingState = nativeMapper.restore() ? .restored : .restoreFailed
    }

    fileprivate func deviceDidRemove(device: IOHIDDevice) {
        guard let activeDevice, CFEqual(activeDevice, device) else { return }
        cancelNativeMappingRetry()
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
        resetMultiActionRuntimes()
        restoreNativeMapping()
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
        guard activeDeviceIsSeized || nativeMappingState == .applied else { return }

        for usage in pressed.sorted() {
            guard let button = RemoteButton.usageMap[usage] else { continue }
            if multiActionCoordinator.resumeDeferredHold(for: usage) {
                AppLogger.shared.write(
                    "HID MULTI button=\(button.rawValue) firmware_repeat=merged"
                )
                continue
            }

            // Ordinary native events are discarded at the device layer. Avoid
            // consuming an identical key from the user's physical keyboard.
            if !activeDeviceIsSeized && button == .microphone {
                eventSuppressor.arm(button: button, edge: .down)
            }

            guard multiActionCoordinator.interruptPending(excluding: usage) else {
                failClosedForDeliveryError()
                return
            }

            let multiActionBinding = settings.multiActionBinding(for: button)
            if button != .microphone {
                guard multiActionCoordinator.handle(
                    .down,
                    usage: usage,
                    button: button,
                    binding: multiActionBinding,
                    configuration: multiActionConfiguration(for: multiActionBinding)
                ) else {
                    failClosedForDeliveryError()
                    return
                }
            } else {
                let binding = multiActionBinding.single
                let delivered: Bool
                if button == .microphone, case let .shortcut(chord) = binding {
                    delivered = KeyboardInjector.send(chord, edge: .down)
                    if delivered { heldVoiceChord.press(chord) }
                } else {
                    delivered = KeyboardInjector.send(binding)
                }
                guard delivered else {
                    failClosedForDeliveryError()
                    return
                }
            }
            AppLogger.shared.write(
                "HID BUTTON down=\(button.rawValue) multi=\(multiActionBinding.hasAdditionalActions)"
            )
        }

        for usage in released {
            guard let button = RemoteButton.usageMap[usage] else { continue }
            if multiActionCoordinator.hasRuntime(for: usage) {
                if multiActionCoordinator.isHoldingOutput(for: usage) {
                    multiActionCoordinator.deferHeldRelease(for: usage)
                } else {
                    let binding = settings.multiActionBinding(for: button)
                    guard multiActionCoordinator.handle(
                        .up,
                        usage: usage,
                        button: button,
                        binding: binding,
                        configuration: multiActionConfiguration(for: binding)
                    ) else {
                        failClosedForDeliveryError()
                        return
                    }
                }
            } else {
                if !activeDeviceIsSeized && button == .microphone {
                    eventSuppressor.arm(button: button, edge: .up)
                }
                if button == .microphone, !releaseHeldVoiceChord() {
                    failClosedForDeliveryError()
                    return
                }
                repeatTimers.removeValue(forKey: usage)?.cancel()
            }
        }
    }

    private func multiActionConfiguration(
        for binding: MultiActionButtonBinding
    ) -> MultiActionGestureConfiguration {
        MultiActionGestureConfiguration(
            hasDoublePress: binding.doublePress != nil,
            hasLongPress: binding.longPress != nil,
            doubleClickMs: settings.multiActionDoubleClickMs,
            longPressMs: settings.multiActionLongPressMs
        )
    }

    private func deliverMultiActionOutputs(
        _ outputs: [MultiActionGestureOutput],
        usage: UInt16,
        button: RemoteButton,
        binding: MultiActionButtonBinding
    ) -> Bool {
        HIDPermissionGate.deliverGestureOutputs(
            outputs, permissionsAreValid: runtimePermissionsAreValid
        ) { output in
            switch output {
            case .performSingle(let count):
                guard deliver(binding.single, count: count) else { return false }
                AppLogger.shared.write(
                    "HID MULTI button=\(button.rawValue) gesture=single count=\(count)"
                )

            case .performDouble:
                guard let doubleBinding = binding.doublePress,
                      deliver(doubleBinding, count: 1)
                else { return false }
                AppLogger.shared.write(
                    "HID MULTI button=\(button.rawValue) gesture=double"
                )

            case .beginSingleHold(let precedingTapCount):
                guard deliver(binding.single, count: precedingTapCount),
                      beginMultiActionHold(
                          binding.single,
                          usage: usage,
                          button: button
                      )
                else { return false }
                AppLogger.shared.write(
                    "HID MULTI button=\(button.rawValue) " +
                    "gesture=single_hold phase=begin preceding=\(precedingTapCount)"
                )

            case .beginLongHold:
                guard let longBinding = binding.longPress,
                      beginMultiActionHold(longBinding, usage: usage, button: button)
                else { return false }
                AppLogger.shared.write(
                    "HID MULTI button=\(button.rawValue) gesture=long_hold phase=begin"
                )

            case .endHold:
                repeatTimers.removeValue(forKey: usage)?.cancel()
                if let heldBinding = multiActionHeldBindings[usage] {
                    guard KeyboardInjector.endHold(heldBinding) else { return false }
                    multiActionHeldBindings.removeValue(forKey: usage)
                }
                AppLogger.shared.write(
                    "HID MULTI button=\(button.rawValue) gesture=hold phase=end"
                )
            }
            return true
        }
    }

    private func beginMultiActionHold(
        _ binding: ButtonBinding,
        usage: UInt16,
        button: RemoteButton
    ) -> Bool {
        guard multiActionHeldBindings[usage] == nil else { return true }
        let result = KeyboardInjector.beginHold(binding)
        guard result.delivered else { return false }
        if let heldBinding = result.heldBinding {
            multiActionHeldBindings[usage] = heldBinding
        }
        if let heldBinding = result.heldBinding, heldBinding.supportsRepeat {
            startHeldRepeat(
                usage: usage,
                button: button,
                heldBinding: heldBinding
            )
        }
        return true
    }

    private func deliver(_ binding: ButtonBinding, count: Int) -> Bool {
        guard count > 0 else { return true }
        for _ in 0..<count {
            guard KeyboardInjector.send(binding) else { return false }
        }
        return true
    }

    private func resetMultiActionRuntimes() {
        for context in multiActionCoordinator.reset() {
            repeatTimers.removeValue(forKey: context.usage)?.cancel()
            if let heldBinding = multiActionHeldBindings[context.usage] {
                _ = KeyboardInjector.endHold(heldBinding)
                multiActionHeldBindings.removeValue(forKey: context.usage)
            }
        }
        multiActionHeldBindings.removeAll()
    }

    private func failClosedForDeliveryError() {
        guard runtimePermissionsAreValid() else {
            releaseForRevokedPermissions()
            return
        }
        stop()
        updateStatus("无法发送自定义按键；已释放遥控器")
    }

    private func startHeldRepeat(
        usage: UInt16,
        button: RemoteButton,
        heldBinding: HeldButtonBinding
    ) {
        repeatTimers.removeValue(forKey: usage)?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + .milliseconds(Int(RemoteButtonRepeatTiming.initialDelayMs)),
            repeating: .milliseconds(RemoteButtonRepeatTiming.intervalMs)
        )
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.multiActionCoordinator.hasRuntime(for: usage),
                  self.multiActionHeldBindings[usage] == heldBinding,
                  self.activeUsages.contains(usage)
            else { return }
            guard self.runtimePermissionsAreValid() else {
                self.releaseForRevokedPermissions()
                return
            }
            if !KeyboardInjector.repeatHold(heldBinding) {
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
        _ = releaseHeldVoiceChord()
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

    @discardableResult
    private func releaseHeldVoiceChord() -> Bool {
        heldVoiceChord.release { chord in
            KeyboardInjector.send(chord, edge: .up)
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
