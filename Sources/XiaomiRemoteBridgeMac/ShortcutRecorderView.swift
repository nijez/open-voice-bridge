import AppKit
import SwiftUI

struct ShortcutRecorderView: View {
    let button: RemoteButton
    let onCancel: () -> Void
    let onClear: () -> Void
    let onRecord: (KeyChord) -> Void

    @State private var monitor: Any?
    @State private var preview = "请按下快捷键"
    @State private var errorText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置\(button.displayName)")
                .font(.title3.weight(.semibold))
            Text("直接按下一个单键，或按住 Command、Control、Option、Shift 后再按一个键。")
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Text(preview)
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .background(Color.accentColor.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Spacer()
            }

            if !errorText.isEmpty {
                Text(errorText)
                    .font(.footnote)
                    .foregroundColor(.red)
            }

            Text("录制只在此窗口打开期间生效；不会记录文字内容，也不会执行脚本或命令。")
                .font(.footnote)
                .foregroundColor(.secondary)

            HStack {
                Button("禁用这个按键", action: onClear)
                Spacer()
                Button("取消", action: onCancel)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { startMonitoring() }
        .onDisappear { stopMonitoring() }
    }

    private func startMonitoring() {
        stopMonitoring()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.getIntegerValueFieldIfSynthetic == nil else { return event }
            guard let chord = KeyChord.from(event: event) else {
                errorText = "这个键暂时无法安全注入，请换一个普通键或功能键。"
                return nil
            }
            preview = chord.displayName
            errorText = ""
            DispatchQueue.main.async { onRecord(chord) }
            return nil
        }
    }

    private func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private extension NSEvent {
    var getIntegerValueFieldIfSynthetic: Int64? {
        guard let cgEvent else { return nil }
        let marker = cgEvent.getIntegerValueField(.eventSourceUserData)
        return marker == KeyboardInjector.syntheticEventMarker ? marker : nil
    }
}

extension KeyChord {
    static func from(event: NSEvent) -> Self? {
        guard event.type == .keyDown,
              let label = label(for: event)
        else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return Self(keyCode: event.keyCode, keyLabel: label, modifiers: modifiers)
    }

    private static func label(for event: NSEvent) -> String? {
        let fixed: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
            76: "Enter", 115: "Home", 116: "Page Up", 117: "Forward Delete",
            119: "End", 121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
            80: "F19", 90: "F20",
        ]
        if let label = fixed[event.keyCode] { return label }
        guard let characters = event.charactersIgnoringModifiers,
              characters.count == 1,
              let scalar = characters.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar)
        else { return nil }
        return characters.uppercased()
    }
}
