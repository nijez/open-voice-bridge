import Foundation

/// UI refresh policy for RC003 audio diagnostics. The repeating refresh is
/// deliberately session-scoped: an idle bridge must not keep the main run loop
/// awake just to republish unchanged diagnostic state.
enum AudioDiagnosticsRefreshPolicy {
    static let activeRefreshInterval: TimeInterval = 0.1
    static let activeRefreshTolerance: TimeInterval = 0.02
    static let settlementDelay: TimeInterval = 1.05
}

/// Owns every scheduled diagnostics refresh. `BridgeAppModel` emits lifecycle
/// events; it never manages a Timer or delayed settlement directly.
final class AudioDiagnosticsRefreshController {
    enum Phase: Equatable {
        case idle
        case active
        case settling
    }

    typealias Cancellation = () -> Void
    typealias RepeatingScheduler = (
        TimeInterval,
        TimeInterval,
        @escaping () -> Void
    ) -> Cancellation
    typealias OneShotScheduler = (TimeInterval, @escaping () -> Void) -> Cancellation

    private(set) var phase: Phase = .idle
    var hasRepeatingRefresh: Bool { cancelRepeating != nil }
    var hasPendingSettlement: Bool { cancelSettlement != nil }

    private let refresh: () -> Void
    private let scheduleRepeating: RepeatingScheduler
    private let scheduleOneShot: OneShotScheduler
    private var cancelRepeating: Cancellation?
    private var cancelSettlement: Cancellation?
    private var generation: UInt64 = 0

    init(
        refresh: @escaping () -> Void,
        scheduleRepeating: @escaping RepeatingScheduler = { interval, tolerance, action in
            let timer = Timer(timeInterval: interval, repeats: true) { _ in action() }
            timer.tolerance = tolerance
            RunLoop.main.add(timer, forMode: .common)
            return { timer.invalidate() }
        },
        scheduleOneShot: @escaping OneShotScheduler = { delay, action in
            let timer = Timer(timeInterval: delay, repeats: false) { _ in action() }
            RunLoop.main.add(timer, forMode: .common)
            return { timer.invalidate() }
        }
    ) {
        self.refresh = refresh
        self.scheduleRepeating = scheduleRepeating
        self.scheduleOneShot = scheduleOneShot
    }

    deinit {
        cancelRepeating?()
        cancelSettlement?()
    }

    func beginActiveSession() {
        reset(refreshNow: false)
        phase = .active
        let callbackGeneration = generation
        refresh()
        cancelRepeating = scheduleRepeating(
            AudioDiagnosticsRefreshPolicy.activeRefreshInterval,
            AudioDiagnosticsRefreshPolicy.activeRefreshTolerance
        ) { [weak self] in
            guard let self,
                  self.generation == callbackGeneration,
                  self.phase == .active
            else { return }
            self.refresh()
        }
    }

    func endActiveSession() {
        guard phase == .active else { return }
        generation &+= 1
        let callbackGeneration = generation
        cancelRepeating?()
        cancelRepeating = nil
        phase = .settling
        refresh()
        cancelSettlement = scheduleOneShot(
            AudioDiagnosticsRefreshPolicy.settlementDelay
        ) { [weak self] in
            guard let self,
                  self.generation == callbackGeneration,
                  self.phase == .settling
            else { return }
            self.cancelSettlement = nil
            self.phase = .idle
            self.refresh()
        }
    }

    func reset(refreshNow: Bool = true) {
        generation &+= 1
        cancelRepeating?()
        cancelRepeating = nil
        cancelSettlement?()
        cancelSettlement = nil
        phase = .idle
        if refreshNow { refresh() }
    }
}

/// A deliberately bounded description of the parts of the voice path this
/// application can observe. It never claims that a virtual-audio driver, an
/// input method, or a focused text field consumed the audio.
struct AudioLevelSnapshot: Equatable {
    let rmsDBFS: Double?
    let peakDBFS: Double?
    let bufferCount: Int
    let sampleCount: Int
    let lastActivityAge: TimeInterval?

    static let empty = AudioLevelSnapshot(
        rmsDBFS: nil,
        peakDBFS: nil,
        bufferCount: 0,
        sampleCount: 0,
        lastActivityAge: nil
    )

    var meterValue: Double {
        guard let rmsDBFS, isRecent else { return 0 }
        return min(1, max(0, (rmsDBFS + 60) / 60))
    }

    var isRecent: Bool {
        guard let lastActivityAge else { return false }
        return lastActivityAge < 1.0
    }

    var levelText: String {
        guard let rmsDBFS, let peakDBFS else { return "—" }
        return String(format: "%.0f / %.0f dBFS", rmsDBFS, peakDBFS)
    }
}

enum AudioPlaybackWatermarkState: Equatable {
    case idle
    case waiting
    case completed
    case notObserved
    case timedOut

