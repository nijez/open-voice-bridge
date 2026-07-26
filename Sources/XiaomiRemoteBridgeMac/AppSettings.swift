import Combine
import Foundation

enum MacDeviceProfile: String, CaseIterable, Identifiable {
    case xiaomiRC003 = "xiaomi-rc003"
    case djiMic2 = "dji-mic-2"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .xiaomiRC003:
            return "小米蓝牙语音遥控器"
        case .djiMic2:
            return "DJI Mic 2"
        }
    }

    var shortName: String {
        switch self {
        case .xiaomiRC003: return "RC003"
        case .djiMic2: return "DJI Mic 2"
        }
    }
}

enum XiaomiRemoteVariant: String, CaseIterable, Identifiable {
    case rc003Pro = "xiaomi-rc003-pro"
    case arn9 = "xiaomi-arn9"

    var id: String { rawValue }

    static func detected(fromModelNumber modelNumber: String) -> Self? {
        switch modelNumber
            .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
            .uppercased()
        {
        case "RC003": return .rc003Pro
        case "ARN9": return .arn9
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .rc003Pro: return "小米蓝牙语音遥控器 2 Pro"
        case .arn9: return "小米蓝牙语音遥控器（普通款）"
        }
    }

    var shortName: String {
        switch self {
        case .rc003Pro: return "2 Pro"
        case .arn9: return "普通款 ARN9"
        }
    }

    var imageResourceName: String {
        switch self {
        case .rc003Pro: return "RC003-remote-photo"
        case .arn9: return "ARN9-remote-photo"
        }
    }

    var mappableButtons: [RemoteButton] {
        switch self {
        case .rc003Pro:
            return RemoteButton.allCases
        case .arn9:
            return RemoteButton.allCases.filter { $0 != .tv }
        }
    }
}

final class AppSettings: ObservableObject {
    private enum Keys {
        static let selectedDeviceProfile = "selectedDeviceProfile"
        static let xiaomiRemoteVariant = "xiaomiRemoteVariant"
        static let gainDB = "gainDB"
        static let selectedAudioDeviceUID = "selectedAudioDeviceUID"
        static let customMappingEnabled = "customMappingEnabled"
        static let legacyExclusiveHID = "exclusiveHID"
        static let buttonBindings = "buttonBindings"
        static let peripheralIdentifier = "peripheralIdentifier"
        static let localFnMicEnabled = "localFnMicEnabled"
        static let localMicInputUID = "localMicInputUID"
        static let doubleClickToggleEnabled = "doubleClickToggleEnabled"
        static let launchAtLoginEnabled = "launchAtLoginEnabled"
    }

    private let defaults: UserDefaults

    @Published var selectedDeviceProfile: MacDeviceProfile {
        didSet { defaults.set(selectedDeviceProfile.rawValue, forKey: Keys.selectedDeviceProfile) }
    }

    @Published var xiaomiRemoteVariant: XiaomiRemoteVariant {
        didSet { defaults.set(xiaomiRemoteVariant.rawValue, forKey: Keys.xiaomiRemoteVariant) }
    }

    @Published var gainDB: Double {
        didSet { defaults.set(gainDB, forKey: Keys.gainDB) }
    }

    @Published var selectedAudioDeviceUID: String {
        didSet { defaults.set(selectedAudioDeviceUID, forKey: Keys.selectedAudioDeviceUID) }
    }

    @Published var customMappingEnabled: Bool {
        didSet { defaults.set(customMappingEnabled, forKey: Keys.customMappingEnabled) }
    }

    /// Off by default: the Mac built-in microphone is never requested or captured
    /// until the user explicitly turns this on.
    @Published var localFnMicEnabled: Bool {
        didSet { defaults.set(localFnMicEnabled, forKey: Keys.localFnMicEnabled) }
    }

    /// Empty string means "follow the system default input device".
    @Published var localMicInputUID: String {
        didSet { defaults.set(localMicInputUID, forKey: Keys.localMicInputUID) }
    }

