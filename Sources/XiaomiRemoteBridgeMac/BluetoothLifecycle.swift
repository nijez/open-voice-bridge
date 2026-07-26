import Foundation

enum RC003NameMatcher {
    static func matches(_ rawName: String?) -> Bool {
        VoiceBridgeDeviceProfiles.xiaomiRC003.matchesBluetoothName(rawName)
    }
}

enum BluetoothLifecyclePhase: Equatable {
    case stopped
    case scanning(UInt64)
    case connecting(UInt64)
    case discovering(UInt64)
    case awaitingCapabilities(UInt64)
    case ready(UInt64)
    case disconnecting(UInt64)
    case waitingReconnect(UInt64)

    var generation: UInt64? {
        switch self {
        case .connecting(let value),
             .scanning(let value),
             .discovering(let value),
             .awaitingCapabilities(let value),
             .ready(let value),
             .disconnecting(let value),
             .waitingReconnect(let value):
            return value
        case .stopped:
            return nil
        }
    }

    func acceptsDidConnect(generation: UInt64) -> Bool {
        self == .connecting(generation)
    }

    func acceptsDidFailToConnect(generation: UInt64) -> Bool {
        self == .connecting(generation) || self == .disconnecting(generation)
    }

    func acceptsInitializationCallback(generation: UInt64) -> Bool {
        self == .discovering(generation)
    }

    /// Device Information and ATVV are discovered in parallel. ATVV may advance
    /// first, so model callbacks remain valid while capabilities are pending, but
    /// never after ready or teardown.
    func acceptsModelDiscovery(generation: UInt64) -> Bool {
        self == .discovering(generation) || self == .awaitingCapabilities(generation)
    }

    func acceptsModelValue(generation: UInt64) -> Bool {
        acceptsModelDiscovery(generation: generation)
    }

    func acceptsNotificationUpdate(generation: UInt64) -> Bool {
        switch self {
        case .discovering(generation),
             .awaitingCapabilities(generation),
             .ready(generation):
            return true
        default:
            return false
        }
    }

    func acceptsCapabilities(generation: UInt64) -> Bool {
        self == .awaitingCapabilities(generation)
    }

    func acceptsProtocolData(generation: UInt64) -> Bool {
        self == .ready(generation)
    }

    func acceptsDisconnect(generation: UInt64) -> Bool {
        switch self {
        case .discovering(generation),
             .awaitingCapabilities(generation),
             .ready(generation),
             .disconnecting(generation):
            return true
        default:
            return false
        }
    }
}

struct XiaomiModelConfirmationGate: Equatable {
    private(set) var modelNumber: String?
    private(set) var variant: XiaomiRemoteVariant?

    var isConfirmed: Bool { modelNumber != nil && variant != nil }

    mutating func accept(_ rawModelNumber: String) -> XiaomiRemoteVariant? {
        guard !isConfirmed,
              let detected = XiaomiRemoteVariant.detected(fromModelNumber: rawModelNumber)
        else { return nil }
        modelNumber = rawModelNumber
            .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
            .uppercased()
        variant = detected
        return detected
    }

    mutating func reset() {
        modelNumber = nil
        variant = nil
    }
}

enum ATVVSessionGate {
    static func canOpenMicrophone(
        phase: BluetoothLifecyclePhase,
        generation: UInt64,
        capabilitiesConfirmed: Bool,
        sampleRate: Double
    ) -> Bool {
        phase.acceptsProtocolData(generation: generation) &&
            capabilitiesConfirmed &&
            ATVVProtocol.supportsAudio(sampleRate: sampleRate)
    }
}
