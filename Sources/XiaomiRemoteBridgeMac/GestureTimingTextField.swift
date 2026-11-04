import AppKit
import SwiftUI

/// Use the native field editor directly: filtering only a SwiftUI Binding can
/// leave rejected characters visible when the filtered state did not change.
struct GestureTimingTextField: NSViewRepresentable {
    let title: String
    @Binding var text: String
    let range: ClosedRange<Int>
    let currentValue: () -> Int
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = GestureTimingNativeTextField()
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.alignment = .right
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = title
        field.setAccessibilityLabel(title)
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            field.currentEditor()?.string = text
        }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        (field as? GestureTimingNativeTextField)?.stopMonitoringClicks()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: GestureTimingTextField

        init(_ parent: GestureTimingTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let raw = field.stringValue
            let filtered = MultiActionTimingInput.digits(in: raw)
            if raw != filtered {
                let editor = field.currentEditor()
                let cursor = min(editor?.selectedRange.location ?? (raw as NSString).length, (raw as NSString).length)
                let prefix = (raw as NSString).substring(to: cursor)
                let filteredCursor = MultiActionTimingInput.digits(in: prefix).utf16.count
                field.stringValue = filtered
                editor?.string = filtered
                editor?.selectedRange = NSRange(location: filteredCursor, length: 0)
            }
            parent.text = filtered
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            normalize(field)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  let field = control as? NSTextField else { return false }
            normalize(field)
            parent.onSubmit()
            return true
        }

        private func normalize(_ field: NSTextField) {
            let value = MultiActionTimingInput.committedValue(
                from: field.stringValue, fallback: parent.currentValue(), range: parent.range
            )
            let normalized = String(value)
            field.stringValue = normalized
            field.currentEditor()?.string = normalized
            parent.text = normalized
        }
    }
}

/// AppKit can pick the first native text field when a SwiftUI page appears and
/// leave it editing when a SwiftUI button or empty area is clicked. Keep that
/// behavior local to the timing fields without intercepting the target's click.
private final class GestureTimingNativeTextField: NSTextField {
    private var clickMonitor: Any?
    private var explicitFocusGeneration = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoringClicks()
        guard let window else { return }

        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  self.currentEditor() != nil else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            if !self.bounds.contains(point) {
                window.makeFirstResponder(nil)
            }
            return event
        }

        let generation = explicitFocusGeneration
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window,
                  self.explicitFocusGeneration == generation,
                  let responder = window.firstResponder,
                  responder === self || responder === self.currentEditor() else { return }
            window.makeFirstResponder(nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        explicitFocusGeneration += 1
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        if let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == 48 {
            explicitFocusGeneration += 1 // Tab / Shift+Tab remains normal keyboard navigation.
        }
        return super.becomeFirstResponder()
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        if focused { explicitFocusGeneration += 1 }
        super.setAccessibilityFocused(focused)
    }

    func stopMonitoringClicks() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    deinit { stopMonitoringClicks() }
}
