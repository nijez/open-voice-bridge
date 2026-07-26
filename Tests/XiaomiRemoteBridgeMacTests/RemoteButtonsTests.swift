import Foundation
import Testing
@testable import XiaomiRemoteBridgeMac

@Suite("Remote buttons")
struct RemoteButtonsTests {
    @Test func parsesRC003ReportOneUsages() {
        let data = Data([0xF1, 0x00, 0x80, 0x00, 0x00, 0x00])
        #expect(RemoteHIDReportParser.usages(reportID: 1, data: data) == Set([UInt16(0xF1), UInt16(0x80)]))
    }

    @Test func acceptsFirmwareReportWithIncludedID() {
        let data = Data([0x01, 0x35, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(RemoteHIDReportParser.usages(reportID: 1, data: data) == Set([UInt16(0x35)]))
    }

    @Test func rejectsOtherReportsAndMalformedPayloads() {
        #expect(RemoteHIDReportParser.usages(reportID: 2, data: Data([0, 0])) == nil)
        #expect(RemoteHIDReportParser.usages(reportID: 1, data: Data()) == nil)
        #expect(RemoteHIDReportParser.usages(reportID: 1, data: Data([1])) == nil)
    }

    @Test func everyKnownUsageHasDefaultBinding() {
        for button in Set(RemoteButton.usageMap.values) {
            #expect(AppSettings.defaultBindings[button] != nil, Comment(rawValue: button.rawValue))
        }
    }

    @Test func usesVerifiedRC003UsageTable() {
        #expect(RemoteButton.usageMap == [
            0x28: .ok,
            0x35: .tv,
            0x4A: .home,
            0x4F: .right,
            0x50: .left,
            0x51: .down,
            0x52: .up,
            0x65: .menu,
            0x66: .power,
            0x80: .volumeUp,
            0x81: .volumeDown,
            0xF1: .back,
        ])
    }

