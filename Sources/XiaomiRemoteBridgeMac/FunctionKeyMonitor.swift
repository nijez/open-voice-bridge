import CoreGraphics
import Foundation

private func functionKeyMonitorCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<FunctionKeyMonitor>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    monitor.handle(type: type, event: event)
    // Always pass the event through untouched: the target IME still needs the
    // physical Fn/Globe press to enter its voice mode. This monitor only listens.
    return Unmanaged.passUnretained(event)
}

/// Passively observes the Mac keyboard's physical Fn/Globe key via a listen-only
/// session event tap and reports debounced press/release edges. The tap never
/// consumes events, so normal Fn behaviour (and the RC003 hardware-mapped Fn) is
/// unaffected. Requires the same input-monitoring authorisation the RC003 key
/// mapping already uses; `start()` returns `false` (fail closed) when the tap
/// cannot be created.
final class FunctionKeyMonitor {
    var onTransition: ((VoiceFunctionKeyTransition) -> Void)?
    /// Fired when the tap is disrupted (disabled by timeout/user input). The
    /// coordinator must force-release the current Fn cycle and require a fresh
    /// full press afterwards — re-enabling the tap alone is not enough.
    var onDisrupted: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tracker = FunctionKeyFlagTracker()

    private(set) var isRunning = false

    /// Whether the tap is live *and* still enabled by the system. The liveness
    /// timer uses this to fail closed if the tap was silently disabled (e.g.
    /// input-monitoring revoked at runtime).
    var isTapEnabled: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    @discardableResult
    func start() -> Bool {
        if isRunning { return true }

        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: functionKeyMonitorCallback,
            userInfo: context
        ) else {
            return false
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        ) else {
            return false
        }

        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        tracker.reset()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        isRunning = true
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        tracker.reset()
        isRunning = false
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The tap was disabled while a press may still be in flight. Fail
            // closed for this cycle: forget the held state (so the missed Fn-up
            // cannot strand a capture) and tell the coordinator to release and
            // stop. Only then attempt to re-enable so future presses work; a
            // fresh full key cycle is now required.
            tracker.reset()
            onDisrupted?()
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }
        guard type == .flagsChanged else { return }
        let functionActive = event.flags.contains(.maskSecondaryFn)
        if let transition = tracker.update(functionFlagActive: functionActive) {
            onTransition?(transition)
        }
    }
}
