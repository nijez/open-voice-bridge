import Foundation

func runApplicationLauncherTests(_ check: (Bool, String) -> Void) {
    let target = ApplicationTarget(
        path: "/Applications/示例 App.app", bundleIdentifier: "test.example.app", name: "示例 App"
    )
    let binding = ButtonBinding.openApplication(target)
    let selected = URL(fileURLWithPath: target.path)
    let relocated = URL(fileURLWithPath: "/Applications/工具/示例 App.app")

    do {
        let encoded = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(ButtonBinding.self, from: encoded)
        check(
            decoded == binding && decoded.displayName == "打开 示例 App" && !decoded.isDisabled,
            "open application: target and action round-trip without losing Unicode or spaces"
        )
    } catch {
        check(false, "open application: target and action round-trip: \(error)")
    }

    let suite = "XiaomiRemoteBridgeMacSelfTest.application.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    for slot in ButtonGestureSlot.allCases {
        settings.setBinding(binding, for: .tv, slot: slot)
    }
    let reloaded = AppSettings(defaults: defaults)
    check(
        ButtonGestureSlot.allCases.allSatisfy { reloaded.binding(for: .tv, slot: $0) == binding } &&
            reloaded.binding(for: .back) == .preset(.deleteBackward),
        "open application: all three action slots persist while other bindings retain their defaults"
    )

    var lookupCount = 0
    let preferred = ApplicationLauncher.resolve(
        target,
        applicationAt: { $0 == selected ? target : nil },
        installedApplicationURL: { _ in lookupCount += 1; return relocated }
    )
    check(
        preferred == selected && lookupCount == 0,
        "open application: the selected installed copy takes priority over bundle-ID lookup"
    )

    let moved = ApplicationLauncher.resolve(
        target,
        applicationAt: { $0 == relocated ? target : nil },
        installedApplicationURL: { $0 == target.bundleIdentifier ? relocated : nil }
    )
    check(moved == relocated, "open application: bundle ID resolves an application after it moves")

    let replacement = ApplicationTarget(path: target.path, bundleIdentifier: "other.app", name: "Other")
    check(
        ApplicationLauncher.resolve(
            target, applicationAt: { _ in replacement }, installedApplicationURL: { _ in selected }
        ) == nil,
        "open application: a different app occupying the old path is never launched"
    )
    check(
        ApplicationLauncher.resolve(target, applicationAt: { _ in nil }, installedApplicationURL: { _ in nil }) == nil,
        "open application: a removed app yields no launch URL"
    )
    let invalid = ApplicationTarget(path: "relative.app", bundleIdentifier: nil, name: "Invalid")
    check(
        ApplicationLauncher.resolve(invalid, applicationAt: { _ in target }, installedApplicationURL: { _ in selected }) == nil &&
            ApplicationTarget.application(at: URL(fileURLWithPath: "/bin/sh")) == nil,
        "open application: targets must be absolute application bundles rather than arbitrary executables"
    )

    var launched: [ApplicationTarget] = []
    let sent = KeyboardInjector.send(binding, openApplication: { launched.append($0) })
    check(sent && launched == [target], "open application: tap delivery launches the selected target once")
    launched.removeAll()
    let held = KeyboardInjector.beginHold(binding, openApplication: { launched.append($0) })
    check(
        held.delivered && held.heldBinding == nil && launched == [target],
        "open application: hold delivery launches once with no repeat/release token or TCC dependency"
    )
}
