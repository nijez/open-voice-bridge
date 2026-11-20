import Foundation

/// Decides when a stopped voice output should be rebuilt.
///
/// CoreAudio delivers configuration changes in bursts — one notification per
/// device in the changed graph — and a device that flaps (a virtual driver whose
/// sample rate is edited, a dock re-enumerating) can repeat them. Rebuilding on
/// every notification would start and stop the engine several times and drop
/// voice audio in between, so the policy collapses a burst into one attempt
/// (debounce), spaces attempts out (minimum interval), and stops trying for a
/// while once the device is clearly gone (suspension) instead of looping.
struct AudioOutputRecoveryPolicy {
    /// How long the graph must stay quiet before the engine is rebuilt.
    let debounce: TimeInterval
    /// Minimum spacing between rebuild attempts.
    let minimumInterval: TimeInterval
    /// Attempts allowed before the policy backs off.
    let maxAttempts: Int
    /// How long to stay quiet after exhausting `maxAttempts`.
    let suspension: TimeInterval

    private(set) var pendingSince: Date?
    private(set) var lastAttempt: Date?
    private(set) var attempts = 0
    private(set) var suspendedUntil: Date?

    init(
        debounce: TimeInterval = 0.5,
        minimumInterval: TimeInterval = 3,
        maxAttempts: Int = 5,
        suspension: TimeInterval = 60
    ) {
        self.debounce = debounce
        self.minimumInterval = minimumInterval
        self.maxAttempts = maxAttempts
        self.suspension = suspension
    }

    /// A configuration change arrived. The earliest pending timestamp wins, so a
    /// continuous stream of notifications cannot postpone the rebuild forever.
    mutating func noteConfigurationChange(now: Date) {
        if pendingSince == nil {
            pendingSince = now
        }
    }

    /// True when the burst has settled, the last attempt is old enough, and the
    /// policy is not backing off.
    func attemptIsDue(now: Date) -> Bool {
        guard let pendingSince else { return false }
        if let suspendedUntil, now < suspendedUntil { return false }
        guard now.timeIntervalSince(pendingSince) >= debounce else { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < minimumInterval {
            return false
        }
        return true
    }

    /// When `attemptIsDue(now:)` can first become true, so the caller can schedule
    /// exactly one wake-up instead of polling. Nil when nothing is pending.
    func nextAttemptDate(now: Date) -> Date? {
        guard let pendingSince else { return nil }
        var due = pendingSince.addingTimeInterval(debounce)
        if let lastAttempt {
            due = max(due, lastAttempt.addingTimeInterval(minimumInterval))
        }
        if let suspendedUntil {
            due = max(due, suspendedUntil)
        }
        return due
    }

    mutating func noteAttempt(now: Date) {
        attempts += 1
        lastAttempt = now
        pendingSince = nil
    }

    /// The device is gone for good (or the engine keeps refusing): stay quiet for
    /// `suspension` and start over with a full attempt budget afterwards.
    mutating func noteExhausted(now: Date) {
        attempts = 0
        suspendedUntil = now.addingTimeInterval(suspension)
        pendingSince = now
    }

    /// The output is playing again — forget the burst, the backoff, and the count.
    mutating func reset() {
        pendingSince = nil
        lastAttempt = nil
        attempts = 0
        suspendedUntil = nil
    }
}
