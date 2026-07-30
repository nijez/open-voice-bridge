import Testing
@testable import XiaomiRemoteBridgeMac

@Suite("Local mic arbiter")
struct LocalMicArbiterTests {
    @Test func defaultOnIdleDoesNotScheduleLivenessPolling() {
        for _ in 0..<10_000 {
            #expect(!LocalMicLivenessPolicy.shouldRun(enabled: true, isCapturing: false))
        }
        #expect(LocalMicLivenessPolicy.shouldRun(enabled: true, isCapturing: true))
        #expect(!LocalMicLivenessPolicy.shouldRun(enabled: false, isCapturing: true))
    }

    private func readyArbiter() -> LocalMicArbiter {
        var arbiter = LocalMicArbiter()
        _ = arbiter.handle(.setEnabled(true))
        _ = arbiter.handle(.setReady(true))
        return arbiter
    }

    @Test func oneStartAndStopPerPressWithIdempotentEdges() {
        var arbiter = readyArbiter()
        #expect(arbiter.handle(.physicalFnDown) == .startCapture)
        #expect(arbiter.handle(.physicalFnDown) == .none)
        #expect(arbiter.capturing)
        #expect(arbiter.handle(.physicalFnUp) == .stopCapture)
        #expect(arbiter.handle(.physicalFnUp) == .none)
        #expect(!arbiter.capturing)
    }

    @Test func remotePreemptsAndResidualFnDoesNotRestart() {
        var arbiter = readyArbiter()
        #expect(arbiter.handle(.physicalFnDown) == .startCapture)
        #expect(arbiter.handle(.remoteVoiceStart) == .stopCapture)
        #expect(arbiter.handle(.remoteVoiceStop) == .none)
        #expect(!arbiter.capturing)
        #expect(arbiter.handle(.physicalFnUp) == .none)
    }

    @Test func neverCapturesWhileRemoteActiveThenFreshPressWorks() {
        var arbiter = readyArbiter()
        _ = arbiter.handle(.remoteVoiceStart)
        #expect(arbiter.handle(.physicalFnDown) == .none)
        #expect(arbiter.handle(.remoteVoiceStop) == .none)
        #expect(arbiter.handle(.physicalFnUp) == .none)
        #expect(arbiter.handle(.physicalFnDown) == .startCapture)
    }

    @Test func becomingReadyMidHoldRequiresFreshPress() {
        var arbiter = LocalMicArbiter()
        #expect(arbiter.handle(.physicalFnDown) == .none)
        _ = arbiter.handle(.setEnabled(true))
        _ = arbiter.handle(.setReady(true))
        #expect(!arbiter.capturing)
        #expect(arbiter.handle(.physicalFnUp) == .none)
        #expect(arbiter.handle(.physicalFnDown) == .startCapture)
    }

    @Test func failsClosedOnDisableRevokeAndTeardown() {
        var disabled = readyArbiter()
        _ = disabled.handle(.physicalFnDown)
        #expect(disabled.handle(.setEnabled(false)) == .stopCapture)

        var revoked = readyArbiter()
        _ = revoked.handle(.physicalFnDown)
        #expect(revoked.handle(.setReady(false)) == .stopCapture)

        var tornDown = readyArbiter()
        _ = tornDown.handle(.physicalFnDown)
        #expect(tornDown.handle(.teardown) == .stopCapture)
        #expect(!tornDown.capturing)
        #expect(!tornDown.fnHeld)
        #expect(!tornDown.remoteActive)
    }

    @Test func interleavedRoundsStayMutuallyExclusive() {
        var arbiter = readyArbiter()
        let commands: [LocalMicCommand] = [
            arbiter.handle(.physicalFnDown),
            arbiter.handle(.physicalFnUp),
            arbiter.handle(.physicalFnDown),
            arbiter.handle(.remoteVoiceStart),
            arbiter.handle(.remoteVoiceStop),
            arbiter.handle(.physicalFnUp),
            arbiter.handle(.physicalFnDown),
            arbiter.handle(.physicalFnUp),
        ]
        #expect(commands == [
            .startCapture, .stopCapture,
            .startCapture, .stopCapture, .none, .none,
            .startCapture, .stopCapture,
        ])
        #expect(!arbiter.capturing)
        #expect(!arbiter.fnHeld)
        #expect(!arbiter.remoteActive)
    }

    @Test func rc003SourcePreMarkerBlocksTheRemappedFnEdge() {
        var arbiter = readyArbiter()
        #expect(arbiter.handle(.remoteSourceDown) == .none)
        #expect(arbiter.handle(.physicalFnDown) == .none)
        #expect(!arbiter.capturing)
        #expect(arbiter.handle(.remoteSourceUp) == .none)
        #expect(arbiter.handle(.physicalFnUp) == .none)
    }

    @Test func lateRc003SourceEdgePreemptsAndResidualFnDoesNotRestart() {
        var arbiter = readyArbiter()
        #expect(arbiter.handle(.physicalFnDown) == .startCapture)
        #expect(arbiter.handle(.remoteSourceDown) == .stopCapture)
        #expect(arbiter.handle(.remoteSourceUp) == .none)
        #expect(!arbiter.capturing)
        #expect(arbiter.handle(.physicalFnUp) == .none)
    }

    @Test func fnMonitorDisruptionStopsAndRequiresFreshPress() {
        var arbiter = readyArbiter()
        #expect(arbiter.handle(.physicalFnDown) == .startCapture)
        #expect(arbiter.handle(.functionMonitorDisrupted) == .stopCapture)
        #expect(!arbiter.fnHeld)
        #expect(arbiter.handle(.physicalFnUp) == .none)
        #expect(arbiter.handle(.physicalFnDown) == .startCapture)
    }

    @Test func disableClearsHeldFnSoReEnableIsNotSwallowed() {
        var arbiter = readyArbiter()
        _ = arbiter.handle(.physicalFnDown)
        #expect(arbiter.handle(.setEnabled(false)) == .stopCapture)
        #expect(!arbiter.fnHeld)
        _ = arbiter.handle(.setEnabled(true))
        _ = arbiter.handle(.setReady(true))
        #expect(arbiter.handle(.physicalFnDown) == .startCapture)
    }

    @Test func disableClearsStaleRemoteSourceMarker() {
        var arbiter = readyArbiter()
        _ = arbiter.handle(.remoteSourceDown)
        _ = arbiter.handle(.setEnabled(false))
        _ = arbiter.handle(.setEnabled(true))
        _ = arbiter.handle(.setReady(true))
        #expect(!arbiter.remoteSourceActive)
        #expect(arbiter.handle(.physicalFnDown) == .startCapture)
    }
}

