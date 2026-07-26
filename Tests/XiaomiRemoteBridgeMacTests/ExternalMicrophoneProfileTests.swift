import XCTest
@testable import XiaomiRemoteBridgeMac

final class ExternalMicrophoneProfileTests: XCTestCase {
    func testMatchesKnownDJIMic2AudioNamesWithoutDependingOnSuffix() {
        XCTAssertTrue(ExternalMicrophoneProfile.isDJIMic2(displayName: "DJI-MIC2-ABCDEF Hands-Free"))
        XCTAssertTrue(ExternalMicrophoneProfile.isDJIMic2(displayName: "DJI Mic 2"))
        XCTAssertTrue(ExternalMicrophoneProfile.isDJIMic2(displayName: "DJI Mic2 (Bluetooth)"))
    }

    func testRejectsLookalikesAndOtherDJIProducts() {
        XCTAssertFalse(ExternalMicrophoneProfile.isDJIMic2(displayName: "DJI-MIC20"))
        XCTAssertFalse(ExternalMicrophoneProfile.isDJIMic2(displayName: "DJI Mic Mini"))
        XCTAssertFalse(ExternalMicrophoneProfile.isDJIMic2(displayName: "Built-in Microphone"))
    }
}
