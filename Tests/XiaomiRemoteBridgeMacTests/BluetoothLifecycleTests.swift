import Testing
@testable import XiaomiRemoteBridgeMac

@Suite("Bluetooth lifecycle")
struct BluetoothLifecycleTests {
    @Test func generationAndPhaseRejectStaleCallbacks() {
        let phase = BluetoothLifecyclePhase.connecting(1)
        #expect(phase.acceptsDidConnect(generation: 1))
        #expect(phase.acceptsDidFailToConnect(generation: 1))
        #expect(!phase.acceptsDisconnect(generation: 1))
        #expect(!phase.acceptsDidConnect(generation: 2))
        #expect(BluetoothLifecyclePhase.disconnecting(1)
            .acceptsDidFailToConnect(generation: 1))
    }

    @Test func initializationCapabilitiesAndReadyAreDistinct() {
        #expect(BluetoothLifecyclePhase.discovering(1)
            .acceptsInitializationCallback(generation: 1))
        #expect(!BluetoothLifecyclePhase.discovering(1)
            .acceptsCapabilities(generation: 1))
        #expect(BluetoothLifecyclePhase.awaitingCapabilities(1)
            .acceptsCapabilities(generation: 1))
        #expect(!BluetoothLifecyclePhase.awaitingCapabilities(1)
            .acceptsProtocolData(generation: 1))
        #expect(BluetoothLifecyclePhase.ready(1)
            .acceptsProtocolData(generation: 1))
    }

    @Test func modelCallbacksAllowEitherParallelInitializationOrder() {
        #expect(BluetoothLifecyclePhase.discovering(7)
            .acceptsModelDiscovery(generation: 7))
        #expect(BluetoothLifecyclePhase.awaitingCapabilities(7)
            .acceptsModelDiscovery(generation: 7))
        #expect(BluetoothLifecyclePhase.discovering(7)
            .acceptsModelValue(generation: 7))
        #expect(BluetoothLifecyclePhase.awaitingCapabilities(7)
            .acceptsModelValue(generation: 7))
    }

    @Test func modelCallbacksRejectLateTeardownAndStaleGeneration() {
        let rejected: [BluetoothLifecyclePhase] = [
            .ready(7), .disconnecting(7), .waitingReconnect(7), .stopped,
        ]
        for phase in rejected {
            #expect(!phase.acceptsModelDiscovery(generation: 7))
            #expect(!phase.acceptsModelValue(generation: 7))
        }
        #expect(!BluetoothLifecyclePhase.discovering(7)
            .acceptsModelValue(generation: 8))
        #expect(!BluetoothLifecyclePhase.awaitingCapabilities(7)
            .acceptsModelDiscovery(generation: 8))
    }

    @Test func modelConfirmationIsFirstValidValueWins() {
        var gate = XiaomiModelConfirmationGate()
        #expect(gate.accept(" arn9\n") == .arn9)
        #expect(gate.modelNumber == "ARN9")
        #expect(gate.isConfirmed)
        #expect(gate.accept("ARN9") == nil)
        #expect(gate.accept("RC003") == nil)
        #expect(gate.modelNumber == "ARN9")
        #expect(gate.variant == .arn9)
        gate.reset()
        #expect(!gate.isConfirmed)
        #expect(gate.accept("RC003") == .rc003Pro)
    }

    @Test func microphoneRequiresConfirmed16kReadySession() {
        #expect(!ATVVSessionGate.canOpenMicrophone(
            phase: .awaitingCapabilities(1),
            generation: 1,
            capabilitiesConfirmed: true,
            sampleRate: 16_000
        ))
        #expect(!ATVVSessionGate.canOpenMicrophone(
            phase: .ready(1),
            generation: 1,
            capabilitiesConfirmed: false,
            sampleRate: 16_000
        ))
        #expect(!ATVVSessionGate.canOpenMicrophone(
            phase: .ready(1),
            generation: 1,
            capabilitiesConfirmed: true,
            sampleRate: 8_000
        ))
        #expect(ATVVSessionGate.canOpenMicrophone(
            phase: .ready(1),
            generation: 1,
            capabilitiesConfirmed: true,
            sampleRate: 16_000
        ))
    }

    @Test func nameMatcherAcceptsApprovedCandidateNames() {
        #expect(RC003NameMatcher.matches("MI RC"))
        #expect(RC003NameMatcher.matches("mi rc"))
        #expect(RC003NameMatcher.matches("  MI RC  "))
        #expect(RC003NameMatcher.matches("Xiaomi Bluetooth Remote 2 Pro"))
        #expect(RC003NameMatcher.matches("xiaomi bluetooth remote 2 pro"))
        #expect(RC003NameMatcher.matches("小米蓝牙语音遥控器"))
        #expect(RC003NameMatcher.matches(" 小米蓝牙语音遥控器 "))
    }

    @Test func nameMatcherRejectsBlankNilAndSimilarNonTargetNames() {
        #expect(!RC003NameMatcher.matches(nil))
        #expect(!RC003NameMatcher.matches(""))
        #expect(!RC003NameMatcher.matches("   "))
        #expect(!RC003NameMatcher.matches("Mi Mouse"))
        #expect(!RC003NameMatcher.matches("小米蓝牙遥控器"))
        #expect(!RC003NameMatcher.matches("Xiaomi Bluetooth Remote 2"))
        #expect(!RC003NameMatcher.matches("MI RC2"))
        #expect(!RC003NameMatcher.matches("小米"))
    }
}
