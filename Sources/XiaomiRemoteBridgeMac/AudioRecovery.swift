import Foundation

enum AudioRecoveryReason: String {
    case devicesChanged = "devices_changed"
    case defaultOutputChanged = "default_output_changed"
    case engineConfigurationChanged = "engine_configuration_changed"
    case streamUnavailable = "stream_unavailable"

    /// Device-list and engine-configuration notifications may be advisory, so the
    /// bound graph is inspected first. Default-output changes and stream failures
    /// restart it even when it still appears healthy.
    var forcesBoundOutputRestart: Bool {
        switch self {
        case .devicesChanged, .engineConfigurationChanged:
            return false
        case .defaultOutputChanged, .streamUnavailable:
            return true
        }
    }
}

enum AudioRecoveryAction: Equatable {
    case inspectBoundOutput
    case restartBoundOutput
}

enum AudioRecoveryPolicy {
    static func action(for reason: AudioRecoveryReason) -> AudioRecoveryAction {
        reason.forcesBoundOutputRestart ? .restartBoundOutput : .inspectBoundOutput
    }

    static func merge(
        _ current: AudioRecoveryReason,
        with new: AudioRecoveryReason
    ) -> AudioRecoveryReason {
        current.forcesBoundOutputRestart && !new.forcesBoundOutputRestart
            ? current
            : new
    }
}

struct AudioRecoverySchedule: Equatable {
    let generation: UInt64
    let attempt: Int
    let delay: TimeInterval
}

/// Keeps automatic audio recovery single-flight and invalidates delayed work after a
/// manual device change or application shutdown.
struct AudioRecoveryState {
    private static let retryDelays: [TimeInterval] = [0.25, 0.5, 1.0]

    private(set) var generation: UInt64 = 0
    private(set) var pendingGeneration: UInt64?
    private(set) var pendingAttempt: Int?
    private(set) var retryIndex = 0
    private(set) var isRecovering = false

    var hasWork: Bool {
        pendingGeneration != nil || isRecovering
    }

    mutating func request(delay: TimeInterval) -> AudioRecoverySchedule? {
        guard !hasWork else { return nil }
        retryIndex = 0
        return makeSchedule(attempt: 0, delay: delay)
    }

    mutating func begin(generation: UInt64) -> Bool {
        guard pendingGeneration == generation else { return false }
        pendingGeneration = nil
        pendingAttempt = nil
        isRecovering = true
        return true
    }

    mutating func expedite(delay: TimeInterval) -> AudioRecoverySchedule? {
        guard pendingGeneration != nil, let pendingAttempt else { return nil }
        return makeSchedule(attempt: pendingAttempt, delay: delay)
    }

    mutating func retry() -> AudioRecoverySchedule? {
        guard pendingGeneration == nil, isRecovering else { return nil }
        guard retryIndex < Self.retryDelays.count else {
            isRecovering = false
            return nil
        }

        let delay = Self.retryDelays[retryIndex]
        retryIndex += 1
        isRecovering = false
        return makeSchedule(attempt: retryIndex, delay: delay)
    }

    mutating func succeeded() {
        isRecovering = false
        retryIndex = 0
    }

    mutating func cancel() {
        generation &+= 1
        pendingGeneration = nil
        pendingAttempt = nil
        retryIndex = 0
        isRecovering = false
    }

    private mutating func makeSchedule(
        attempt: Int,
        delay: TimeInterval
    ) -> AudioRecoverySchedule {
        generation &+= 1
        pendingGeneration = generation
        pendingAttempt = attempt
        return AudioRecoverySchedule(
            generation: generation,
            attempt: attempt,
            delay: delay
        )
    }
}
