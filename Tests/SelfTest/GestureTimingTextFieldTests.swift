import AppKit
import SwiftUI

func runGestureTimingTextFieldTests(_ check: (Bool, String) -> Void) {
    var draft = "350"
    var submits = 0
    let view = GestureTimingTextField(
        title: "双击间隔",
        text: Binding(get: { draft }, set: { draft = $0 }),
        range: 200...600, currentValue: { 350 }, onSubmit: { submits += 1 }
    )
    let coordinator = view.makeCoordinator()
    let field = NSTextField()
    field.stringValue = "a3中5.0"
    coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    check(
        draft == "350" && field.stringValue == "350",
        "native timing field: rejected characters disappear even when the filtered model value is unchanged"
    )
    field.stringValue = "1"
    coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    check(draft == "1" && submits == 0, "native timing field: partial numbers remain editable without saving")
    coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
    check(
        draft == "200" && field.stringValue == "200" && submits == 0,
        "native timing field: ending an edit clamps the visible field without implicitly saving"
    )
    field.stringValue = String(repeating: "9", count: 100)
    coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
    check(draft == "600" && field.stringValue == "600", "native timing field: oversized input visibly clamps to maximum")
    field.stringValue = ""
    coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
    check(draft == "350" && field.stringValue == "350", "native timing field: clearing restores the current saved value")
    field.stringValue = "9999"
    let handled = coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
    check(
        handled && draft == "600" && field.stringValue == "600" && submits == 1,
        "native timing field: Return normalizes and explicitly submits once"
    )
}
