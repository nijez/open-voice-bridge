import Foundation

enum RemoteButton: String, CaseIterable, Codable, Identifiable {
    case microphone
    case power
    case up
    case left
    case ok
    case right
    case down
    case back
    case volumeUp = "volume_up"
    case home
    case volumeDown = "volume_down"
    case menu
    case tv

    var id: String { rawValue }

    var hidUsage: UInt16 {
        switch self {
        case .microphone: return 0x3E
        case .power: return 0x66
        case .up: return 0x52
        case .left: return 0x50
        case .ok: return 0x28
        case .right: return 0x4F
        case .down: return 0x51
        case .back: return 0xF1
        case .volumeUp: return 0x80
        case .home: return 0x4A
        case .volumeDown: return 0x81
        case .menu: return 0x65
        case .tv: return 0x35
        }
    }

    var shortLabel: String {
        switch self {
        case .microphone: return "语音"
        case .power: return "电源"
        case .up: return "上"
        case .left: return "左"
        case .ok: return "OK"
        case .right: return "右"
        case .down: return "下"
        case .back: return "返回"
        case .volumeUp: return "+"
        case .home: return "主页"
        case .volumeDown: return "−"
        case .menu: return "菜单"
        case .tv: return "TV"
        }
    }

    var displayName: String {
        switch self {
        case .microphone: return "语音键"
        case .power: return "电源键"
        case .up: return "上键"
        case .left: return "左键"
        case .ok: return "确定键"
        case .right: return "右键"
        case .down: return "下键"
        case .back: return "返回键"
        case .volumeUp: return "音量 +"
        case .home: return "主页键"
        case .volumeDown: return "音量 -"
        case .menu: return "菜单键"
        case .tv: return "TV 键"
        }
    }

    static let usageMap = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0.hidUsage, $0) }
    )

    var nativeEvent: RemoteNativeEvent? {
        switch self {
        case .microphone: return .keyboard(keyCode: 96)
        case .ok: return .keyboard(keyCode: 36)
        case .tv: return .keyboard(keyCode: 50)
        case .home: return .keyboard(keyCode: 115)
        case .right: return .keyboard(keyCode: 124)
        case .left: return .keyboard(keyCode: 123)
        case .down: return .keyboard(keyCode: 125)
        case .up: return .keyboard(keyCode: 126)
        case .menu: return .keyboard(keyCode: 110)
        case .power: return .systemKey(type: 6)
        case .volumeUp: return .systemKey(type: 0)
        case .volumeDown: return .systemKey(type: 1)
        case .back: return nil
        }
    }
}

enum RemoteNativeEvent: Equatable, Hashable {
    case keyboard(keyCode: UInt16)
    case systemKey(type: Int32)
}

enum RemoteEventEdge: Equatable {
    case down
    case up
}

enum ButtonAction: String, CaseIterable, Codable, Identifiable {
    case disabled
    case escape
    case returnKey
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case deleteBackward
    case showDesktop
    case contextMenu
    case appSwitcher
    case mouseRightClick
    case volumeUp
    case volumeDown
    case volumeMute
    case playPause

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .disabled: return "禁用"
        case .escape: return "Escape"
        case .returnKey: return "Return"
        case .arrowUp: return "方向上"
        case .arrowDown: return "方向下"
        case .arrowLeft: return "方向左"
        case .arrowRight: return "方向右"
        case .deleteBackward: return "Delete（退格）"
        case .showDesktop: return "显示桌面"
        case .contextMenu: return "上下文菜单（Shift-F10）"
        case .appSwitcher: return "切换应用（Command-Tab）"
        case .mouseRightClick: return "鼠标右键（当前位置）"
        case .volumeUp: return "系统音量 +"
        case .volumeDown: return "系统音量 -"
        case .volumeMute: return "系统静音"
        case .playPause: return "播放 / 暂停"
        }
    }
}

struct KeyChord: Codable, Equatable, Hashable {
    struct Modifiers: OptionSet, Codable, Hashable {
        let rawValue: UInt8