@Suite("RC003 voice-key tracker")
struct RemoteVoiceKeyTrackerTests {
    private let usage = RemoteVoiceFunctionMappingPolicy.remoteVoiceKeyUsage

    @Test func debouncesF5UsageIntoOneEdge() {
        var tracker = RemoteVoiceKeyTracker()
        #expect(tracker.update(usages: Set([0x28, usage])) == .down)
        #expect(tracker.update(usages: Set([usage])) == nil)
        #expect(tracker.update(usages: Set([0x28])) == .up)
        #expect(tracker.update(usages: Set<UInt16>()) == nil)
        #expect(!tracker.isDown)
    }

    @Test func releaseEmitsBalancingUpOnlyWhenHeld() {
        var tracker = RemoteVoiceKeyTracker()
        // Not held: release is a no-op.
        #expect(tracker.release() == nil)
        // Held (reader stop / mapping switch / device removal mid-press): release
        // yields exactly one balancing .up and clears the held state.
        _ = tracker.update(usages: Set([usage]))
        #expect(tracker.isDown)
        #expect(tracker.release() == .up)
        #expect(!tracker.isDown)
        #expect(tracker.release() == nil)
    }
}

@Suite("Local mic session router")
struct LocalMicSampleRouterTests {
    @Test func onlyAcceptsTheActiveSessionToken() {
        var router = LocalMicSampleRouter()
        let first = router.begin()
        #expect(router.accepts(first))
        router.invalidate()
        #expect(!router.accepts(first))
        let second = router.begin()
        #expect(first != second)
        #expect(!router.accepts(first))
        #expect(router.accepts(second))
    }
}

@Suite("Local mic gate")
struct LocalMicGateTests {
    @Test func admitsOnlyWhenEveryConditionHolds() {
        #expect(LocalMicGate.block(
            enabled: true, micAuthorized: true, fnMonitorRunning: true,
            remoteSourceReaderReady: true,
            outputRunning: true, outputUID: "BlackHole2ch",
            resolvedInputUID: "BuiltInMic", captureEngineHealthy: true
        ) == nil)
    }

    @Test func failsClosedOnEachMissingCondition() {
        #expect(LocalMicGate.block(
            enabled: false, micAuthorized: true, fnMonitorRunning: true,
            remoteSourceReaderReady: true,
            outputRunning: true, outputUID: "BlackHole2ch",
            resolvedInputUID: "BuiltInMic", captureEngineHealthy: true
        ) == .disabled)
        #expect(LocalMicGate.block(
            enabled: true, micAuthorized: false, fnMonitorRunning: true,
            remoteSourceReaderReady: true,
            outputRunning: true, outputUID: "BlackHole2ch",
            resolvedInputUID: "BuiltInMic", captureEngineHealthy: true
        ) == .micPermission)
        #expect(LocalMicGate.block(
            enabled: true, micAuthorized: true, fnMonitorRunning: false,
            remoteSourceReaderReady: true,
            outputRunning: true, outputUID: "BlackHole2ch",
            resolvedInputUID: "BuiltInMic", captureEngineHealthy: true
        ) == .fnMonitor)
        #expect(LocalMicGate.block(
            enabled: true, micAuthorized: true, fnMonitorRunning: true,
            remoteSourceReaderReady: false,
            outputRunning: true, outputUID: "BlackHole2ch",
            resolvedInputUID: "BuiltInMic", captureEngineHealthy: true
        ) == .remoteReader)
        #expect(LocalMicGate.block(
            enabled: true, micAuthorized: true, fnMonitorRunning: true,
            remoteSourceReaderReady: true,
            outputRunning: false, outputUID: "BlackHole2ch",
            resolvedInputUID: "BuiltInMic", captureEngineHealthy: true
        ) == .outputMissing)
        #expect(LocalMicGate.block(
            enabled: true, micAuthorized: true, fnMonitorRunning: true,
            remoteSourceReaderReady: true,
            outputRunning: true, outputUID: "BlackHole2ch",
            resolvedInputUID: nil, captureEngineHealthy: true
        ) == .inputMissing)
        #expect(LocalMicGate.block(
            enabled: true, micAuthorized: true, fnMonitorRunning: true,
            remoteSourceReaderReady: true,
            outputRunning: true, outputUID: "BlackHole2ch",
            resolvedInputUID: "BlackHole2ch", captureEngineHealthy: true
        ) == .sameDevice)
        #expect(LocalMicGate.block(
            enabled: true, micAuthorized: true, fnMonitorRunning: true,
            remoteSourceReaderReady: true,
            outputRunning: true, outputUID: "BlackHole2ch",
            resolvedInputUID: "BuiltInMic", captureEngineHealthy: false
        ) == .captureEngine)
    }
}

