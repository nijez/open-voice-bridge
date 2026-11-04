import Foundation

enum RemoteButtonRepeatTiming {
    static let initialDelayMs: UInt64 = 350
    static let intervalMs = 100
}

/// A cancellable scheduled callback used by the gesture runtime. The small
/// type-erased wrapper keeps Dispatch timers out of the coordinator's logic and
/// lets tests supply a deterministic scheduler.
final class MultiActionScheduledTask {
    private var cancelAction: (() -> Void)?

    init(cancel: @escaping () -> Void) {
        cancelAction = cancel
    }

    func cancel() {
        cancelAction?()
        cancelAction = nil
    }

    deinit {
        cancel()
    }
}

/// Callbacks must run asynchronously on the same serial execution context as
/// the coordinator's callers. Production uses the main queue; deterministic
/// tests drive callbacks serially with a fake clock.
struct MultiActionRuntimeScheduler {
    let nowMs: () -> UInt64
    let schedule: (_ delayMs: UInt64, _ action: @escaping () -> Void) -> MultiActionScheduledTask

    static let main = MultiActionRuntimeScheduler(
        nowMs: {
            DispatchTime.now().uptimeNanoseconds / 1_000_000
        },
        schedule: { delayMs, action in
            let timer = DispatchSource.makeTimerSource(queue: .main)
            let boundedDelay = Int(min(delayMs, UInt64(Int.max)))
            timer.schedule(deadline: .now() + .milliseconds(boundedDelay))
            timer.setEventHandler(handler: action)
            timer.resume()
            return MultiActionScheduledTask {
                timer.cancel()
            }
        }
    )
}

struct MultiActionRuntimeContext: Equatable {
    let usage: UInt16
    let button: RemoteButton
    let binding: MultiActionButtonBinding
}

struct MultiActionRuntimeResetContext: Equatable {
    let usage: UInt16
    let button: RemoteButton
    let wasHoldingOutput: Bool
}

/// Owns the ordinary and gesture button runtime lifecycle:
/// per-usage state machines, their deadlines, firmware-repeat release grace,
/// interruption, and reset. HID parsing and actual keyboard delivery remain in
/// `HIDRemoteMonitor`.
///
/// This type is not thread-safe. All calls, scheduled callbacks, and output
/// delivery share one serial execution context (the main thread in production).
/// Each runtime snapshots its binding and timing when created, retaining them
/// for the entire tap/hold sequence, including any quick-tap window.
/// Reset discards pending gestures and cancels tasks; the owner must balance
/// platform hold resources using the returned reset contexts
/// before accepting another sequence.
final class MultiActionRuntimeCoordinator {
    typealias OutputHandler = (
        MultiActionRuntimeContext,
        [MultiActionGestureOutput]
    ) -> Bool

    private final class Runtime {
        let context: MultiActionRuntimeContext
        var gesture: MultiActionButtonGesture
        var deadlineTask: MultiActionScheduledTask?
        var deferredReleaseTask: MultiActionScheduledTask?
        var deferredReleaseGeneration: UInt64 = 0
        let immediateSingle: Bool
        let pressedAtMs: UInt64

        init(
            context: MultiActionRuntimeContext,
            configuration: MultiActionGestureConfiguration,
            pressedAtMs: UInt64
        ) {
            self.context = context
            self.pressedAtMs = pressedAtMs
            immediateSingle = !configuration.hasDoublePress && !configuration.hasLongPress
            gesture = MultiActionButtonGesture(configuration: configuration)
        }

        deinit {
            deadlineTask?.cancel()
            deferredReleaseTask?.cancel()
        }
    }

    private let scheduler: MultiActionRuntimeScheduler
    private let releaseGraceMs: UInt64
    private let isUsageActive: (UInt16) -> Bool
    private let deliverOutputs: OutputHandler
    private let deliveryDidFail: () -> Void
    private var runtimes: [UInt16: Runtime] = [:]

    init(
        scheduler: MultiActionRuntimeScheduler = .main,
        releaseGraceMs: UInt64 = 120,
        isUsageActive: @escaping (UInt16) -> Bool,
        deliverOutputs: @escaping OutputHandler,
        deliveryDidFail: @escaping () -> Void
    ) {
        self.scheduler = scheduler
        self.releaseGraceMs = releaseGraceMs
        self.isUsageActive = isUsageActive
        self.deliverOutputs = deliverOutputs
        self.deliveryDidFail = deliveryDidFail
    }

    func hasRuntime(for usage: UInt16) -> Bool {
        runtimes[usage] != nil
    }

    func isHoldingOutput(for usage: UInt16) -> Bool {
        runtimes[usage]?.gesture.isHoldingOutput == true
    }