    @Test func HIDPermissionGateFailsClosed() {
        #expect(!HIDPermissionGate.canMonitor(
            mappingEnabled: true,
            inputMonitoringGranted: false,
            accessibilityGranted: true
        ))
        #expect(!HIDPermissionGate.canMonitor(
            mappingEnabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: false
        ))
        #expect(HIDPermissionGate.canMonitor(
            mappingEnabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true
        ))
    }

    @Test func HIDPermissionRequestsAreSequentialAndOptIn() {
        #expect(HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: false,
            inputMonitoringGranted: false,
            accessibilityGranted: false
        ) == .none)
        #expect(HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: true,
            inputMonitoringGranted: false,
            accessibilityGranted: false
        ) == .inputMonitoring)
        #expect(HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: false
        ) == .accessibility)
        #expect(HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true
        ) == .none)
    }

    @Test func savedBindingsMergeWithDefaults() throws {
        let suiteName = "XiaomiRemoteBridgeMacTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let saved = try JSONEncoder().encode([RemoteButton.back.rawValue: ButtonAction.disabled])
        defaults.set(saved, forKey: "buttonBindings")
        let settings = AppSettings(defaults: defaults)

        #expect(settings.action(for: .back) == .disabled)
        #expect(settings.action(for: .up) == .arrowUp)
    }

    @Test func migratesLegacyExclusiveToggleToCustomMappingToggle() throws {
        let suiteName = "XiaomiRemoteBridgeMacTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "exclusiveHID")
        let settings = AppSettings(defaults: defaults)

        #expect(settings.customMappingEnabled)
    }

    @Test func deviceProfileDefaultsToRC003AndPersistsDJISelection() throws {
        let suiteName = "XiaomiRemoteBridgeMacTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = AppSettings(defaults: defaults)
        #expect(initial.selectedDeviceProfile == .xiaomiRC003)
        initial.selectedDeviceProfile = .djiMic2

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.selectedDeviceProfile == .djiMic2)
        #expect(MacDeviceProfile.allCases == [.xiaomiRC003, .djiMic2])
    }

    @Test func xiaomiRemoteVariantDefaultsToProAndPersistsARN9Selection() throws {
        let suiteName = "XiaomiRemoteBridgeMacTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = AppSettings(defaults: defaults)
        #expect(initial.xiaomiRemoteVariant == .rc003Pro)
        #expect(initial.xiaomiRemoteVariant.mappableButtons.contains(.tv))
        initial.xiaomiRemoteVariant = .arn9

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.xiaomiRemoteVariant == .arn9)
        #expect(!reloaded.xiaomiRemoteVariant.mappableButtons.contains(.tv))
        #expect(reloaded.xiaomiRemoteVariant.mappableButtons.contains(.menu))
    }

    @Test func xiaomiRemoteVariantUsesBluetoothModelNumberInsteadOfSharedName() {
        #expect(XiaomiRemoteVariant.detected(fromModelNumber: "ARN9") == .arn9)
        #expect(XiaomiRemoteVariant.detected(fromModelNumber: " arn9\n") == .arn9)
        #expect(XiaomiRemoteVariant.detected(fromModelNumber: "RC003") == .rc003Pro)
        #expect(XiaomiRemoteVariant.detected(fromModelNumber: "UNKNOWN") == nil)
    }

    @Test func launchAtLoginDefaultsOnAndPersistsOptOut() throws {
        let suiteName = "XiaomiRemoteBridgeMacTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = AppSettings(defaults: defaults)
        #expect(initial.launchAtLoginEnabled)
        initial.launchAtLoginEnabled = false

        let reloaded = AppSettings(defaults: defaults)
        #expect(!reloaded.launchAtLoginEnabled)
    }

    @Test func nativeEventDescriptorsCoverPotentialDuplicateEvents() {
        #expect(RemoteButton.up.nativeEvent == .keyboard(keyCode: 126))
        #expect(RemoteButton.ok.nativeEvent == .keyboard(keyCode: 36))
        #expect(RemoteButton.volumeUp.nativeEvent == .systemKey(type: 0))
        #expect(RemoteButton.back.nativeEvent == nil)
    }

    @Test func mouseRightClickActionHasStableRawValueAndDisplayName() {
        #expect(ButtonAction.mouseRightClick.rawValue == "mouseRightClick")
        #expect(ButtonAction.mouseRightClick.displayName == "鼠标右键（当前位置）")
        #expect(ButtonAction.allCases.contains(.mouseRightClick))
    }

    @Test func clarifiedActionsKeepRawValuesWhileRenamingDisplay() {
        #expect(ButtonAction.contextMenu.rawValue == "contextMenu")
        #expect(ButtonAction.contextMenu.displayName == "上下文菜单（Shift-F10）")
        #expect(ButtonAction.appSwitcher.rawValue == "appSwitcher")
        #expect(ButtonAction.appSwitcher.displayName == "切换应用（Command-Tab）")
    }

    @Test func menuDefaultBindingStaysContextMenu() {
        #expect(AppSettings.defaultBindings[.menu] == .contextMenu)
        #expect(AppSettings.defaultBindings[.tv] == .appSwitcher)
    }

    @Test func legacyActionJSONStillDecodesToSameActions() throws {
        let json = Data(#"{"menu":"contextMenu","tv":"appSwitcher"}"#.utf8)
        let decoded = try JSONDecoder().decode([String: ButtonAction].self, from: json)
        #expect(decoded["menu"] == .contextMenu)
        #expect(decoded["tv"] == .appSwitcher)
    }

    @Test func mouseRightClickBindingPersistsAndReloads() throws {
        let suiteName = "XiaomiRemoteBridgeMacTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let saved = try JSONEncoder().encode([RemoteButton.menu.rawValue: ButtonAction.mouseRightClick])
        defaults.set(saved, forKey: "buttonBindings")
        let settings = AppSettings(defaults: defaults)

        #expect(settings.action(for: .menu) == .mouseRightClick)
        #expect(settings.action(for: .tv) == .appSwitcher)
    }
}