@Suite("RC003 device lifecycle")
struct RemoteDeviceLifecycleTests {
    @Test func openPipelineIsAHealthyWatcherWithNoDevice() {
        var lifecycle = RemoteDeviceLifecycle()
        #expect(!lifecycle.pipelineReady)
        lifecycle.openPipeline()
        #expect(lifecycle.pipelineReady)
        #expect(!lifecycle.devicePresent)
        #expect(lifecycle.activeGeneration == nil)
    }

    @Test func matchWhilePipelineClosedIsIgnored() {
        var lifecycle = RemoteDeviceLifecycle()
        #expect(lifecycle.matched(openSucceeded: true) == .ignored)
        #expect(!lifecycle.devicePresent)
    }

    @Test func matchOpenFailureIsUnreadableAndNeverPresent() {
        var lifecycle = RemoteDeviceLifecycle()
        lifecycle.openPipeline()
        #expect(lifecycle.matched(openSucceeded: false) == .unreadable)
        #expect(!lifecycle.devicePresent)
        #expect(lifecycle.pipelineReady)
    }

    @Test func removalInvalidatesGenerationThenReconnectMintsANewOne() {
        var lifecycle = RemoteDeviceLifecycle()
        lifecycle.openPipeline()
        guard case let .present(gen1) = lifecycle.matched(openSucceeded: true) else {
            Issue.record("first match should yield a generation")
            return
        }
        #expect(lifecycle.accepts(generation: gen1))
        #expect(lifecycle.removed() == gen1)
        #expect(!lifecycle.devicePresent)
        #expect(!lifecycle.accepts(generation: gen1))       // stale report dropped
        #expect(lifecycle.removed() == nil)                 // idempotent removal
        guard case let .present(gen2) = lifecycle.matched(openSucceeded: true) else {
            Issue.record("reconnect should yield a fresh generation")
            return
        }
        #expect(gen2 != gen1)
        #expect(lifecycle.accepts(generation: gen2))
        #expect(!lifecycle.accepts(generation: gen1))       // superseded generation stays rejected
    }

    @Test func removalBalancesTheHeldKeyAndDropsTheStaleReport() {
        var lifecycle = RemoteDeviceLifecycle()
        lifecycle.openPipeline()
        guard case let .present(gen) = lifecycle.matched(openSucceeded: true) else {
            Issue.record("match should yield a generation")
            return
        }
        var tracker = RemoteVoiceKeyTracker()
        let usages = Set([RemoteVoiceFunctionMappingPolicy.remoteVoiceKeyUsage])
        #expect(lifecycle.accepts(generation: gen))
        #expect(tracker.update(usages: usages) == .down)    // key down while present
        #expect(lifecycle.removed() == gen)                 // invalidate FIRST
        #expect(tracker.release() == .up)                   // THEN balance the held key
        #expect(!lifecycle.accepts(generation: gen))        // late report is rejected, never re-arms
    }

    @Test func secondMatchWhilePresentIsIgnored() {
        var lifecycle = RemoteDeviceLifecycle()
        lifecycle.openPipeline()
        guard case let .present(gen1) = lifecycle.matched(openSucceeded: true) else {
            Issue.record("initial adopt should yield a generation")
            return
        }
        #expect(lifecycle.matched(openSucceeded: true) == .ignored)
        #expect(lifecycle.accepts(generation: gen1))
    }

    @Test func closingThePipelineDropsDeviceAndGeneration() {
        var lifecycle = RemoteDeviceLifecycle()
        lifecycle.openPipeline()
        guard case let .present(gen) = lifecycle.matched(openSucceeded: true) else {
            Issue.record("adopt should yield a generation")
            return
        }
        lifecycle.closePipeline()
        #expect(!lifecycle.pipelineReady)
        #expect(!lifecycle.devicePresent)
        #expect(!lifecycle.accepts(generation: gen))
    }
}

@Suite("Standalone reader health")
struct StandaloneReaderHealthTests {
    @Test func openWatcherWithNoDeviceIsObservingAndHealthy() {
        var health = StandaloneReaderHealth()
        #expect(!health.isHealthy)
        health.opened()
        #expect(health.isObserving)
        #expect(health.isHealthy)
        #expect(!health.devicePresent)
        #expect(health.activeGeneration == nil)
    }