    @discardableResult
    func handle(
        _ edge: RemoteEventEdge,
        usage: UInt16,
        button: RemoteButton,
        binding: MultiActionButtonBinding,
        configuration: MultiActionGestureConfiguration
    ) -> Bool {
        let runtime: Runtime
        if let existing = runtimes[usage] {
            runtime = existing
        } else {
            runtime = Runtime(
                context: MultiActionRuntimeContext(
                    usage: usage,
                    button: button,
                    binding: binding
                ),
                configuration: configuration,
                pressedAtMs: scheduler.nowMs()
            )
            runtimes[usage] = runtime
        }

        let outputs = runtime.gesture.handle(edge, nowMs: scheduler.nowMs())
        guard deliverOutputs(runtime.context, outputs) else { return false }
        refreshDeadline(for: usage, runtime: runtime)
        return true
    }

    @discardableResult
    func interruptPending(excluding excludedUsage: UInt16) -> Bool {
        for usage in runtimes.keys.sorted() where usage != excludedUsage {
            guard let runtime = runtimes[usage] else { continue }
            let outputs = runtime.gesture.interrupt()
            guard deliverOutputs(runtime.context, outputs) else { return false }
            refreshDeadline(for: usage, runtime: runtime)
        }
        return true
    }

    /// Merges the RC003 firmware's next report round into an already-active hold.
    /// Returns true only when a deferred physical release was actually cancelled.
    func resumeDeferredHold(for usage: UInt16) -> Bool {
        guard let runtime = runtimes[usage],
              let task = runtime.deferredReleaseTask,
              runtime.gesture.isHoldingOutput
        else { return false }
        task.cancel()
        runtime.deferredReleaseTask = nil
        runtime.deferredReleaseGeneration &+= 1
        return true
    }

    func deferHeldRelease(for usage: UInt16) {
        guard let runtime = runtimes[usage], runtime.gesture.isHoldingOutput else { return }
        // Plain short taps must release immediately: otherwise rapid independent
        // taps (<120 ms apart) would be mistaken for firmware repeat rounds.
        // Once held for the repeat delay, use the same grace as gesture holds.
        let nowMs = scheduler.nowMs()
        if runtime.immediateSingle &&
            (nowMs < runtime.pressedAtMs || nowMs - runtime.pressedAtMs < RemoteButtonRepeatTiming.initialDelayMs) {
            let outputs = runtime.gesture.handle(.up, nowMs: scheduler.nowMs())
            guard deliverOutputs(runtime.context, outputs) else {
                deliveryDidFail()
                return
            }
            refreshDeadline(for: usage, runtime: runtime)
            return
        }
        runtime.deferredReleaseTask?.cancel()
        runtime.deferredReleaseGeneration &+= 1
        let generation = runtime.deferredReleaseGeneration
        runtime.deferredReleaseTask = scheduler.schedule(releaseGraceMs) { [weak self, weak runtime] in
            guard let self, let runtime,
                  self.runtimes[usage] === runtime,
                  runtime.deferredReleaseGeneration == generation,
                  !self.isUsageActive(usage)
            else { return }
            runtime.deferredReleaseTask = nil
            let outputs = runtime.gesture.handle(.up, nowMs: self.scheduler.nowMs())
            guard self.deliverOutputs(runtime.context, outputs) else {
                self.deliveryDidFail()
                return
            }
            self.refreshDeadline(for: usage, runtime: runtime)
        }
    }

    /// Cancels every runtime-owned task and forgets all in-flight gestures.
    /// The caller uses the returned contexts to balance platform hold/suppression
    /// resources without making those platform concerns part of this coordinator.
    func reset() -> [MultiActionRuntimeResetContext] {
        let contexts = runtimes.keys.sorted().compactMap { usage -> MultiActionRuntimeResetContext? in
            guard let runtime = runtimes[usage] else { return nil }
            runtime.deadlineTask?.cancel()
            runtime.deadlineTask = nil
            runtime.deferredReleaseTask?.cancel()
            runtime.deferredReleaseTask = nil
            runtime.deferredReleaseGeneration &+= 1
            let wasHoldingOutput = runtime.gesture.isHoldingOutput
            _ = runtime.gesture.reset()
            return MultiActionRuntimeResetContext(
                usage: usage,
                button: runtime.context.button,
                wasHoldingOutput: wasHoldingOutput
            )
        }
        runtimes.removeAll()
        return contexts
    }

    private func refreshDeadline(for usage: UInt16, runtime: Runtime) {
        runtime.deadlineTask?.cancel()
        runtime.deadlineTask = nil

        guard runtimes[usage] === runtime else { return }
        guard let deadlineMs = runtime.gesture.nextDeadlineMs else {
            if runtime.gesture.isFinished {
                runtimes.removeValue(forKey: usage)
            }
            return
        }

        let nowMs = scheduler.nowMs()
        let delayMs = deadlineMs > nowMs ? deadlineMs - nowMs : 0
        runtime.deadlineTask = scheduler.schedule(delayMs) { [weak self, weak runtime] in
            guard let self, let runtime,
                  self.runtimes[usage] === runtime,
                  runtime.gesture.nextDeadlineMs == deadlineMs
            else { return }
            let outputs = runtime.gesture.handleDeadline(nowMs: self.scheduler.nowMs())
            guard self.deliverOutputs(runtime.context, outputs) else {
                self.deliveryDidFail()
                return
            }
            self.refreshDeadline(for: usage, runtime: runtime)
        }
    }
}