    var displayText: String {
        switch self {
        case .idle:
            return "等待语音"
        case .waiting:
            return "等待播放回执"
        case .completed:
            return "已完成到输出节点"
        case .notObserved:
            return "语音已结束（未取得回执）"
        case .timedOut:
            return "回执超时（未确认）"
        }
    }
}

struct AudioPathSnapshot: Equatable {
    let decoded: AudioLevelSnapshot
    let queued: AudioLevelSnapshot
    let rejectedQueueCount: Int
    let playbackState: AudioPlaybackWatermarkState
    let completedWatermarkCount: Int

    static let empty = AudioPathSnapshot(
        decoded: .empty,
        queued: .empty,
        rejectedQueueCount: 0,
        playbackState: .idle,
        completedWatermarkCount: 0
    )

    var decodedStatusText: String {
        guard decoded.bufferCount > 0 else { return "未收到 PCM" }
        return "\(decoded.levelText) · \(decoded.bufferCount) 帧"
    }

    var queuedStatusText: String {
        guard queued.bufferCount > 0 else {
            return rejectedQueueCount == 0 ? "未向输出设备排队" : "排队失败 \(rejectedQueueCount) 次"
        }
        let failure = rejectedQueueCount == 0 ? "" : " · 失败 \(rejectedQueueCount)"
        return "\(queued.levelText) · \(queued.bufferCount) 段\(failure)"
    }
}

/// Thread-safe, in-memory-only audio-path telemetry. PCM content is never
/// retained: each update reduces a buffer to RMS/peak plus counters before
/// taking the lock. UI code reads a coherent snapshot at a much lower rate.
final class AudioPathDiagnostics {
    struct Session: Equatable {
        fileprivate let id: UInt64
    }

    struct PlaybackWatermark: Equatable {
        fileprivate let session: Session
        fileprivate let id: UInt64
    }

    static let playbackWatermarkInterval: TimeInterval = 0.25
    static let playbackWatermarkTimeout: TimeInterval = 1.5

    private struct MutableLevel {
        var rmsDBFS: Double?
        var peakDBFS: Double?
        var bufferCount = 0
        var sampleCount = 0
        var lastActivityNanos: UInt64?

        mutating func record(samples: [Int16], at now: UInt64) {
            guard !samples.isEmpty else { return }
            let level = Self.measure(samples)
            rmsDBFS = level.rms
            peakDBFS = level.peak
            bufferCount += 1
            sampleCount += samples.count
            lastActivityNanos = now
        }

        func snapshot(now: UInt64) -> AudioLevelSnapshot {
            AudioLevelSnapshot(
                rmsDBFS: rmsDBFS,
                peakDBFS: peakDBFS,
                bufferCount: bufferCount,
                sampleCount: sampleCount,
                lastActivityAge: lastActivityNanos.map { Self.age(secondsFrom: $0, to: now) }
            )
        }

        private static func measure(_ samples: [Int16]) -> (rms: Double, peak: Double) {
            var sumSquares = 0.0
            var peak = 0.0
            for sample in samples {
                let normalized = Double(sample) / 32_768.0
                sumSquares += normalized * normalized
                peak = max(peak, abs(normalized))
            }
            let rms = sqrt(sumSquares / Double(samples.count))
            return (dbfs(rms), dbfs(peak))
        }

        private static func dbfs(_ value: Double) -> Double {
            20 * log10(max(value, 0.000_015_848_931_9))
        }

        private static func age(secondsFrom then: UInt64, to now: UInt64) -> TimeInterval {
            guard now >= then else { return 0 }
            return TimeInterval(now - then) / 1_000_000_000
        }
    }

    private let lock = NSLock()
    private let nowNanos: () -> UInt64
    private var decoded = MutableLevel()
    private var queued = MutableLevel()
    private var rejectedQueueCount = 0
    private var currentSession: Session?
    private var nextSessionID: UInt64 = 0
    private var nextWatermarkID: UInt64 = 0
    private var playbackWatermarkPending: PlaybackWatermark?
    private var playbackWatermarkPendingAt: UInt64?
    private var lastPlaybackWatermarkRequestAt: UInt64?
    private var lastPlaybackWatermarkCompletedAt: UInt64?
    private var completedWatermarkCount = 0
    private var sessionEndedWithoutWatermark = false

    init(nowNanos: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.nowNanos = nowNanos
    }

    /// Starts an RC003-only diagnostic session. Completion callbacks are tied
    /// to this opaque token so a late callback cannot update a later session.
    @discardableResult
    func beginSession() -> Session {
        lock.lock()
        nextSessionID &+= 1
        let session = Session(id: nextSessionID)
        currentSession = session
        resetTelemetry()
        lock.unlock()
        return session
    }

    /// Clears the visible diagnostics without creating a voice session. Used
    /// while changing output routing, before any RC003 voice stream starts.
    func reset() {
        lock.lock()
        currentSession = nil
        resetTelemetry()
        lock.unlock()
    }