    @Test func matchFailureStaysObservingButUnhealthy() {
        var health = StandaloneReaderHealth()
        health.opened()
        #expect(health.matched(openSucceeded: false) == .unreadable)
        // Observing stays true so the coordinator's `!isObserving` start guard does
        // not restart it in a loop; healthy is false so readerReady fails closed.
        #expect(health.isObserving)
        #expect(!health.isHealthy)
        #expect(!health.devicePresent)
        #expect(!RemoteSourceReaderPolicy.readerReady(
            target: .standalone, hidMonitorReading: false, standaloneHealthy: health.isHealthy))
    }

    @Test func removingTheUnreadableDeviceRecoversHealth() {
        var health = StandaloneReaderHealth()
        health.opened()
        _ = health.matched(openSucceeded: false)
        #expect(!health.isHealthy)
        health.clearUnreadable()          // that exact device removed
        #expect(health.isHealthy)
        #expect(health.isObserving)
        #expect(!health.devicePresent)
    }

    @Test func readableMatchSupersedesTheUnreadableBlock() {
        var health = StandaloneReaderHealth()
        health.opened()
        _ = health.matched(openSucceeded: false)
        guard case let .present(gen) = health.matched(openSucceeded: true) else {
            Issue.record("a readable match should supersede the unreadable block")
            return
        }
        #expect(health.isHealthy)
        #expect(health.devicePresent)
        #expect(health.accepts(generation: gen))
    }

    @Test func revokeFailsClosedAndRecoveryRequiresReopen() {
        var health = StandaloneReaderHealth()
        health.opened()
        health.revokePermission()
        #expect(!health.isHealthy)        // fail closed on runtime revoke
        #expect(health.isObserving)       // still observing (manager kept open)

        // A reopen whose open fails (permission flapped) stays unhealthy.
        var failedReopen = health
        failedReopen.closed()
        #expect(!failedReopen.isHealthy)
        #expect(!failedReopen.isObserving)

        // Only a successful reopen returns to healthy — there is no bare
        // permission flip that skips reopening/verifying the manager.
        var okReopen = health
        okReopen.closed()
        okReopen.opened()
        #expect(okReopen.isHealthy)
        #expect(okReopen.isObserving)
    }

    @Test func reportGateRejectsRevokedAndStaleReports() {
        var health = StandaloneReaderHealth()
        health.opened()
        guard case let .present(gen) = health.matched(openSucceeded: true) else {
            Issue.record("match should yield a generation")
            return
        }
        #expect(health.isHealthy && health.accepts(generation: gen))

        // Permission revoked between report snapshot and execution: device still
        // present, but a permission-failed report must never emit a .down.
        var revoked = health
        revoked.revokePermission()
        #expect(revoked.devicePresent)
        #expect(!(revoked.isHealthy && revoked.accepts(generation: gen)))

        // Device removed: the snapshotted generation is no longer accepted.
        var removed = health
        _ = removed.removed()
        #expect(!(removed.isHealthy && removed.accepts(generation: gen)))
    }

    @Test func removalInvalidatesGenerationThenReconnectMintsANewOne() {
        var health = StandaloneReaderHealth()
        health.opened()
        guard case let .present(gen1) = health.matched(openSucceeded: true) else {
            Issue.record("first match should yield a generation")
            return
        }
        #expect(health.removed() == gen1)
        #expect(!health.accepts(generation: gen1))
        guard case let .present(gen2) = health.matched(openSucceeded: true) else {
            Issue.record("reconnect should yield a fresh generation")
            return
        }
        #expect(gen2 != gen1)
        #expect(health.accepts(generation: gen2))
        #expect(!health.accepts(generation: gen1))
    }

    @Test func revokeBalancesTheHeldKeyAndDropsThePostRevokeReport() {
        var health = StandaloneReaderHealth()
        health.opened()
        guard case let .present(gen) = health.matched(openSucceeded: true) else {
            Issue.record("match should yield a generation")
            return
        }
        var tracker = RemoteVoiceKeyTracker()
        let usages = Set([RemoteVoiceFunctionMappingPolicy.remoteVoiceKeyUsage])
        let down = (health.isHealthy && health.accepts(generation: gen))
            ? tracker.update(usages: usages) : nil
        health.revokePermission()
        let balancedUp = tracker.release()
        let postRevoke = (health.isHealthy && health.accepts(generation: gen))
            ? tracker.update(usages: usages) : nil
        #expect(down == .down)
        #expect(balancedUp == .up)
        #expect(postRevoke == nil)
        #expect(!health.isHealthy)
    }
}

@Suite("RC003 source-reader policy")
struct RemoteSourceReaderPolicyTests {
    @Test func selectsNoReaderWhileFeatureOff() {
        #expect(RemoteSourceReaderPolicy.targetReader(
            localFnMicEnabled: false, hidMonitorReading: false) == RemoteSourceReader.none)
        #expect(RemoteSourceReaderPolicy.targetReader(
            localFnMicEnabled: false, hidMonitorReading: true) == RemoteSourceReader.none)
    }

    @Test func usesOnlyTheHidMonitorWhenItIsActuallyReading() {
        #expect(RemoteSourceReaderPolicy.targetReader(
            localFnMicEnabled: true, hidMonitorReading: true) == .hidMonitor)
        #expect(RemoteSourceReaderPolicy.readerReady(
            target: .hidMonitor, hidMonitorReading: true, standaloneHealthy: false))
    }

    @Test func fallsBackToStandaloneWhenTheHidMonitorIsNotReading() {
        // First install without Accessibility, runtime revocation, or an HID open
        // failure: the mapping checkbox is on but the monitor is not reading.
        #expect(RemoteSourceReaderPolicy.targetReader(
            localFnMicEnabled: true, hidMonitorReading: false) == .standalone)
        #expect(RemoteSourceReaderPolicy.readerReady(
            target: .standalone, hidMonitorReading: false, standaloneHealthy: true))
    }

    @Test func failsClosedWhenNoReaderIsHealthy() {
        // A standalone target that is observing but unhealthy (match failure or
        // runtime revoke) is not ready — readerReady is real health, not "open".
        #expect(!RemoteSourceReaderPolicy.readerReady(
            target: .standalone, hidMonitorReading: false, standaloneHealthy: false))
        #expect(!RemoteSourceReaderPolicy.readerReady(
            target: RemoteSourceReader.none, hidMonitorReading: false, standaloneHealthy: false))
    }

    @Test func selectsAtMostOneReaderAcrossTheMatrix() {
        let matrix: [RemoteSourceReader] = [
            RemoteSourceReaderPolicy.targetReader(localFnMicEnabled: false, hidMonitorReading: false),
            RemoteSourceReaderPolicy.targetReader(localFnMicEnabled: false, hidMonitorReading: true),
            RemoteSourceReaderPolicy.targetReader(localFnMicEnabled: true, hidMonitorReading: false),
            RemoteSourceReaderPolicy.targetReader(localFnMicEnabled: true, hidMonitorReading: true),
        ]
        #expect(matrix == [RemoteSourceReader.none, RemoteSourceReader.none, .standalone, .hidMonitor])
    }
}

