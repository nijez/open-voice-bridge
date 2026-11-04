import Foundation

struct MultiActionGestureConfiguration: Equatable {
    let hasDoublePress: Bool
    let hasLongPress: Bool
    let doubleClickMs: UInt64
    let longPressMs: UInt64

    init(
        hasDoublePress: Bool,
        hasLongPress: Bool,
        doubleClickMs: Int,
        longPressMs: Int
    ) {
        let timing = MultiActionTiming.normalized(
            doubleClickMs: doubleClickMs,
            longPressMs: longPressMs
        )
        self.hasDoublePress = hasDoublePress
        self.hasLongPress = hasLongPress
        self.doubleClickMs = UInt64(timing.doubleClickMs)
        self.longPressMs = UInt64(timing.longPressMs)
    }
}

enum MultiActionGestureOutput: Equatable {
    case performSingle(count: Int)
    case performDouble
    case beginSingleHold(precedingTapCount: Int)
    case beginLongHold
    case endHold
}

/// Pure edge/timer state machine for one physical button. It owns no timers and
/// injects no events: the runtime coordinator schedules `nextDeadlineMs` and
/// feeds it back through `handleDeadline`; the HID adapter delivers the effects.
struct MultiActionButtonGesture {
    private enum Phase: Equatable {
        case idle
        case firstDown(startMs: UInt64)
        case waitingSecond(firstDownMs: UInt64, deadlineMs: UInt64)
        case secondDown(startMs: UInt64)
        case holdingLong
        case holdingSingle
        case recentSingleTap(deadlineMs: UInt64)
    }

    let configuration: MultiActionGestureConfiguration
    private var phase: Phase = .idle

    init(configuration: MultiActionGestureConfiguration) {
        self.configuration = configuration
    }

    var nextDeadlineMs: UInt64? {
        switch phase {
        case .idle, .holdingLong, .holdingSingle:
            return nil
        case .firstDown(let startMs):
            return Self.adding(
                configuration.hasLongPress
                    ? configuration.longPressMs
                    : configuration.doubleClickMs,
                to: startMs
            )
        case .waitingSecond(_, let deadlineMs), .recentSingleTap(let deadlineMs):
            return deadlineMs
        case .secondDown(let startMs):
            return Self.adding(
                configuration.hasLongPress
                    ? configuration.longPressMs
                    : configuration.doubleClickMs,
                to: startMs
            )
        }
    }

    var isFinished: Bool {
        if case .idle = phase { return true }
        return false
    }

    var isHoldingOutput: Bool {
        switch phase {
        case .holdingLong, .holdingSingle: return true
        default: return false
        }
    }

    mutating func handle(_ edge: RemoteEventEdge, nowMs: UInt64) -> [MultiActionGestureOutput] {
        switch edge {
        case .down:
            return handleDown(nowMs: nowMs)
        case .up:
            return handleUp(nowMs: nowMs)
        }
    }

    mutating func handleDeadline(nowMs: UInt64) -> [MultiActionGestureOutput] {
        guard let deadline = nextDeadlineMs, nowMs >= deadline else { return [] }

        switch phase {
        case .firstDown:
            if configuration.hasLongPress {
                phase = .holdingLong
                return [.beginLongHold]
            }
            phase = .holdingSingle
            return [.beginSingleHold(precedingTapCount: 0)]

        case .waitingSecond:
            phase = .idle
            return [.performSingle(count: 1)]

        case .secondDown:
            phase = .holdingSingle
            return [.beginSingleHold(precedingTapCount: 1)]

        case .recentSingleTap:
            phase = .idle
            return []

        case .idle, .holdingLong, .holdingSingle:
            return []
        }
    }

    /// A different physical button resolves only a completed first tap that is
    /// waiting for a possible double press. Held keys remain independent.
    mutating func interrupt() -> [MultiActionGestureOutput] {
        switch phase {
        case .waitingSecond:
            phase = .idle
            return [.performSingle(count: 1)]
        case .recentSingleTap:
            phase = .idle
            return []
        default:
            return []
        }
    }

    mutating func reset() -> [MultiActionGestureOutput] {
        let outputs: [MultiActionGestureOutput]
        switch phase {
        case .holdingLong, .holdingSingle:
            outputs = [.endHold]
        default:
            outputs = []
        }
        phase = .idle
        return outputs
    }

    private mutating func handleDown(nowMs: UInt64) -> [MultiActionGestureOutput] {
        switch phase {
        case .idle:
            if !configuration.hasDoublePress && !configuration.hasLongPress {
                phase = .holdingSingle
                return [.beginSingleHold(precedingTapCount: 0)]
            }
            phase = .firstDown(startMs: nowMs)
            return []

        case .recentSingleTap(let deadlineMs):
            // A window excludes its deadline, matching handleDeadline's >=.
            if nowMs < deadlineMs {
                phase = .holdingSingle
                return [.beginSingleHold(precedingTapCount: 0)]
            }
            phase = .firstDown(startMs: nowMs)
            return []

        case .waitingSecond(_, let deadlineMs):
            if nowMs < deadlineMs {
                phase = .secondDown(startMs: nowMs)
                return []
            }
            phase = .firstDown(startMs: nowMs)
            return [.performSingle(count: 1)]

        case .firstDown, .secondDown, .holdingLong, .holdingSingle:
            // Repeated downs from one physical hold are not new gestures.
            return []
        }
    }

    private mutating func handleUp(nowMs: UInt64) -> [MultiActionGestureOutput] {
        switch phase {
        case .firstDown(let startMs):
            let heldMs = Self.elapsed(from: startMs, to: nowMs)
            if configuration.hasLongPress, heldMs >= configuration.longPressMs {
                phase = .idle
                return [.beginLongHold, .endHold]
            }

            if configuration.hasDoublePress,
               heldMs < configuration.doubleClickMs {
                let deadline = Self.adding(configuration.doubleClickMs, to: startMs)
                phase = .waitingSecond(firstDownMs: startMs, deadlineMs: deadline)
                return []
            }

            phase = recentTapPhase(after: nowMs)
            return [.performSingle(count: 1)]

        case .secondDown(let startMs):
            let threshold = configuration.hasLongPress
                ? configuration.longPressMs
                : configuration.doubleClickMs
            if Self.elapsed(from: startMs, to: nowMs) >= threshold {
                phase = .idle
                return [.beginSingleHold(precedingTapCount: 1), .endHold]
            }
            phase = .idle
            return [.performDouble]

        case .holdingLong:
            phase = .idle
            return [.endHold]

        case .holdingSingle:
            phase = recentTapPhase(after: nowMs)
            return [.endHold]

        case .idle, .waitingSecond, .recentSingleTap:
            // Orphan/repeated releases cannot complete a gesture.
            return []
        }
    }

    private func recentTapPhase(after nowMs: UInt64) -> Phase {
        guard configuration.hasLongPress else { return .idle }
        return .recentSingleTap(
            deadlineMs: Self.adding(configuration.doubleClickMs, to: nowMs)
        )
    }

    private static func elapsed(from start: UInt64, to now: UInt64) -> UInt64 {
        now >= start ? now - start : 0
    }

    private static func adding(_ interval: UInt64, to start: UInt64) -> UInt64 {
        let (value, overflow) = start.addingReportingOverflow(interval)
        return overflow ? UInt64.max : value
    }
}
