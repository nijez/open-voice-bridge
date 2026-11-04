import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum HeldButtonBinding: Equatable {
    case key(keyCode: UInt16, modifiers: KeyChord.Modifiers)
    case systemKey(type: Int32, repeats: Bool)

    var supportsRepeat: Bool {
        switch self {
        case .key: return true
        case .systemKey(_, let repeats): return repeats
        }
    }
}

struct ButtonHoldStartResult {
    let delivered: Bool
    let heldBinding: HeldButtonBinding?
}

enum KeyboardInjector {
    static let syntheticEventMarker: Int64 = 0x5849_414F

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func send(_ action: ButtonAction) -> Bool {
        guard action != .disabled else { return true }
        guard isAccessibilityTrusted else { return false }

        switch action {
        case .disabled:
            return true
        case .mouseRightClick:
            return postRightClick()
        default:
            guard let binding = presetKeyBinding(for: action) else { return false }
            switch binding {
            case .key(let keyCode, let modifiers):
                return postKey(code: CGKeyCode(keyCode), flags: cgFlags(for: modifiers))
            case .systemKey(let type, _):
                return postSystemKey(type: type)
            }
        }
    }

    @discardableResult
    static func send(
        _ binding: ButtonBinding,
        openApplication: (ApplicationTarget) -> Void = ApplicationLauncher.open
    ) -> Bool {
        switch binding {
        case let .preset(action): return send(action)
        case let .shortcut(chord): return send(chord, edge: nil)
        case let .openApplication(target):
            openApplication(target)
            return true
        case .hardwareFn: return true
        }
    }

    /// Starts a QMK-style held action. Keyboard and system-key bindings receive
    /// a real down edge and return a token that must be balanced with `endHold`.
    /// Momentary actions such as right-click execute once and return no token.
    static func beginHold(
        _ binding: ButtonBinding,
        openApplication: (ApplicationTarget) -> Void = ApplicationLauncher.open
    ) -> ButtonHoldStartResult {
        switch binding {
        case .hardwareFn, .preset(.disabled):
            return ButtonHoldStartResult(delivered: true, heldBinding: nil)

        case .preset(.mouseRightClick):
            return ButtonHoldStartResult(delivered: send(binding), heldBinding: nil)

        case .openApplication:
            return ButtonHoldStartResult(
                delivered: send(binding, openApplication: openApplication), heldBinding: nil
            )

        case .preset(let action):
            guard let heldBinding = presetKeyBinding(for: action) else {
                return ButtonHoldStartResult(delivered: false, heldBinding: nil)
            }
            return ButtonHoldStartResult(
                delivered: sendHeld(heldBinding, isDown: true, isRepeat: false),
                heldBinding: heldBinding
            )

        case .shortcut(let chord):
            let heldBinding = HeldButtonBinding.key(
                keyCode: chord.keyCode,
                modifiers: chord.modifiers
            )
            return ButtonHoldStartResult(
                delivered: chord.isValid && sendHeld(heldBinding, isDown: true, isRepeat: false),
                heldBinding: chord.isValid ? heldBinding : nil
            )
        }
    }

    static func repeatHold(_ heldBinding: HeldButtonBinding) -> Bool {
        guard heldBinding.supportsRepeat else { return true }
        return sendHeld(heldBinding, isDown: true, isRepeat: true)
    }

    static func endHold(_ heldBinding: HeldButtonBinding) -> Bool {
        sendHeld(heldBinding, isDown: false, isRepeat: false)
    }