@Suite("Function key flag tracker")
struct FunctionKeyFlagTrackerTests {
    @Test func debouncesDuplicateSamples() {
        var tracker = FunctionKeyFlagTracker()
        #expect(tracker.update(functionFlagActive: true) == .press)
        #expect(tracker.update(functionFlagActive: true) == nil)
        #expect(tracker.update(functionFlagActive: false) == .release)
        #expect(tracker.update(functionFlagActive: false) == nil)
        #expect(!tracker.isDown)
    }

    @Test func resetClearsHeldState() {
        var tracker = FunctionKeyFlagTracker()
        #expect(tracker.update(functionFlagActive: true) == .press)
        tracker.reset()
        #expect(!tracker.isDown)
        #expect(tracker.update(functionFlagActive: true) == .press)
    }
}

@Suite("RC003 voice-key double-click bridge toggle")
struct RemoteBridgeToggleGestureDetectorTests {
    private func expectEdge(
        _ detector: inout RemoteBridgeToggleGestureDetector,
        _ edge: RemoteEventEdge,
        at nowMs: UInt64,
        toggles: Bool
    ) {
        let result = detector.handle(edge, nowMs: nowMs)
        #expect(result == toggles)
    }

    @Test func twoShortTapsInWindowToggleExactlyOnce() {
        var detector = RemoteBridgeToggleGestureDetector()
        expectEdge(&detector, .down, at: 0, toggles: false)
        expectEdge(&detector, .up, at: 100, toggles: false)
        expectEdge(&detector, .down, at: 200, toggles: false)
        expectEdge(&detector, .up, at: 300, toggles: true)
        // Idle again: a lone tap does not toggle.
        expectEdge(&detector, .down, at: 400, toggles: false)
        expectEdge(&detector, .up, at: 460, toggles: false)
    }

    @Test func longPressNeverTogglesAndDoesNotArmAPair() {
        var detector = RemoteBridgeToggleGestureDetector()
        expectEdge(&detector, .down, at: 0, toggles: false)
        expectEdge(&detector, .up, at: 400, toggles: false) // long press
        expectEdge(&detector, .down, at: 450, toggles: false)
        expectEdge(&detector, .up, at: 520, toggles: false)
    }

    @Test func longSecondPressDoesNotToggle() {
        var detector = RemoteBridgeToggleGestureDetector()
        _ = detector.handle(.down, nowMs: 0)
        _ = detector.handle(.up, nowMs: 100)
        _ = detector.handle(.down, nowMs: 200)
        expectEdge(&detector, .up, at: 700, toggles: false)
    }

    @Test func slowRepeatedAndMissingUpNeverToggle() {
        var slow = RemoteBridgeToggleGestureDetector()
        _ = slow.handle(.down, nowMs: 0)
        _ = slow.handle(.up, nowMs: 100)
        expectEdge(&slow, .down, at: 500, toggles: false) // past window
        expectEdge(&slow, .up, at: 560, toggles: false)

        var repeated = RemoteBridgeToggleGestureDetector()
        _ = repeated.handle(.down, nowMs: 0)
        expectEdge(&repeated, .down, at: 50, toggles: false) // repeated down
        expectEdge(&repeated, .up, at: 100, toggles: false)
    }

    @Test func resetDropsInflightGesture() {
        var detector = RemoteBridgeToggleGestureDetector()
        _ = detector.handle(.down, nowMs: 0)
        _ = detector.handle(.up, nowMs: 100)
        detector.reset()
        expectEdge(&detector, .down, at: 200, toggles: false)
        expectEdge(&detector, .up, at: 260, toggles: false)
    }

    @Test func sameGestureTogglesAgainToRestore() {
        var detector = RemoteBridgeToggleGestureDetector()
        _ = detector.handle(.down, nowMs: 0)
        _ = detector.handle(.up, nowMs: 80)
        _ = detector.handle(.down, nowMs: 150)
        expectEdge(&detector, .up, at: 220, toggles: true) // disable
        _ = detector.handle(.down, nowMs: 1000)
        _ = detector.handle(.up, nowMs: 1080)
        _ = detector.handle(.down, nowMs: 1150)
        expectEdge(&detector, .up, at: 1220, toggles: true) // restore
    }

    @Test func boundariesAreInclusiveAndOneMsPastFails() {
        var inclusive = RemoteBridgeToggleGestureDetector()
        _ = inclusive.handle(.down, nowMs: 0)
        _ = inclusive.handle(.up, nowMs: 250)   // tap == 250
        _ = inclusive.handle(.down, nowMs: 350) // window == 350
        expectEdge(&inclusive, .up, at: 600, toggles: true)

        var over = RemoteBridgeToggleGestureDetector()
        _ = over.handle(.down, nowMs: 0)
        _ = over.handle(.up, nowMs: 100)
        _ = over.handle(.down, nowMs: 351)      // 1ms past the window
        expectEdge(&over, .up, at: 400, toggles: false)
    }

