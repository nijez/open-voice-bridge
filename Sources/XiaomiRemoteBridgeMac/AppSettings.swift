import Combine
import Foundation

final class AppSettings: ObservableObject {
    private enum Keys {
        static let gainDB = "gainDB"
        static let selectedAudioDeviceUID = "selectedAudioDeviceUID"
        static let customMappingEnabled = "customMappingEnabled"
        static let legacyExclusiveHID = "exclusiveHID"
        static let buttonBindings = "buttonBindings"
        static let peripheralIdentifier = "peripheralIdentifier"
        static let localFnMicEnabled = "localFnMicEnabled"
        static let localMicInputUID = "localMicInputUID"
        static let doubleClickToggleEnabled = "doubleClickToggleEnabled"
    }

    private let defaults: UserDefaults

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
