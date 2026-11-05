import Foundation

// The pre-gesture V2 reader's supported kinds and decoding contract. Decode the
// whole map, as that release did, so one unknown kind cannot hide in the test.
private enum LegacyV2ButtonBinding: Decodable, Equatable {
    case preset(ButtonAction)
    case shortcut(KeyChord)
    case hardwareFn

    private enum CodingKeys: String, CodingKey { case type, action, chord }
    private enum Kind: String, Decodable { case preset, shortcut, hardwareFn }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .preset: self = .preset(try container.decode(ButtonAction.self, forKey: .action))
        case .shortcut: self = .shortcut(try container.decode(KeyChord.self, forKey: .chord))
        case .hardwareFn: self = .hardwareFn
        }
    }
}

func runButtonSettingsTests(_ check: (Bool, String) -> Void) {
    let suite = "XiaomiRemoteBridgeMacSelfTest.buttonSettings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)

    var accepted = settings.setMultiActionTiming(doubleClickMs: 600, longPressMs: 500)
    check(
        accepted.doubleClickMs == 600 && accepted.longPressMs == 650,
        "timing settings: a double-only edit raises the unchanged long threshold"
    )
    accepted = settings.setMultiActionTiming(doubleClickMs: 600, longPressMs: 300)
    check(
        accepted.doubleClickMs == 250 && accepted.longPressMs == 300,
        "timing settings: a long-only edit lowers the unchanged double interval"
    )
    accepted = settings.setMultiActionTiming(doubleClickMs: 600, longPressMs: 400)
    check(
        accepted.doubleClickMs == 600 && accepted.longPressMs == 650,
        "timing settings: conflicting edits to both fields consistently prioritize double click"
    )
    accepted = settings.setMultiActionTiming(doubleClickMs: Int.min, longPressMs: Int.max)
    let reloaded = AppSettings(defaults: defaults)
    check(
        accepted.doubleClickMs == 200 && accepted.longPressMs == 1500 &&
            reloaded.multiActionDoubleClickMs == 200 && reloaded.multiActionLongPressMs == 1500,
        "timing settings: extreme inputs clamp and the accepted pair persists across reload"
    )
    settings.resetMultiActionTiming()
    check(
        settings.multiActionDoubleClickMs == MultiActionTiming.defaultDoubleClickMs &&
            settings.multiActionLongPressMs == MultiActionTiming.defaultLongPressMs,
        "timing settings: restoring defaults uses the same paired commit"
    )

    let chord = KeyChord(keyCode: 8, keyLabel: "C", modifiers: [.control])
    let target = ApplicationTarget(path: "/Applications/Example.app", bundleIdentifier: "test.example", name: "Example")
    settings.setBinding(.shortcut(chord), for: .back)
    for slot in ButtonGestureSlot.allCases {
        settings.setBinding(.openApplication(target), for: .tv, slot: slot)
    }
    do {
        let data = defaults.data(forKey: "buttonBindingsV2") ?? Data()
        let legacy = try JSONDecoder().decode([String: LegacyV2ButtonBinding].self, from: data)
        check(
            legacy[RemoteButton.tv.rawValue] == .preset(.disabled) &&
                legacy[RemoteButton.back.rawValue] == .shortcut(chord) &&
                legacy[RemoteButton.ok.rawValue] == .preset(.returnKey) &&
                legacy[RemoteButton.microphone.rawValue] == .hardwareFn,
            "binding compatibility: an old V2 reader loads the entire map with only new actions disabled"
        )
    } catch {
        check(false, "binding compatibility: old V2 reader rejected the map: \(error)")
    }
    let latest = AppSettings(defaults: defaults)
    check(
        ButtonGestureSlot.allCases.allSatisfy { latest.binding(for: .tv, slot: $0) == .openApplication(target) } &&
            latest.binding(for: .back) == .shortcut(chord),
        "binding compatibility: V2 projection preserves all V3 actions and gesture slots"
    )
    do {
        // Reproduce a V2 blob already written by the earlier local candidate.
        let unsafeV2 = try JSONEncoder().encode([RemoteButton.tv.rawValue: ButtonBinding.openApplication(target)])
        defaults.set(unsafeV2, forKey: "buttonBindingsV2")
        let originalV3 = defaults.data(forKey: "multiActionBindingsV3")
        _ = AppSettings(defaults: defaults)
        let repaired = try JSONDecoder().decode(
            [String: LegacyV2ButtonBinding].self,
            from: defaults.data(forKey: "buttonBindingsV2") ?? Data()
        )
        check(
            repaired[RemoteButton.tv.rawValue] == .preset(.disabled) &&
                repaired[RemoteButton.back.rawValue] == .shortcut(chord) &&
                defaults.data(forKey: "multiActionBindingsV3") == originalV3,
            "binding compatibility: launch repairs an existing unsafe V2 projection without modifying V3"
        )
    } catch {
        check(false, "binding compatibility: repairing an existing V2 projection failed: \(error)")
    }
}
