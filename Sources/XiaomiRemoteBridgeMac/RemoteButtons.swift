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

enum RemoteNativeEvent: Equatable {
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

enum ButtonBinding: Codable, Equatable {
    case preset(ButtonAction)
    case shortcut(KeyChord)
    case hardwareFn

    private enum CodingKeys: String, CodingKey { case type, action, chord }
    private enum Kind: String, Codable { case preset, shortcut, hardwareFn }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .preset:
            self = .preset(try container.decode(ButtonAction.self, forKey: .action))
        case .shortcut:
            self = .shortcut(try container.decode(KeyChord.self, forKey: .chord))
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
        case .hardwareFn:
            try container.encode(Kind.hardwareFn, forKey: .type)
        }
    }

    var displayName: String {
        switch self {
        case let .preset(action): return action.displayName
        case let .shortcut(chord): return chord.displayName
        case .hardwareFn: return "硬件 Fn（默认语音）"
        }
    }

    var isDisabled: Bool {
        if case .preset(.disabled) = self { return true }
        return false
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
