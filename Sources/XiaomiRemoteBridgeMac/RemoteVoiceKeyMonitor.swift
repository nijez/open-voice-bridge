import Foundation
import IOKit.hid

private func remoteVoiceKeyInputReport(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard let context, result == kIOReturnSuccess, reportLength > 0 else { return }
    let monitor = Unmanaged<RemoteVoiceKeyMonitor>.fromOpaque(context).takeUnretainedValue()
    // The manager is scheduled on the main run loop, so this callback runs on the
    // main thread: snapshot the present-device generation and hand the report to
    // the same ordered main-queue domain as match/removal. A report with no
    // present device (nil) is dropped; one whose generation a removal invalidated,
    // or that arrives while the reader is unhealthy (e.g. Input Monitoring revoked
    // between snapshot and execution), is rejected on execution — so a late report
    // cannot re-open the F5 key after a balanced `.up` or while permission is gone.
    guard let generation = monitor.currentReportGeneration else { return }
    let data = Data(bytes: report, count: reportLength)
    DispatchQueue.main.async {
        monitor.handleReport(reportID: reportID, data: data, generation: generation)
    }
}

private func remoteVoiceKeyDeviceMatched(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    let monitor = Unmanaged<RemoteVoiceKeyMonitor>.fromOpaque(context).takeUnretainedValue()
    // The manager is scheduled on the main run loop, so this fires on the main
    // thread: run it directly (no redundant re-dispatch) so the present-device
    // generation is live before any input report is snapshotted — the F5 pre-marker
    // for a held key can never be dropped for racing the match.
    monitor.deviceDidMatch(result: result, device: device)
}

private func remoteVoiceKeyDeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    let monitor = Unmanaged<RemoteVoiceKeyMonitor>.fromOpaque(context).takeUnretainedValue()
    // Runs on the main thread (see the match callback). Handling removal directly
    // invalidates the device generation before any still-queued input-report async
    // block executes, so a late report is rejected and cannot follow the balancing
    // `.up` with a stale `.down`.
    monitor.deviceDidRemove(device: device)
}

/// Passively reads the RC003 microphone (F5) key edge directly from the remote's
/// HID input reports, matching only the RC003 VID/PID. It is the reliable
/// "remote source" pre-marker for the local-microphone arbiter when the RC003
/// custom key mapping is OFF (so `HIDRemoteMonitor` is not running and has not
/// opened the device).
///
/// Coordination with `HIDRemoteMonitor`: this observer opens the device in
/// non-seize (shared) mode and NEVER seizes, so it cannot consume RC003 keys or
/// break the F5→Fn remap. The coordinator only runs it while the compatibility
/// feature is enabled and custom mapping is OFF, so it never double-opens or
/// contends with `HIDRemoteMonitor`'s seize. When custom mapping is ON,
/// `HIDRemoteMonitor` (which already reads the device) supplies the same edge.
///
/// Health closed loop (round 5): the observer keeps a shared `StandaloneReaderHealth`
/// that separates "observing" (the manager is open and watching) from "healthy"
/// (safe to trust as the F5 pre-marker). A matched-but-unreadable device fails the
/// reader closed without tearing the watcher down, and a 1-second Input Monitoring
/// liveness flips health the moment permission is revoked at runtime and reopens
/// to re-verify when it is restored. The coordinator reads `isObserving`
/// (restart decision) and `isHealthy` (readerReady) and is notified via
/// `onReaderHealthChange` whenever health flips from a callback it did not drive.
final class RemoteVoiceKeyMonitor {
    /// Reports RC003 microphone-key down/up edges on the main run loop.
    var onVoiceKeyEdge: ((RemoteEventEdge) -> Void)?
    /// Fired on the main run loop whenever the reader's *health* flips from a
    /// source the coordinator did not itself drive (a match open-failure, a
    /// device removal that clears an unreadable block, or a permission
    /// revoke/restore liveness tick). The coordinator re-selects the single F5
    /// reader and pushes `readerReady` from real health. Deliberately NOT fired
    /// from `start()`/`stop()`, which the coordinator invokes and reads back
    /// synchronously — self-notifying there would re-enter the coordinator and
    /// could restart this observer while `HIDRemoteMonitor` is mid-(re)open.
    var onReaderHealthChange: (() -> Void)?
    /// Fired SYNCHRONOUSLY, on the main run loop, immediately BEFORE every forced
    /// balancing `.up` and on every adopted-device generation change — even when
    /// reader health does not flip (a present-device removal keeps the watcher
    /// healthy). The coordinator resets only the double-click detector here so a
    /// synthetic `.up` cannot complete an in-flight double-click; the balancing
    /// `.up` that follows still reaches the local-mic arbiter.
    var onGestureInvalidate: (() -> Void)?