    /// Whether the RC003 voice-key double-click toggles the bridge runtime on/off.
    /// On by default; this only governs gesture recognition. The runtime
    /// enabled/disabled state itself is intentionally NOT persisted (the app
    /// always starts enabled), and the explicit Settings/menu button works even
    /// when this is off.
    @Published var doubleClickToggleEnabled: Bool {
        didSet { defaults.set(doubleClickToggleEnabled, forKey: Keys.doubleClickToggleEnabled) }
    }

    /// Desired login-item state. On by default so the bridge is available after
    /// a restart; the platform manager reports whether the OS accepted it.
    @Published var launchAtLoginEnabled: Bool {
        didSet { defaults.set(launchAtLoginEnabled, forKey: Keys.launchAtLoginEnabled) }
    }

    @Published var buttonBindings: [RemoteButton: ButtonAction] {
        didSet { saveBindings() }
    }

    var peripheralIdentifier: UUID? {
        get {
            guard let raw = defaults.string(forKey: Keys.peripheralIdentifier) else { return nil }
            return UUID(uuidString: raw)
        }
        set {
            defaults.set(newValue?.uuidString, forKey: Keys.peripheralIdentifier)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedDeviceProfile = MacDeviceProfile(
            rawValue: defaults.string(forKey: Keys.selectedDeviceProfile) ?? ""
        ) ?? .xiaomiRC003
        xiaomiRemoteVariant = XiaomiRemoteVariant(
            rawValue: defaults.string(forKey: Keys.xiaomiRemoteVariant) ?? ""
        ) ?? .rc003Pro
        gainDB = defaults.object(forKey: Keys.gainDB) == nil
            ? 10.0
            : defaults.double(forKey: Keys.gainDB)
        selectedAudioDeviceUID = defaults.string(forKey: Keys.selectedAudioDeviceUID) ?? ""
        if defaults.object(forKey: Keys.customMappingEnabled) != nil {
            customMappingEnabled = defaults.bool(forKey: Keys.customMappingEnabled)
        } else {
            customMappingEnabled = defaults.bool(forKey: Keys.legacyExclusiveHID)
        }
        localFnMicEnabled = defaults.bool(forKey: Keys.localFnMicEnabled)
        localMicInputUID = defaults.string(forKey: Keys.localMicInputUID) ?? ""
        doubleClickToggleEnabled = defaults.object(forKey: Keys.doubleClickToggleEnabled) == nil
            ? true
            : defaults.bool(forKey: Keys.doubleClickToggleEnabled)
        launchAtLoginEnabled = defaults.object(forKey: Keys.launchAtLoginEnabled) == nil
            ? true
            : defaults.bool(forKey: Keys.launchAtLoginEnabled)
        if
            let data = defaults.data(forKey: Keys.buttonBindings),
            let decoded = try? JSONDecoder().decode([String: ButtonAction].self, from: data)
        {
            buttonBindings = Self.defaultBindings.merging(
                Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
                    RemoteButton(rawValue: key).map { ($0, value) }
                })
            ) { _, saved in saved }
        } else {
            buttonBindings = Self.defaultBindings
        }
    }

    func action(for button: RemoteButton) -> ButtonAction {
        buttonBindings[button] ?? .disabled
    }

    func setAction(_ action: ButtonAction, for button: RemoteButton) {
        buttonBindings[button] = action
    }

    func resetBindings() {
        buttonBindings = Self.defaultBindings
    }

    private func saveBindings() {
        let raw = Dictionary(uniqueKeysWithValues: buttonBindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Keys.buttonBindings)
        }
    }

    static let defaultBindings: [RemoteButton: ButtonAction] = [
        .power: .escape,
        .up: .arrowUp,
        .left: .arrowLeft,
        .ok: .returnKey,
        .right: .arrowRight,
        .down: .arrowDown,
        .back: .deleteBackward,
        .volumeUp: .volumeUp,
        .home: .showDesktop,
        .volumeDown: .volumeDown,
        .menu: .contextMenu,
        .tv: .appSwitcher,
    ]
}