        static let command = Self(rawValue: 1 << 0)
        static let control = Self(rawValue: 1 << 1)
        static let option = Self(rawValue: 1 << 2)
        static let shift = Self(rawValue: 1 << 3)
        static let function = Self(rawValue: 1 << 4)
    }

    let keyCode: UInt16
    let keyLabel: String
    let modifiers: Modifiers

    var isValid: Bool {
        keyCode <= 127 && !keyLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && keyLabel.count <= 24
    }

    var displayName: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(keyLabel)
        return parts.joined()
    }
}

struct ApplicationTarget: Codable, Equatable {
    let path: String
    let bundleIdentifier: String?
    let name: String

    var isValid: Bool {
        (path as NSString).isAbsolutePath &&
            URL(fileURLWithPath: path).pathExtension.lowercased() == "app" &&
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func application(at url: URL) -> Self? {
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url),
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path)
        else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return Self(path: url.path, bundleIdentifier: bundle.bundleIdentifier, name: name)
    }
}

enum ButtonBinding: Codable, Equatable {
    case preset(ButtonAction)
    case shortcut(KeyChord)
    case openApplication(ApplicationTarget)
    case hardwareFn

    private enum CodingKeys: String, CodingKey { case type, action, chord, application }
    private enum Kind: String, Codable { case preset, shortcut, openApplication, hardwareFn }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .preset:
            self = .preset(try container.decode(ButtonAction.self, forKey: .action))
        case .shortcut:
            self = .shortcut(try container.decode(KeyChord.self, forKey: .chord))
        case .openApplication:
            self = .openApplication(try container.decode(ApplicationTarget.self, forKey: .application))
        case .hardwareFn:
            self = .hardwareFn
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .preset(action):
            try container.encode(Kind.preset, forKey: .type)
            try container.encode(action, forKey: .action)
        case let .shortcut(chord):
            try container.encode(Kind.shortcut, forKey: .type)
            try container.encode(chord, forKey: .chord)
        case let .openApplication(application):
            try container.encode(Kind.openApplication, forKey: .type)
            try container.encode(application, forKey: .application)
        case .hardwareFn:
            try container.encode(Kind.hardwareFn, forKey: .type)
        }
    }

    var displayName: String {
        switch self {
        case let .preset(action): return action.displayName
        case let .shortcut(chord): return chord.displayName
        case let .openApplication(application): return "打开 \(application.name)"
        case .hardwareFn: return "硬件 Fn（默认语音）"
        }
    }

    var isDisabled: Bool {
        if case .preset(.disabled) = self { return true }
        return false
    }

    /// V2 readers decode the entire map together and cannot read newer kinds.
    /// Preserve their supported actions and disable only unsupported ones.
    var legacyV2Binding: ButtonBinding {
        switch self {
        case .preset, .shortcut, .hardwareFn: return self
        case .openApplication: return .preset(.disabled)
        }
    }
}

enum ButtonGestureSlot: String, CaseIterable, Codable, Identifiable {
    case single
    case doublePress = "double"
    case longPress = "long"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .single: return "单击"
        case .doublePress: return "双击"
        case .longPress: return "长按"
        }
    }
}

struct MultiActionButtonBinding: Codable, Equatable {
    var single: ButtonBinding
    var doublePress: ButtonBinding?
    var longPress: ButtonBinding?

    init(
        single: ButtonBinding,
        doublePress: ButtonBinding? = nil,
        longPress: ButtonBinding? = nil
    ) {
        self.single = single
        self.doublePress = doublePress
        self.longPress = longPress
    }

    var hasAdditionalActions: Bool {
        doublePress != nil || longPress != nil
    }

    func binding(for slot: ButtonGestureSlot) -> ButtonBinding? {
        switch slot {
        case .single: return single
        case .doublePress: return doublePress
        case .longPress: return longPress
        }
    }

