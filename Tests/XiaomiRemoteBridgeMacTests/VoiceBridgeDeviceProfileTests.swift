import Testing
@testable import XiaomiRemoteBridgeMac

@Suite("Voice bridge device profiles")
struct VoiceBridgeDeviceProfileTests {
    @Test func rc003ProfileOwnsAllRuntimeIdentity() {
        let profile = VoiceBridgeDeviceProfiles.xiaomiRC003

        #expect(profile.id == "xiaomi-rc003")
        #expect(profile.matchesBluetoothName("MI RC"))
        #expect(profile.matchesBluetoothName(" xiaomi bluetooth remote 2 pro "))
        #expect(profile.matchesBluetoothName("小米蓝牙语音遥控器"))
        #expect(!profile.matchesBluetoothName("Mi Mouse"))
        #expect(profile.hidIdentity == VoiceBridgeHIDIdentity(
            vendorID: 0x2717,
            productID: 0x32B8
        ))
    }

    @Test func rc003CapabilitiesAndTransportsAreExplicit() {
        let profile = VoiceBridgeDeviceProfiles.xiaomiRC003

        #expect(profile.transports == [.bluetoothLowEnergyGATT, .bluetoothHID])
        #expect(profile.capabilities == [
            .voiceCapture,
            .pressToTalk,
            .buttonInput,
            .hostKeyMapping,
        ])
        #expect(!profile.transports.contains(.usbDigitalAudio))
    }
}