    @Test func frozenConstantsMatchTheContract() {
        #expect(RemoteBridgeToggleGesture.doubleClickWindowMs == 350)
        #expect(RemoteBridgeToggleGesture.singleTapMaxMs == 250)
    }
}

@Suite("RC003 multi-source double-click coordinator")
struct RemoteBridgeToggleCoordinatorTests {
    private func expectEdge(
        _ coordinator: inout RemoteBridgeToggleCoordinator,
        _ edge: RemoteEventEdge,
        source: RemoteBridgeToggleSource,
        at nowMs: UInt64,
        toggles: Bool
    ) {
        let result = coordinator.handle(edge, source: source, nowMs: nowMs)
        #expect(result == toggles)
    }

    @Test func atvvCompletesGestureWhenHidDropsTheRapidReports() {
        var coordinator = RemoteBridgeToggleCoordinator()
        expectEdge(&coordinator, .down, source: .atvv, at: 0, toggles: false)
        expectEdge(&coordinator, .up, source: .atvv, at: 70, toggles: false)
        expectEdge(&coordinator, .down, source: .atvv, at: 150, toggles: false)
        expectEdge(&coordinator, .up, source: .atvv, at: 220, toggles: true)
    }

    @Test func mirroredHidAndAtvvGestureTogglesOnlyOnce() {
        var coordinator = RemoteBridgeToggleCoordinator()
        expectEdge(&coordinator, .down, source: .hid, at: 0, toggles: false)
        expectEdge(&coordinator, .down, source: .atvv, at: 8, toggles: false)
        expectEdge(&coordinator, .up, source: .hid, at: 70, toggles: false)
        expectEdge(&coordinator, .up, source: .atvv, at: 78, toggles: false)
        expectEdge(&coordinator, .down, source: .hid, at: 150, toggles: false)
        expectEdge(&coordinator, .down, source: .atvv, at: 158, toggles: false)
        expectEdge(&coordinator, .up, source: .hid, at: 220, toggles: true)
        // The HID completion reset both source detectors. The mirrored ATVV up
        // is therefore an orphan release and cannot undo the first toggle.
        expectEdge(&coordinator, .up, source: .atvv, at: 228, toggles: false)
    }

    @Test func lateMirroredSecondTapCannotArmTheNextGesture() {
        var coordinator = RemoteBridgeToggleCoordinator()
        // HID finishes before the mirrored ATVV second tap has even started.
        expectEdge(&coordinator, .down, source: .hid, at: 0, toggles: false)
        expectEdge(&coordinator, .up, source: .hid, at: 60, toggles: false)
        expectEdge(&coordinator, .down, source: .hid, at: 150, toggles: false)
        expectEdge(&coordinator, .up, source: .hid, at: 220, toggles: true)
        expectEdge(&coordinator, .down, source: .atvv, at: 230, toggles: false)
        expectEdge(&coordinator, .up, source: .atvv, at: 280, toggles: false)

        // One later ATVV tap is a fresh first tap, not the second half of the
        // delayed mirror above.
        expectEdge(&coordinator, .down, source: .atvv, at: 500, toggles: false)
        expectEdge(&coordinator, .up, source: .atvv, at: 560, toggles: false)
    }

    @Test func missingMirrorDoesNotDisableTheFallbackForever() {
        var coordinator = RemoteBridgeToggleCoordinator()
        expectEdge(&coordinator, .down, source: .hid, at: 0, toggles: false)
        expectEdge(&coordinator, .up, source: .hid, at: 60, toggles: false)
        expectEdge(&coordinator, .down, source: .hid, at: 150, toggles: false)
        expectEdge(&coordinator, .up, source: .hid, at: 220, toggles: true)

        // No mirrored ATVV edge arrives. After the bounded isolation expires,
        // ATVV can independently recognise a restore gesture.
        expectEdge(&coordinator, .down, source: .atvv, at: 600, toggles: false)
        expectEdge(&coordinator, .up, source: .atvv, at: 660, toggles: false)
        expectEdge(&coordinator, .down, source: .atvv, at: 740, toggles: false)
        expectEdge(&coordinator, .up, source: .atvv, at: 800, toggles: true)
    }

    @Test func longPressFromEitherSourceNeverToggles() {
        for source in [RemoteBridgeToggleSource.hid, .atvv] {
            var coordinator = RemoteBridgeToggleCoordinator()
            expectEdge(&coordinator, .down, source: source, at: 0, toggles: false)
            expectEdge(&coordinator, .up, source: source, at: 400, toggles: false)
        }
    }
}

@Suite("ATVV voice-control edge tracker")
struct RemoteVoiceControlEdgeTrackerTests {
    @Test func micOpenAndStreamStartBecomeOneDown() {
        var tracker = RemoteVoiceControlEdgeTracker()
        let down = tracker.update(active: true)
        let duplicateDown = tracker.update(active: true)
        let up = tracker.update(active: false)
        let duplicateUp = tracker.update(active: false)
        #expect(down == .down)
        #expect(duplicateDown == nil)
        #expect(up == .up)
        #expect(duplicateUp == nil)
    }

    @Test func resetDropsAStaleHeldSessionWithoutInventingAnUp() {
        var tracker = RemoteVoiceControlEdgeTracker()
        _ = tracker.update(active: true)
        tracker.reset()
        #expect(!tracker.isDown)
        let orphanUp = tracker.update(active: false)
        let nextDown = tracker.update(active: true)
        #expect(orphanUp == nil)
        #expect(nextDown == .down)
    }

