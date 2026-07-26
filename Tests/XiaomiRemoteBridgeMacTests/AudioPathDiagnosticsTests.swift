import Testing
@testable import XiaomiRemoteBridgeMac

@Suite("Audio path diagnostics")
struct AudioPathDiagnosticsTests {
    @Test func keepsPCMQueueAndPlaybackBoundariesSeparate() {
        var now: UInt64 = 0
        let diagnostics = AudioPathDiagnostics(nowNanos: { now })
        let session = diagnostics.beginSession()
        diagnostics.recordDecoded(samples: [Int16.max, 0, -Int16.max], for: session)
        diagnostics.recordQueueAccepted(samples: [Int16.max, 0, -Int16.max], for: session)

        let watermark = diagnostics.requestPlaybackWatermark(for: session)
        #expect(watermark != nil)
        #expect(diagnostics.requestPlaybackWatermark(for: session) == nil)
        #expect(diagnostics.snapshot().playbackState == .waiting)

        diagnostics.recordPlaybackWatermarkCompleted(watermark!)
        let snapshot = diagnostics.snapshot()
        #expect(snapshot.decoded.bufferCount == 1)
        #expect(snapshot.queued.bufferCount == 1)
        #expect(snapshot.playbackState == .completed)
    }

    @Test func marksAQueuedWatermarkAsUnconfirmedAfterItsDeadline() {
        var now: UInt64 = 0
        let diagnostics = AudioPathDiagnostics(nowNanos: { now })
        let session = diagnostics.beginSession()
        diagnostics.recordQueueAccepted(samples: [1, 2, 3], for: session)
        #expect(diagnostics.requestPlaybackWatermark(for: session) != nil)

        now += 2_000_000_000
        #expect(diagnostics.snapshot().playbackState == .timedOut)
        diagnostics.recordQueueAccepted(samples: [4, 5, 6], for: session)
        #expect(diagnostics.requestPlaybackWatermark(for: session) != nil)
        #expect(diagnostics.snapshot().playbackState == .waiting)
    }

    @Test func doesNotPresentAFlushedShortSessionAsPlaybackSuccess() {
        let diagnostics = AudioPathDiagnostics(nowNanos: { 0 })
        let session = diagnostics.beginSession()
        diagnostics.recordQueueAccepted(samples: [1, 2, 3], for: session)
        _ = diagnostics.requestPlaybackWatermark(for: session)
        diagnostics.endSession(session)

        #expect(diagnostics.snapshot().playbackState == .notObserved)
    }

    @Test func ignoresAnEarlierSessionPlaybackCallback() {
        let diagnostics = AudioPathDiagnostics(nowNanos: { 0 })
        let oldSession = diagnostics.beginSession()
        diagnostics.recordQueueAccepted(samples: [1, 2, 3], for: oldSession)
        let oldWatermark = diagnostics.requestPlaybackWatermark(for: oldSession)!

        let newSession = diagnostics.beginSession()
        diagnostics.recordQueueAccepted(samples: [4, 5, 6], for: newSession)
        let newWatermark = diagnostics.requestPlaybackWatermark(for: newSession)!
        diagnostics.recordPlaybackWatermarkCompleted(oldWatermark)

        #expect(diagnostics.snapshot().playbackState == .waiting)
        #expect(diagnostics.snapshot().completedWatermarkCount == 0)
        diagnostics.recordPlaybackWatermarkCompleted(newWatermark)
        #expect(diagnostics.snapshot().playbackState == .completed)
    }
}
