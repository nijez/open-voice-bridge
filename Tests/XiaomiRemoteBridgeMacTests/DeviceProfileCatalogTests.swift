import Foundation
import XCTest
@testable import XiaomiRemoteBridgeMac

final class DeviceProfileCatalogTests: XCTestCase {
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func profileJSON(
        id: String,
        status: String = "implemented",
        displayName: String = "Test Device"
    ) -> String {
        """
        {
          "schemaVersion": 1,
          "id": "\(id)",
          "displayName": "\(displayName)",
          "vendor": "Test Vendor",
          "model": "Test Model",
          "support": { "status": "\(status)", "notes": "Verified test fixture." },
          "identity": {},
          "transports": [
            {
              "kind": "system-audio-input",
              "role": "voice-input",
              "status": "\(status)",
              "notes": "Test transport."
            }
          ],
          "capabilities": ["voice-capture"],
          "platforms": [
            { "platform": "macos", "status": "\(status)", "notes": "Test platform." }
          ],
          "sources": ["https://example.com/device"]
        }
        """
    }

    private func write(_ text: String, named name: String, to directory: URL) throws {
        try Data(text.utf8).write(to: directory.appendingPathComponent(name))
    }

    func testLoadsRepositoryProfilesFromOneDirectory() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let profiles = try DeviceProfileCatalog.load(
            directory: repositoryRoot.appendingPathComponent("device-profiles", isDirectory: true)
        )

        XCTAssertEqual(profiles.map(\.id), ["xiaomi-arn9", "xiaomi-rc003", "dji-mic-2"])
        XCTAssertEqual(
            profiles.first(where: { $0.id == "xiaomi-arn9" })?.support.status,
            .implemented
        )
        XCTAssertEqual(
            profiles.first(where: { $0.id == "dji-mic-2" })?.platforms
                .first(where: { $0.platform == .windows })?.status,
            .planned
        )
    }

    func testMissingDirectoryFailsClosed() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        XCTAssertThrowsError(try DeviceProfileCatalog.load(directory: missing)) { error in
            XCTAssertEqual(error as? DeviceProfileCatalogError, .directoryUnavailable)
        }
    }

    func testMissingRequiredFieldFailsClosed() throws {
        try withTemporaryDirectory { directory in
            let missingDisplayName = profileJSON(id: "missing-field")
                .replacingOccurrences(of: "\n  \"displayName\": \"Test Device\",", with: "")
            try write(missingDisplayName, named: "missing.json", to: directory)

            XCTAssertThrowsError(try DeviceProfileCatalog.load(directory: directory)) { error in
                guard case let .invalidProfile(_, reason) = error as? DeviceProfileCatalogError else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertTrue(reason.contains("displayName"))
            }
        }
    }

    func testUnknownStatusFailsClosed() throws {
        try withTemporaryDirectory { directory in
            try write(
                profileJSON(id: "unknown-status", status: "beta"),
                named: "unknown.json",
                to: directory
            )

            XCTAssertThrowsError(try DeviceProfileCatalog.load(directory: directory)) { error in
                guard case let .invalidProfile(_, reason) = error as? DeviceProfileCatalogError else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertEqual(reason, "包含未知枚举值")
            }
        }
    }

    func testDuplicateIDsFailTheEntireCatalog() throws {
        try withTemporaryDirectory { directory in
            try write(profileJSON(id: "duplicate"), named: "one.json", to: directory)
            try write(profileJSON(id: "duplicate"), named: "two.json", to: directory)

            XCTAssertThrowsError(try DeviceProfileCatalog.load(directory: directory)) { error in
                XCTAssertEqual(error as? DeviceProfileCatalogError, .duplicateID("duplicate"))
            }
        }
    }
}