    @Test func pauseDrainsDuplicateStartAndStopBeforeAcceptingANewPress() {
        var tracker = RemoteVoiceControlEdgeTracker()
        #expect(tracker.update(active: true) == .down) // MIC_OPEN
        tracker.cancelCurrentPress()
        #expect(!tracker.isDown)
        #expect(tracker.update(active: true) == nil)   // same press: STREAM_START
        #expect(tracker.update(active: false) == nil)  // same press: STOP
        #expect(tracker.update(active: true) == .down) // next physical press
    }

    @Test func pauseBetweenMicOpenAndStreamStartCannotArmAnAccidentalRestore() {
        var tracker = RemoteVoiceControlEdgeTracker()
        var coordinator = RemoteBridgeToggleCoordinator()

        let micOpen = tracker.update(active: true)
        #expect(micOpen == .down)
        if let micOpen {
            let toggled = coordinator.handle(micOpen, source: .atvv, nowMs: 0)
            #expect(!toggled)
        }

        // Settings/menu pause invalidates the partial gesture, then drains the
        // remaining controls from the same physical press.
        coordinator.reset()
        tracker.cancelCurrentPress()
        #expect(tracker.update(active: true) == nil)  // delayed STREAM_START
        #expect(tracker.update(active: false) == nil) // STOP

        // A single tap after the drain is only a first tap and cannot restore.
        let singleDown = tracker.update(active: true)
        #expect(singleDown == .down)
        if let singleDown {
            let toggled = coordinator.handle(singleDown, source: .atvv, nowMs: 100)
            #expect(!toggled)
        }
        let singleUp = tracker.update(active: false)
        #expect(singleUp == .up)
        if let singleUp {
            let toggled = coordinator.handle(singleUp, source: .atvv, nowMs: 160)
            #expect(!toggled)
        }

        // After that tap has expired, one complete fresh double-click restores.
        let firstDown = tracker.update(active: true)
        let firstDownResult = firstDown.map {
            coordinator.handle($0, source: .atvv, nowMs: 500)
        }
        #expect(firstDownResult == false)
        let firstUp = tracker.update(active: false)
        let firstUpResult = firstUp.map {
            coordinator.handle($0, source: .atvv, nowMs: 560)
        }
        #expect(firstUpResult == false)
        let secondDown = tracker.update(active: true)
        let secondDownResult = secondDown.map {
            coordinator.handle($0, source: .atvv, nowMs: 650)
        }
        #expect(secondDownResult == false)
        let secondUp = tracker.update(active: false)
        let secondUpResult = secondUp.map {
            coordinator.handle($0, source: .atvv, nowMs: 710)
        }
        #expect(secondUpResult == true)
    }
}

@Suite("Bridge runtime gates")
struct BridgeRuntimeGateTests {
    @Test func readerIsNeededByEitherConsumer() {
        #expect(RemoteSourceReaderPolicy.targetReader(
            localFnMicEnabled: false, doubleClickEnabled: true, hidMonitorReading: false
        ) == .standalone)
        #expect(RemoteSourceReaderPolicy.targetReader(
            localFnMicEnabled: false, doubleClickEnabled: true, hidMonitorReading: true
        ) == .hidMonitor)
        #expect(RemoteSourceReaderPolicy.targetReader(
            localFnMicEnabled: true, doubleClickEnabled: false, hidMonitorReading: false
        ) == .standalone)
        #expect(RemoteSourceReaderPolicy.targetReader(
            localFnMicEnabled: false, doubleClickEnabled: false, hidMonitorReading: true
        ) == RemoteSourceReader.none)
    }

    @Test func fullSuppressionOnlyWithSeizedCustomMapping() {
        #expect(BridgeSuppressionScope.isFullSuppression(customMappingEnabled: true, exclusivelyReading: true))
        #expect(!BridgeSuppressionScope.isFullSuppression(customMappingEnabled: true, exclusivelyReading: false))
        #expect(!BridgeSuppressionScope.isFullSuppression(customMappingEnabled: false, exclusivelyReading: true))
        #expect(!BridgeSuppressionScope.isFullSuppression(customMappingEnabled: false, exclusivelyReading: false))
    }

    @Test func voiceGateFollowsBridgingState() {
        #expect(ATVVVoiceBridgeGate.allowsVoice(bridgingEnabled: true))
        #expect(!ATVVVoiceBridgeGate.allowsVoice(bridgingEnabled: false))
    }

    @Test func statusTextTracksSeizeMode() {
        #expect(BridgeRuntimeStatusText.text(
            enabled: true, mappingRestoreFailed: false, customMappingEnabled: false, exclusivelyReading: false
        ) == BridgeRuntimeStatusText.enabled)
        #expect(BridgeRuntimeStatusText.text(
            enabled: false, mappingRestoreFailed: true, customMappingEnabled: true, exclusivelyReading: true
        ) == BridgeRuntimeStatusText.mappingRestoreFailed)
        #expect(BridgeRuntimeStatusText.text(
            enabled: false, mappingRestoreFailed: false, customMappingEnabled: true, exclusivelyReading: true
        ) == BridgeRuntimeStatusText.disabled)
        #expect(BridgeRuntimeStatusText.text(
            enabled: false, mappingRestoreFailed: false, customMappingEnabled: true, exclusivelyReading: false
        ) == BridgeRuntimeStatusText.nativeKeysMayRemain)
        #expect(BridgeRuntimeStatusText.text(
            enabled: false, mappingRestoreFailed: false, customMappingEnabled: false, exclusivelyReading: true
        ) == BridgeRuntimeStatusText.nativeKeysMayRemain)
    }

    @Test func seizeModeChangeAloneChangesDisabledStatus() {
        // A seize-mode flip does NOT flip reader health, so match/removal must
        // refresh the status; this proves the status genuinely differs.
        let seized = BridgeRuntimeStatusText.text(
            enabled: false, mappingRestoreFailed: false, customMappingEnabled: true, exclusivelyReading: true
        )
        let monitored = BridgeRuntimeStatusText.text(
            enabled: false, mappingRestoreFailed: false, customMappingEnabled: true, exclusivelyReading: false
        )
        #expect(seized != monitored)
    }
}