    /// Sends either one edge (for a hold-style binding such as the microphone
    /// key) or an atomic tap. Every event is constructed before anything is
    /// posted, so construction failure cannot leave a half-delivered chord.
    @discardableResult
    static func send(_ chord: KeyChord, edge: RemoteEventEdge?) -> Bool {
        guard chord.isValid,
              isAccessibilityTrusted,
              let source = CGEventSource(stateID: .hidSystemState)
        else { return false }
        let flags = cgFlags(for: chord.modifiers)

        func makeEvent(isDown: Bool) -> CGEvent? {
            makeKeyEvent(source: source, code: CGKeyCode(chord.keyCode), flags: flags, isDown: isDown)
        }

        switch edge {
        case .down:
            guard let event = makeEvent(isDown: true) else { return false }
            event.post(tap: .cghidEventTap)
        case .up:
            guard let event = makeEvent(isDown: false) else { return false }
            event.post(tap: .cghidEventTap)
        case nil:
            guard let down = makeEvent(isDown: true),
                  let up = makeEvent(isDown: false)
            else { return false }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    private static func cgFlags(for modifiers: KeyChord.Modifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    private static func postKey(code: CGKeyCode, flags: CGEventFlags = []) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = makeKeyEvent(source: source, code: code, flags: flags, isDown: true),
              let up = makeKeyEvent(source: source, code: code, flags: flags, isDown: false)
        else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Posts a single real right-click (down + up) at the current mouse cursor
    /// position. The cursor location is read from a null `CGEvent(source:)` — the
    /// CoreGraphics event coordinate space — instead of `NSEvent.mouseLocation`,
    /// whose bottom-left AppKit coordinates would land the click in the wrong place.
    /// Any failure to build the event source, the location probe, or either mouse
    /// event returns `false` so the HID path fails closed rather than faking success.
    private static func postRightClick() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let locationProbe = CGEvent(source: source)
        else { return false }
        let location = locationProbe.location
        guard let down = CGEvent(
                  mouseEventSource: source,
                  mouseType: .rightMouseDown,
                  mouseCursorPosition: location,
                  mouseButton: .right
              ),
              let up = CGEvent(
                  mouseEventSource: source,
                  mouseType: .rightMouseUp,
                  mouseCursorPosition: location,
                  mouseButton: .right
              )
        else { return false }
        down.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func postSystemKey(type: Int32) -> Bool {
        guard let down = makeSystemKeyEvent(type: type, isDown: true),
              let up = makeSystemKeyEvent(type: type, isDown: false)
        else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Shared preset mapping for atomic taps and held edges. Momentary actions
    /// have no key binding and are dispatched separately by their callers.
    static func presetKeyBinding(for action: ButtonAction) -> HeldButtonBinding? {
        switch action {
        case .disabled, .mouseRightClick:
            return nil
        case .escape:
            return .key(keyCode: 53, modifiers: [])
        case .returnKey:
            return .key(keyCode: 36, modifiers: [])
        case .arrowUp:
            return .key(keyCode: 126, modifiers: [])
        case .arrowDown:
            return .key(keyCode: 125, modifiers: [])
        case .arrowLeft:
            return .key(keyCode: 123, modifiers: [])
        case .arrowRight:
            return .key(keyCode: 124, modifiers: [])
        case .deleteBackward:
            return .key(keyCode: 51, modifiers: [])
        case .showDesktop:
            return .key(keyCode: 103, modifiers: [.function])
        case .contextMenu:
            return .key(keyCode: 109, modifiers: [.shift])
        case .appSwitcher:
            return .key(keyCode: 48, modifiers: [.command])
        case .volumeUp:
            return .systemKey(type: 0, repeats: true)
        case .volumeDown:
            return .systemKey(type: 1, repeats: true)
        case .volumeMute:
            return .systemKey(type: 7, repeats: false)
        case .playPause:
            return .systemKey(type: 16, repeats: false)
        }
    }

    private static func sendHeld(
        _ heldBinding: HeldButtonBinding,
        isDown: Bool,
        isRepeat: Bool
    ) -> Bool {
        guard isAccessibilityTrusted else { return false }
        switch heldBinding {
        case .key(let keyCode, let modifiers):
            guard let source = CGEventSource(stateID: .hidSystemState),
                  let event = makeKeyEvent(
                      source: source,
                      code: CGKeyCode(keyCode),
                      flags: cgFlags(for: modifiers),
                      isDown: isDown,
                      isRepeat: isRepeat
                  )
            else { return false }
            event.post(tap: .cghidEventTap)
            return true

        case .systemKey(let type, _):
            guard let event = makeSystemKeyEvent(type: type, isDown: isDown) else { return false }
            event.post(tap: .cghidEventTap)
            return true
        }
    }

    private static func makeKeyEvent(
        source: CGEventSource,
        code: CGKeyCode,
        flags: CGEventFlags,
        isDown: Bool,
        isRepeat: Bool = false
    ) -> CGEvent? {
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: code,
            keyDown: isDown
        ) else { return nil }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        if isRepeat {
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        return event
    }

    private static func makeSystemKeyEvent(type: Int32, isDown: Bool) -> CGEvent? {
        let keyState = isDown ? 0xA : 0xB
        let data1 = Int((type << 16) | Int32(keyState << 8))
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { return nil }
        guard let cgEvent = event.cgEvent else { return nil }
        cgEvent.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        return cgEvent
    }
}
