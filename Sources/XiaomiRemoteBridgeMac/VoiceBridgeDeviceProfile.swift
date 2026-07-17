import Foundation

enum VoiceBridgeTransport: String, CaseIterable, Hashable {
    case bluetoothLowEnergyGATT = "ble-gatt"
    case bluetoothHID = "bluetooth-hid"
    case usbDigitalAudio = "usb-digital-audio"
    case systemAudioInput = "system-audio-input"
}

enum VoiceBridgeCapability: String, CaseIterable, Hashable {
    case voiceCapture = "voice-capture"
    case pressToTalk = "press-to-talk"
    case buttonInput = "button-input"
    case hostKeyMapping = "host-key-mapping"
}

struct VoiceBridgeHIDIdentity: Equatable {
    let vendorID: Int
    let productID: Int
}

struct VoiceBridgeDeviceProfile: Equatable {
    let id: String
    let displayName: String
    let manufacturer: String
    let model: String
    let bluetoothNames: Set<String>
    let transports: Set<VoiceBridgeTransport>
    let capabilities: Set<VoiceBridgeCapability>
    let hidIdentity: VoiceBridgeHIDIdentity?

    init(
        id: String,
        displayName: String,
        manufacturer: String,
        model: String,
        bluetoothNames: Set<String> = [],
        transports: Set<VoiceBridgeTransport>,
        capabilities: Set<VoiceBridgeCapability>,
        hidIdentity: VoiceBridgeHIDIdentity? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.manufacturer = manufacturer
        self.model = model
        self.bluetoothNames = Set(bluetoothNames.compactMap(Self.normalizeName))
        self.transports = transports
        self.capabilities = capabilities
        self.hidIdentity = hidIdentity
    }

    func matchesBluetoothName(_ rawName: String?) -> Bool {
        guard let normalized = Self.normalizeName(rawName) else { return false }
        return bluetoothNames.contains(normalized)
    }

    private static func normalizeName(_ rawName: String?) -> String? {
        guard let rawName else { return nil }
        let normalized = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

enum VoiceBridgeDeviceProfiles {
    static let xiaomiRC003 = VoiceBridgeDeviceProfile(
        id: "xiaomi-rc003",
        displayName: "Xiaomi Bluetooth Remote 2 Pro / RC003",
        manufacturer: "Xiaomi",
        model: "RC003",
        bluetoothNames: [
            "MI RC",
            "Xiaomi Bluetooth Remote 2 Pro",
            "小米蓝牙语音遥控器",
        ],
        transports: [.bluetoothLowEnergyGATT, .bluetoothHID],
        capabilities: [.voiceCapture, .pressToTalk, .buttonInput, .hostKeyMapping],
        hidIdentity: VoiceBridgeHIDIdentity(vendorID: 0x2717, productID: 0x32B8)
    )
}