    private var manager: IOHIDManager?
    private var health = StandaloneReaderHealth()
    private var tracker = RemoteVoiceKeyTracker()
    private var permissionMonitor: DispatchSourceTimer?
    /// The adopted (present, readable) device, so a removal is matched by identity
    /// rather than clearing state for any RC003 removal.
    private var activeDevice: IOHIDDevice?
    /// A matched-but-unreadable device blocking health. Stored by identity so only
    /// *its* removal clears the failure — an unrelated removal must not.
    private var unreadableDevice: IOHIDDevice?
    /// Last health value handed to the coordinator, so `onReaderHealthChange`
    /// fires only on a real flip.
    private var reportedHealthy = false

    /// The manager is open and watching (it may be unhealthy). The coordinator
    /// (re)starts the observer only when this is false, so a match-failure or
    /// revoke unhealthy state cannot drive a restart loop.
    var isObserving: Bool { health.isObserving }

    /// The reader is currently safe to trust as the F5 pre-marker. The coordinator
    /// pushes this as `readerReady` for the standalone target; false fails the
    /// local mic path closed.
    var isHealthy: Bool { health.isHealthy }

    /// The present-device generation an input-report callback tags its report with,
    /// or `nil` when no device is present (so the report is dropped).
    fileprivate var currentReportGeneration: UInt64? { health.activeGeneration }

    @discardableResult
    func start() -> Bool {
        stopInternals()
        let opened = openManager()
        if opened { startPermissionMonitor() }
        // The coordinator reads `isObserving`/`isHealthy` right after start(), so
        // just snapshot the reported health here without notifying (a self-notify
        // would re-enter the coordinator).
        syncReportedHealth()
        return opened
    }

    func stop() {
        // Feature off / mapping switch / teardown: cancel the liveness timer (no
        // background polling), balance any held F5, and close the pipeline. As
        // with start(), snapshot health without notifying — the coordinator drives
        // this call and reads health back synchronously.
        stopInternals()
        syncReportedHealth()
    }

