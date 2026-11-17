import ApplicationServices
import CoreGraphics
import Foundation

let lock = NSLock()
var seen: [String] = []
let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) |
    (CGEventMask(1) << CGEventType.keyUp.rawValue)
let callback: CGEventTapCallBack = { _, _, event, _ in
    if event.getIntegerValueField(.eventSourceUserData) == KeyboardInjector.syntheticEventMarker {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let command = event.flags.contains(.maskCommand)
        lock.lock()
        seen.append("\(code):\(event.type == .keyDown ? "down" : "up"):\(command ? "command" : "plain")")
        lock.unlock()
    }
    return Unmanaged.passUnretained(event)
}
guard AXIsProcessTrusted() else { fatalError("Accessibility permission is missing") }
guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
    eventsOfInterest: mask, callback: callback, userInfo: nil
), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
    fatalError("Could not create event tap")
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

guard KeyboardInjector.send(.deleteBackward),
      KeyboardInjector.send(.appSwitcher),
      KeyboardInjector.send(.returnKey)
else { fatalError("KeyboardInjector failed to post test keys") }

RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
CGEvent.tapEnable(tap: tap, enable: false)
print(seen.joined(separator: ","))
let expected = [
    "51:down:plain", "51:up:plain", "48:down:command", "48:up:plain",
    "36:down:plain", "36:up:plain",
]
exit(seen == expected ? 0 : 1)