    mutating func setBinding(_ binding: ButtonBinding?, for slot: ButtonGestureSlot) {
        switch slot {
        case .single:
            if let binding { single = binding }
        case .doublePress:
            doublePress = binding
        case .longPress:
            longPress = binding
        }
    }
}

enum MultiActionTimingInput {
    static func digits(in text: String) -> String {
        text.filter { $0 >= "0" && $0 <= "9" }
    }

    static func committedValue(
        from text: String, fallback: Int, range: ClosedRange<Int>
    ) -> Int {
        let filtered = digits(in: text)
        // An empty edit restores the saved value. An integer overflow can only
        // represent an excessively large nonnegative input, so use the maximum.
        let value = filtered.isEmpty ? fallback : (Int(filtered) ?? range.upperBound)
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

enum MultiActionTiming {
    static let defaultDoubleClickMs = 350
    static let defaultLongPressMs = 500
    static let minimumDoubleClickMs = 200
    static let maximumDoubleClickMs = 600
    static let minimumLongPressMs = 300
    static let maximumLongPressMs = 1_500
    static let minimumGapMs = 50

    static func normalized(doubleClickMs: Int, longPressMs: Int) -> (doubleClickMs: Int, longPressMs: Int) {
        let doubleClick = min(
            max(doubleClickMs, minimumDoubleClickMs),
            maximumDoubleClickMs
        )
        var longPress = min(
            max(longPressMs, minimumLongPressMs),
            maximumLongPressMs
        )
        if longPress <= doubleClick {
            longPress = min(maximumLongPressMs, doubleClick + minimumGapMs)
        }
        return (doubleClick, longPress)
    }
}

struct HeldKeyChordLatch {
    private(set) var chord: KeyChord?

    var isHeld: Bool { chord != nil }

    mutating func press(_ chord: KeyChord) {
        self.chord = chord
    }

    @discardableResult
    mutating func release(using deliver: (KeyChord) -> Bool) -> Bool {
        guard let chord else { return true }
        guard deliver(chord) else { return false }
        self.chord = nil
        return true
    }
}

enum VoiceBindingChangeGate {
    static func canChange(isStreaming: Bool, physicalKeyDown: Bool) -> Bool {
        !isStreaming && !physicalKeyDown
    }
}

enum RemoteHIDReportParser {
    static func usages(reportID: UInt32, data: Data) -> Set<UInt16>? {
        guard reportID == 1 else { return nil }
        var bytes = Array(data)
        if bytes.count == 7, bytes.first == UInt8(reportID) {
            bytes.removeFirst()
        }
        guard !bytes.isEmpty, bytes.count.isMultiple(of: 2) else { return nil }

        var result = Set<UInt16>()
        for index in stride(from: 0, to: bytes.count, by: 2) {
            let usage = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            if usage != 0 { result.insert(usage) }
        }
        return result
    }
}

enum HIDPermissionGate {
    /// Check live permissions at the platform delivery boundary, including
    /// timer-driven actions. Releases still get a best-effort delivery attempt.
    static func deliverGestureOutputs(
        _ outputs: [MultiActionGestureOutput],
        permissionsAreValid: () -> Bool,
        perform: (MultiActionGestureOutput) -> Bool
    ) -> Bool {
        for output in outputs {
            if output != .endHold && !permissionsAreValid() { return false }
            guard perform(output) else { return false }
        }
        return true
    }

    static func canMonitor(
        mappingEnabled: Bool,
        inputMonitoringGranted: Bool,
        accessibilityGranted: Bool
    ) -> Bool {
        mappingEnabled && inputMonitoringGranted && accessibilityGranted
    }

    static func nextPermissionRequest(
        mappingEnabled: Bool,
        inputMonitoringGranted: Bool,
        accessibilityGranted: Bool
    ) -> HIDPermissionRequest {
        guard mappingEnabled else { return .none }
        if !inputMonitoringGranted { return .inputMonitoring }
        if !accessibilityGranted { return .accessibility }
        return .none
    }
}

enum HIDPermissionRequest: Equatable {
    case none
    case inputMonitoring
    case accessibility
}
