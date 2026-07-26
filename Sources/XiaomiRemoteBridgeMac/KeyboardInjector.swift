import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

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
        case .escape:
            postKey(code: 53)
        case .returnKey:
            postKey(code: 36)
        case .arrowUp:
            postKey(code: 126)
        case .arrowDown:
            postKey(code: 125)
        case .arrowLeft:
            postKey(code: 123)
        case .arrowRight:
            postKey(code: 124)
        case .deleteBackward:
            postKey(code: 51)
        case .showDesktop:
            postKey(code: 103, flags: .maskSecondaryFn)
        case .contextMenu:
            postKey(code: 109, flags: .maskShift)
        case .appSwitcher:
            postKey(code: 48, flags: .maskCommand)
        case .mouseRightClick:
            return postRightClick()
        case .volumeUp:
            postSystemKey(type: 0)
        case .volumeDown:
            postSystemKey(type: 1)
        case .volumeMute:
            postSystemKey(type: 7)
        case .playPause:
            postSystemKey(type: 16)
        }
        return true
    }

    private static func postKey(code: CGKeyCode, flags: CGEventFlags = []) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
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

    private static func postSystemKey(type: Int32) {
        postSystemKey(type: type, isDown: true)
        postSystemKey(type: type, isDown: false)
    }

    private static func postSystemKey(type: Int32, isDown: Bool) {
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
        ) else { return }
        guard let cgEvent = event.cgEvent else { return }
        cgEvent.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        cgEvent.post(tap: CGEventTapLocation.cghidEventTap)
    }
}