@Suite("Forced voice-key release ordering")
struct RemoteVoiceKeyForcedReleaseTests {
    /// Mirrors BridgeAppModel: onGestureInvalidate resets ONLY the detector, then
    /// the balancing `.up` reaches both the (now idle) detector and the arbiter.
    private func applyForcedRelease(
        keyHeld: Bool,
        detector: inout RemoteBridgeToggleGestureDetector,
        arbiter: inout LocalMicArbiter,
        nowMs: UInt64
    ) -> Bool {
        var toggled = false
        for effect in RemoteVoiceKeyForcedRelease.effects(keyHeld: keyHeld) {
            switch effect {
            case .invalidateGesture:
                detector.reset()
            case .balancingUp:
                if detector.handle(.up, nowMs: nowMs) { toggled = true }
                _ = arbiter.handle(.remoteSourceUp)
            }
        }
        return toggled
    }

    private func detectorInSecondDown() -> RemoteBridgeToggleGestureDetector {
        var detector = RemoteBridgeToggleGestureDetector()
        _ = detector.handle(.down, nowMs: 0)
        _ = detector.handle(.up, nowMs: 80)
        _ = detector.handle(.down, nowMs: 150)
        return detector
    }

    @Test func invalidationIsAlwaysOrderedBeforeAnyBalancingUp() {
        #expect(RemoteVoiceKeyForcedRelease.effects(keyHeld: true) == [.invalidateGesture, .balancingUp])
        #expect(RemoteVoiceKeyForcedRelease.effects(keyHeld: false) == [.invalidateGesture])
    }

    @Test func genuineUpInSecondDownStillToggles() {
        var detector = RemoteBridgeToggleGestureDetector()
        _ = detector.handle(.down, nowMs: 0)
        _ = detector.handle(.up, nowMs: 80)
        _ = detector.handle(.down, nowMs: 150)
        let toggled = detector.handle(.up, nowMs: 210)
        #expect(toggled) // genuine report .up is not suppressed
    }

    @Test func removalRevokeStopDuringSecondDownDoNotToggleButStillRelease() {
        for scenario in ["removal", "revoke", "stop/fail-close", "generation-change"] {
            var detector = detectorInSecondDown()
            var arbiter = LocalMicArbiter()
            _ = arbiter.handle(.remoteSourceDown)
            let toggled = applyForcedRelease(
                keyHeld: true, detector: &detector, arbiter: &arbiter, nowMs: 210
            )
            #expect(!toggled, "\(scenario) during secondDown must not toggle")
            #expect(!arbiter.remoteSourceActive, "\(scenario) must still release the remote-source marker")
        }
    }

    @Test func generationChangeWhileKeyNotHeldDropsPendingFirstTap() {
        var detector = RemoteBridgeToggleGestureDetector()
        _ = detector.handle(.down, nowMs: 0)
        _ = detector.handle(.up, nowMs: 80) // firstReleased, key not held
        var arbiter = LocalMicArbiter()
        let toggled = applyForcedRelease(
            keyHeld: false, detector: &detector, arbiter: &arbiter, nowMs: 150
        )
        #expect(!toggled)
        // A later in-window tap must be a fresh first tap, not the second of an old pair.
        let laterDown = detector.handle(.down, nowMs: 200)
        let laterUp = detector.handle(.up, nowMs: 260)
        #expect(!laterDown)
        #expect(!laterUp)
    }
}

@Suite("Audio loop guard and gain")
struct AudioLoopGuardTests {
    @Test func rejectsFeedbackAndMissingEndpoints() {
        #expect(AudioLoopGuard.rejection(resolvedInputUID: "BuiltInMic", outputUID: "BlackHole2ch") == nil)
        #expect(AudioLoopGuard.rejection(resolvedInputUID: "BlackHole2ch", outputUID: "BlackHole2ch") == .sameDevice)
        #expect(AudioLoopGuard.rejection(resolvedInputUID: nil, outputUID: "BlackHole2ch") == .noInput)
        #expect(AudioLoopGuard.rejection(resolvedInputUID: "", outputUID: "BlackHole2ch") == .noInput)
        #expect(AudioLoopGuard.rejection(resolvedInputUID: "BuiltInMic", outputUID: "") == .noOutput)
    }

    @Test func gainScalesClampsAndHandlesNonFinite() {
        #expect(LocalMicGain.apply([], gainDB: 6) == [])
        #expect(LocalMicGain.apply([100, -100], gainDB: 0) == [100, -100])
        #expect(LocalMicGain.apply([20_000], gainDB: 24) == [Int16.max])
        #expect(LocalMicGain.apply([-20_000], gainDB: 24) == [Int16.min])
        #expect(LocalMicGain.apply([100], gainDB: .infinity) == [100])
    }
}
