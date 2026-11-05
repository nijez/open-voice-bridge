import Foundation

func runGestureReviewRegressionTests(_ check: (Bool, String) -> Void) {
    func boundarySequence(
        double: Bool, long: Bool, secondDown: UInt64, timerFirst: Bool
    ) -> [MultiActionGestureOutput] {
        var gesture = MultiActionButtonGesture(configuration: MultiActionGestureConfiguration(
            hasDoublePress: double, hasLongPress: long,
            doubleClickMs: 350, longPressMs: 500
        ))
        var outputs = gesture.handle(.down, nowMs: 0)
        outputs += gesture.handle(.up, nowMs: 80)
        if timerFirst { outputs += gesture.handleDeadline(nowMs: secondDown) }
        outputs += gesture.handle(.down, nowMs: secondDown)
        if !timerFirst { outputs += gesture.handleDeadline(nowMs: secondDown) }
        outputs += gesture.handle(.up, nowMs: secondDown + 50)
        outputs += gesture.handleDeadline(nowMs: secondDown + 1_000)
        return outputs
    }

    for (double, long) in [(true, false), (true, true), (false, true)] {
        let deadline: UInt64 = double ? 350 : 430
        let before = boundarySequence(double: double, long: long, secondDown: deadline - 1, timerFirst: false)
        let atInputFirst = boundarySequence(double: double, long: long, secondDown: deadline, timerFirst: false)
        let atTimerFirst = boundarySequence(double: double, long: long, secondDown: deadline, timerFirst: true)
        let after = boundarySequence(double: double, long: long, secondDown: deadline + 1, timerFirst: false)
        let separateSingles: [MultiActionGestureOutput] = [.performSingle(count: 1), .performSingle(count: 1)]
        check(
            atInputFirst == separateSingles && atTimerFirst == atInputFirst,
            "gesture boundary: deadline starts a new sequence in either callback order (double=\(double), long=\(long))"
        )
        check(
            before == (double ? [.performDouble] : [.performSingle(count: 1), .beginSingleHold(precedingTapCount: 0), .endHold]),
            "gesture boundary: the last millisecond inside the window retains double/quick-tap behavior (double=\(double), long=\(long))"
        )
        check(
            after == separateSingles,
            "gesture boundary: input after the window produces separate singles (double=\(double), long=\(long))"
        )
    }

    for (inputGranted, accessibilityGranted) in [(false, true), (true, false), (false, false)] {
        var delivered: [MultiActionGestureOutput] = []
        let newActions: [MultiActionGestureOutput] = [
            .performSingle(count: 1), .performDouble,
            .beginSingleHold(precedingTapCount: 1), .beginLongHold,
        ]
        let allBlocked = newActions.allSatisfy { output in
            !HIDPermissionGate.deliverGestureOutputs(
                [output],
                permissionsAreValid: {
                    HIDPermissionGate.canMonitor(
                        mappingEnabled: true, inputMonitoringGranted: inputGranted,
                        accessibilityGranted: accessibilityGranted
                    )
                },
                perform: { delivered.append($0); return true }
            )
        }
        check(
            allBlocked && delivered.isEmpty,
            "gesture permissions: either revoked grant blocks every new tap/hold (input=\(inputGranted), accessibility=\(accessibilityGranted))"
        )
    }

    var permissionChecks = 0
    var cleanup: [MultiActionGestureOutput] = []
    let released = HIDPermissionGate.deliverGestureOutputs(
        [.endHold], permissionsAreValid: { permissionChecks += 1; return false },
        perform: { cleanup.append($0); return true }
    )
    check(
        released && cleanup == [.endHold] && permissionChecks == 0,
        "gesture permissions: permission loss never skips a best-effort held-key release"
    )
    let releaseFailed = HIDPermissionGate.deliverGestureOutputs(
        [.endHold], permissionsAreValid: { false }, perform: { _ in false }
    )
    check(!releaseFailed, "gesture permissions: a failed release still reaches the owner's failure handling")

    let noOutput = HIDPermissionGate.deliverGestureOutputs(
        [], permissionsAreValid: { permissionChecks += 1; return false },
        perform: { _ in check(false, "empty gesture output must never be delivered"); return false }
    )
    check(noOutput && permissionChecks == 0, "gesture permissions: an empty decision does not query permissions or deliver actions")

    // Exercise real timer-driven coordinator output through the production gate.
    // The action sink is in-memory; no actual app, keyboard event, or TCC change.
    for long in [false, true] {
        let clock = FakeMultiActionRuntimeScheduler()
        var permitted = true
        var delivered: [MultiActionGestureOutput] = []
        var failures = 0
        let usage = RemoteButton.tv.hidUsage
        let target = ButtonBinding.openApplication(ApplicationTarget(
            path: "/Applications/Example.app", bundleIdentifier: "test.example", name: "Example"
        ))
        let binding = MultiActionButtonBinding(single: target, doublePress: long ? nil : target, longPress: long ? target : nil)
        let configuration = MultiActionGestureConfiguration(
            hasDoublePress: !long, hasLongPress: long, doubleClickMs: 350, longPressMs: 500
        )
        let coordinator = MultiActionRuntimeCoordinator(
            scheduler: clock.scheduler, isUsageActive: { _ in long },
            deliverOutputs: { _, outputs in
                HIDPermissionGate.deliverGestureOutputs(
                    outputs, permissionsAreValid: { permitted },
                    perform: { delivered.append($0); return true }
                )
            },
            deliveryDidFail: { failures += 1 }
        )
        _ = coordinator.handle(.down, usage: usage, button: .tv, binding: binding, configuration: configuration)
        if !long {
            clock.advance(to: 80)
            _ = coordinator.handle(.up, usage: usage, button: .tv, binding: binding, configuration: configuration)
        }
        clock.advance(to: 100)
        permitted = false
        clock.advance(to: long ? 500 : 350)
        _ = coordinator.reset()
        clock.advance(to: 2_000)
        check(
            delivered.isEmpty && failures == 1 && !coordinator.hasRuntime(for: usage),
            "gesture permissions: revoke before \(long ? "long hold" : "pending single") deadline blocks app launch and reports cleanup once"
        )
    }

    var stillPermitted = true
    var balanced: [MultiActionGestureOutput] = []
    let balancedHold = HIDPermissionGate.deliverGestureOutputs(
        [.beginLongHold, .endHold], permissionsAreValid: { stillPermitted },
        perform: { output in
            balanced.append(output)
            stillPermitted = false
            return true
        }
    )
    check(
        balancedHold && balanced == [.beginLongHold, .endHold],
        "gesture permissions: a grant lost after begin-hold still allows its balancing end-hold"
    )
}