    /// Opens the IOHIDManager and marks the pure health as observing/healthy on
    /// success. Does NOT touch the liveness timer or the reported-health snapshot,
    /// so it composes into both `start()` and an in-place permission reopen.
    private func openManager() -> Bool {
        guard HIDRemoteMonitor.isInputMonitoringGranted,
              let hidIdentity = VoiceBridgeDeviceProfiles.xiaomiRC003.hidIdentity
        else { return false }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [
            kIOHIDVendorIDKey as String: hidIdentity.vendorID,
            kIOHIDProductIDKey as String: hidIdentity.productID,
        ] as CFDictionary
        IOHIDManagerSetDeviceMatching(manager, matching)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputReportCallback(manager, remoteVoiceKeyInputReport, context)
        // Track match/removal so a device that disconnects mid-press still emits a
        // balancing `.up` (keeps the arbiter's remoteSourceActive from sticking)
        // and a match open-failure fails the reader closed.
        IOHIDManagerRegisterDeviceMatchingCallback(manager, remoteVoiceKeyDeviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, remoteVoiceKeyDeviceRemoved, context)
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
            AppLogger.shared.write("REMOTE VOICEKEY open_failed=\(result)")
            return false
        }
        self.manager = manager
        // Pipeline open: a healthy watcher for the current and all future RC003
        // devices, even before any device matches.
        health.opened()
        AppLogger.shared.write("REMOTE VOICEKEY observing")
        return true
    }

    /// Closes the IOHIDManager and drops the present/unreadable device, marking the
    /// pure health closed. Does NOT touch the liveness timer, so the in-place
    /// permission reopen keeps polling across the close+open.
    private func closeManager() {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
        }
        activeDevice = nil
        unreadableDevice = nil
        health.closed()
    }

    private func stopInternals() {
        permissionMonitor?.cancel()
        permissionMonitor = nil
        // Balance any in-flight press before tearing down: if F5 is still held
        // when the reader stops, emit the `.up` so the arbiter's remoteSourceActive
        // cannot stay stuck true.
        forceReleaseVoiceKey()
        closeManager()
    }

    fileprivate func deviceDidMatch(result: IOReturn, device: IOHIDDevice) {
        // Adopt the device under a fresh generation only when the match reports
        // success; input reports then flow through `handleReport` tagged with that
        // generation. A failed match leaves the target device present but
        // unreadable: fail the reader closed (health flips false) WITHOUT tearing
        // the watcher down, so the coordinator falls back to the other reader (or
        // fails the local mic closed), and a later removal of this exact device can
        // recover health without a spinning re-open.
        switch health.matched(openSucceeded: result == kIOReturnSuccess) {
        case .ignored:
            return
        case .unreadable:
            unreadableDevice = device
            AppLogger.shared.write("REMOTE VOICEKEY match_failed=\(result)")
            notifyHealthIfChanged()
        case .present:
            activeDevice = device
            // A readable device supersedes any prior unreadable block.
            unreadableDevice = nil
            // A freshly adopted device is a new generation: drop any in-flight
            // double-click so a gesture straddling a reconnect cannot be completed
            // by edges from two different device generations.
            onGestureInvalidate?()
            notifyHealthIfChanged()
        }
    }

    fileprivate func deviceDidRemove(device: IOHIDDevice) {
        // The stuck-unreadable device left: clear the block (identity-guarded) so
        // health can recover to a watcher with no present device.
        if let unreadableDevice, CFEqual(unreadableDevice, device) {
            self.unreadableDevice = nil
            health.clearUnreadable()
            notifyHealthIfChanged()
            return
        }
        // The adopted device left: invalidate the device generation FIRST so any
        // late/queued report is dropped, THEN force-release — which invalidates the
        // gesture (even when no key is held, since this is a generation change) and,
        // if F5 is held, emits a balancing `.up` so the local mic is not left
        // suppressed. Guarded on identity so a removal for some other device is a
        // no-op.
        guard let activeDevice, CFEqual(activeDevice, device) else { return }
        _ = health.removed()
        self.activeDevice = nil
        forceReleaseVoiceKey()
        // The manager stays open and keeps watching, so reader health is unchanged
        // (a healthy watcher with no device present); notify only if it flipped.
        notifyHealthIfChanged()
    }

    /// Forced (non-report) voice-key release: stop, device removal, or permission
    /// revoke. Drives the shared ordering contract so the gesture is invalidated
    /// FIRST (always), then — only if the key is currently held — a balancing `.up`
    /// is emitted. A genuine key-up parsed from a report never comes through here,
    /// so a real second tap still toggles.
    private func forceReleaseVoiceKey() {
        for effect in RemoteVoiceKeyForcedRelease.effects(keyHeld: tracker.isDown) {
            switch effect {
            case .invalidateGesture:
                onGestureInvalidate?()
            case .balancingUp:
                if let edge = tracker.release() {
                    onVoiceKeyEdge?(edge)
                }
            }
        }
    }

    fileprivate func handleReport(reportID: UInt32, data: Data, generation: UInt64) {
        // Verify BOTH health and generation at execution time: reject a report
        // whose device has been removed or superseded (stale generation) and any
        // report that arrives while the reader is unhealthy (Input Monitoring
        // revoked between snapshot and execution). A permission-failed report must
        // never emit a `.down`.
        guard health.isHealthy,
              health.accepts(generation: generation),
              let usages = RemoteHIDReportParser.usages(reportID: reportID, data: data)
        else { return }
        if let edge = tracker.update(usages: usages) {
            onVoiceKeyEdge?(edge)
        }
    }

    // MARK: Input Monitoring liveness

    /// Polls Input Monitoring once per second while observing. On a runtime revoke
    /// it flips health to unhealthy immediately, balances a held F5 with an `.up`,
    /// and notifies the coordinator (which pushes `readerReady=false` and stops any
    /// running local capture). On restore it reopens the manager to genuinely
    /// re-verify — never re-blessing the stale manager — minting a fresh generation
    /// on the next match. The timer runs only between `start()` and `stop()`, so
    /// the feature-off path leaves no background poll.
    private func startPermissionMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.permissionTick()
        }
        permissionMonitor = timer
        timer.resume()
    }

    private func permissionTick() {
        let granted = HIDRemoteMonitor.isInputMonitoringGranted
        if granted {
            // Restored (or a prior reopen failed): reopen to re-verify. Bounded to
            // the 1 Hz tick — never a tight spin.
            if !health.permissionHealthy {
                reopenAfterPermissionRestore()
            }
        } else if health.permissionHealthy {
            // Revoked at runtime: fail closed now, balance a held key, notify. The
            // manager is kept open (still observing) so this same timer detects the
            // restore; recovery still requires a reopen, not a bare flag flip.
            health.revokePermission()
            forceReleaseVoiceKey()
            AppLogger.shared.write("REMOTE VOICEKEY permission_revoked")
            notifyHealthIfChanged()
        }
    }

    private func reopenAfterPermissionRestore() {
        // Close then open a fresh manager so a recovered permission is verified,
        // not assumed. The liveness timer keeps running across this, so a failed
        // reopen (permission flapped) simply retries on the next tick. On success
        // health returns to true and a reconnect mints a new generation.
        closeManager()
        let reopened = openManager()
        AppLogger.shared.write("REMOTE VOICEKEY permission_restore reopened=\(reopened)")
        notifyHealthIfChanged()
    }

    // MARK: Health notification

    /// Snapshots current health as "reported" WITHOUT notifying — used by the
    /// coordinator-driven `start()`/`stop()`, which read health back synchronously.
    private func syncReportedHealth() {
        reportedHealthy = health.isHealthy
    }

    /// Notifies the coordinator only when health has flipped since the last report
    /// — used by the callback-driven paths (match failure, removal recovery,
    /// permission revoke/restore) the coordinator did not itself drive.
    private func notifyHealthIfChanged() {
        let healthy = health.isHealthy
        guard healthy != reportedHealthy else { return }
        reportedHealthy = healthy
        onReaderHealthChange?()
    }
}