    private func resetTelemetry() {
        decoded = MutableLevel()
        queued = MutableLevel()
        rejectedQueueCount = 0
        playbackWatermarkPending = nil
        playbackWatermarkPendingAt = nil
        lastPlaybackWatermarkRequestAt = nil
        lastPlaybackWatermarkCompletedAt = nil
        completedWatermarkCount = 0
        sessionEndedWithoutWatermark = false
    }

    func recordDecoded(samples: [Int16], for session: Session) {
        let now = nowNanos()
        lock.lock()
        guard currentSession == session else {
            lock.unlock()
            return
        }
        decoded.record(samples: samples, at: now)
        lock.unlock()
    }

    func recordQueueAccepted(samples: [Int16], for session: Session) {
        let now = nowNanos()
        lock.lock()
        guard currentSession == session else {
            lock.unlock()
            return
        }
        queued.record(samples: samples, at: now)
        lock.unlock()
    }

    func recordQueueRejected(for session: Session) {
        lock.lock()
        guard currentSession == session else {
            lock.unlock()
            return
        }
        rejectedQueueCount += 1
        lock.unlock()
    }

    /// Returns true at most once per watermark interval. The caller may attach
    /// a `.dataPlayedBack` callback to this one buffer; all other PCM buffers
    /// remain callback-free, avoiding a 60+ Hz callback stream.
    func requestPlaybackWatermark(for session: Session) -> PlaybackWatermark? {
        let now = nowNanos()
        lock.lock()
        defer { lock.unlock() }
        guard currentSession == session else { return nil }
        if let pendingAt = playbackWatermarkPendingAt {
            guard elapsed(now, since: pendingAt) >= Self.playbackWatermarkTimeout else { return nil }
            // A missing callback is not terminal. Drop only this expired marker
            // and permit a later PCM buffer to carry a fresh, independent one.
            playbackWatermarkPending = nil
            playbackWatermarkPendingAt = nil
        }
        guard let last = lastPlaybackWatermarkRequestAt else {
            return makePlaybackWatermark(session: session, at: now)
        }
        guard elapsed(now, since: last) >= Self.playbackWatermarkInterval else { return nil }
        return makePlaybackWatermark(session: session, at: now)
    }

    private func makePlaybackWatermark(session: Session, at now: UInt64) -> PlaybackWatermark {
        nextWatermarkID &+= 1
        let watermark = PlaybackWatermark(session: session, id: nextWatermarkID)
        playbackWatermarkPending = watermark
        playbackWatermarkPendingAt = now
        lastPlaybackWatermarkRequestAt = now
        return watermark
    }

    func recordPlaybackWatermarkCompleted(_ watermark: PlaybackWatermark) {
        let now = nowNanos()
        lock.lock()
        guard currentSession == watermark.session,
              playbackWatermarkPending == watermark
        else {
            lock.unlock()
            return
        }
        playbackWatermarkPending = nil
        playbackWatermarkPendingAt = nil
        lastPlaybackWatermarkCompletedAt = now
        completedWatermarkCount += 1
        sessionEndedWithoutWatermark = false
        lock.unlock()
    }

    func cancelPlaybackWatermark(for session: Session) {
        lock.lock()
        guard currentSession == session else {
            lock.unlock()
            return
        }
        playbackWatermarkPending = nil
        playbackWatermarkPendingAt = nil
        lock.unlock()
    }

    func endSession(_ session: Session) {
        lock.lock()
        guard currentSession == session else {
            lock.unlock()
            return
        }
        if queued.bufferCount > 0, lastPlaybackWatermarkCompletedAt == nil {
            sessionEndedWithoutWatermark = true
        }
        currentSession = nil
        playbackWatermarkPending = nil
        playbackWatermarkPendingAt = nil
        lock.unlock()
    }

    func snapshot() -> AudioPathSnapshot {
        let now = nowNanos()
        lock.lock()
        defer { lock.unlock() }
        let playbackState: AudioPlaybackWatermarkState
        if queued.bufferCount == 0 {
            playbackState = .idle
        } else if sessionEndedWithoutWatermark {
            playbackState = .notObserved
        } else if let pending = playbackWatermarkPendingAt {
            playbackState = elapsed(now, since: pending) >= Self.playbackWatermarkTimeout ? .timedOut : .waiting
        } else if lastPlaybackWatermarkCompletedAt != nil {
            playbackState = .completed
        } else {
            playbackState = .waiting
        }
        return AudioPathSnapshot(
            decoded: decoded.snapshot(now: now),
            queued: queued.snapshot(now: now),
            rejectedQueueCount: rejectedQueueCount,
            playbackState: playbackState,
            completedWatermarkCount: completedWatermarkCount
        )
    }

    private func elapsed(_ now: UInt64, since then: UInt64) -> TimeInterval {
        guard now >= then else { return 0 }
        return TimeInterval(now - then) / 1_000_000_000
    }
}
