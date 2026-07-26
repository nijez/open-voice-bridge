import Foundation
import Testing
@testable import XiaomiRemoteBridgeMac

@Suite("Launch at login")
struct LaunchAtLoginManagerTests {
    @Test func onlyInstalledApplicationLocationsCanRegister() {
        let home = URL(fileURLWithPath: "/private/tmp/ovb-test-home")
        #expect(LaunchAtLoginManager.isInstalledApplicationBundle(
            URL(fileURLWithPath: "/Applications/Open Voice Bridge.app"),
            homeDirectory: home
        ))
        #expect(!LaunchAtLoginManager.isInstalledApplicationBundle(
            URL(fileURLWithPath: "/tmp/dist/Open Voice Bridge.app"),
            homeDirectory: home
        ))
    }

    @Test func applicationsSymlinkCannotTrustAnExternalDistBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OVBLoginTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let dist = root.appendingPathComponent("dist", isDirectory: true)
        let app = dist.appendingPathComponent("Open Voice Bridge.app", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("Applications", isDirectory: true),
            withDestinationURL: dist
        )

        #expect(!LaunchAtLoginManager.isInstalledApplicationBundle(
            home
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent("Open Voice Bridge.app", isDirectory: true),
            homeDirectory: home
        ))
    }

    @Test func legacyAgentUsesBundleIdentityAndAquaSession() throws {
        let bundleIdentifier = "com.example.OpenVoiceBridge"
        let propertyList = LaunchAtLoginManager.legacyLaunchAgentPropertyList(
            bundleIdentifier: bundleIdentifier
        )

        #expect(propertyList["Label"] as? String == "com.example.OpenVoiceBridge.LaunchAtLogin")
        #expect(propertyList["LimitLoadToSessionType"] as? String == "Aqua")
        #expect(propertyList["RunAtLoad"] as? Bool == true)
        #expect(propertyList["ProgramArguments"] as? [String] == [
            "/usr/bin/open",
            "-b",
            bundleIdentifier,
        ])

        _ = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
    }
}
