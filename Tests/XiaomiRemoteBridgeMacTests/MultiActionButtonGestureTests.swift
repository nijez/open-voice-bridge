import Testing
@testable import XiaomiRemoteBridgeMac

@Suite("Multi-action button gesture")
struct MultiActionButtonGestureTests {
    private func configuration(double: Bool, long: Bool) -> MultiActionGestureConfiguration {
        MultiActionGestureConfiguration(
            hasDoublePress: double,
            hasLongPress: long,
            doubleClickMs: 350,
            longPressMs: 500
        )
    }

    @Test func singleWaitsForDoubleWindowAndFiresOnDeadline() {
        var gesture = MultiActionButtonGesture(configuration: configuration(double: true, long: false))
        #expect(gesture.handle(.down, nowMs: 1_000).isEmpty)
        #expect(gesture.handle(.up, nowMs: 1_080).isEmpty)
        #expect(gesture.nextDeadlineMs == 1_350)
        #expect(gesture.handleDeadline(nowMs: 1_349).isEmpty)
        #expect(gesture.handleDeadline(nowMs: 1_350) == [.performSingle(count: 1)])
        #expect(gesture.isFinished)
    }

    @Test func secondShortTapPerformsOnlyDouble() {
        var gesture = MultiActionButtonGesture(configuration: configuration(double: true, long: false))
        _ = gesture.handle(.down, nowMs: 0)
        _ = gesture.handle(.up, nowMs: 80)
        #expect(gesture.handle(.down, nowMs: 200).isEmpty)
        #expect(gesture.handle(.up, nowMs: 270) == [.performDouble])
        #expect(gesture.isFinished)
    }

    @Test func longPressBeginsAHoldAndReleaseBalancesIt() {
        var gesture = MultiActionButtonGesture(configuration: configuration(double: false, long: true))
        _ = gesture.handle(.down, nowMs: 100)
        #expect(gesture.nextDeadlineMs == 600)
        #expect(gesture.handleDeadline(nowMs: 600) == [.beginLongHold])
        #expect(gesture.isHoldingOutput)
        #expect(gesture.handleDeadline(nowMs: 900).isEmpty)
        #expect(gesture.handle(.up, nowMs: 950) == [.endHold])
        #expect(gesture.isFinished)
    }

    @Test func shortTapThenHoldRestoresSingleHoldWhenLongExists() {
        var gesture = MultiActionButtonGesture(configuration: configuration(double: false, long: true))
        _ = gesture.handle(.down, nowMs: 0)
        #expect(gesture.handle(.up, nowMs: 80) == [.performSingle(count: 1)])
        #expect(gesture.handle(.down, nowMs: 200) == [.beginSingleHold(precedingTapCount: 0)])
        #expect(gesture.handle(.up, nowMs: 900) == [.endHold])
    }

    @Test func doubleAndLongSecondHoldBecomesTapThenSingleHold() {
        var gesture = MultiActionButtonGesture(configuration: configuration(double: true, long: true))
        _ = gesture.handle(.down, nowMs: 0)
        _ = gesture.handle(.up, nowMs: 80)
        _ = gesture.handle(.down, nowMs: 200)
        #expect(gesture.nextDeadlineMs == 700)
        #expect(gesture.handleDeadline(nowMs: 700) == [.beginSingleHold(precedingTapCount: 1)])
        #expect(gesture.handle(.up, nowMs: 900) == [.endHold])
    }

    @Test func heldKeyWithOnlyDoubleFallsBackToSingleHold() {
        var gesture = MultiActionButtonGesture(configuration: configuration(double: true, long: false))
        _ = gesture.handle(.down, nowMs: 1_000)
        #expect(gesture.handleDeadline(nowMs: 1_350) == [.beginSingleHold(precedingTapCount: 0)])
        #expect(gesture.handle(.up, nowMs: 1_800) == [.endHold])
    }

    @Test func anotherButtonInterruptsPendingSingleInOrder() {
        var gesture = MultiActionButtonGesture(configuration: configuration(double: true, long: true))
        _ = gesture.handle(.down, nowMs: 0)
        _ = gesture.handle(.up, nowMs: 60)
        #expect(gesture.interrupt() == [.performSingle(count: 1)])
        #expect(gesture.isFinished)
    }

    @Test func resetBalancesActiveSingleHold() {
        var gesture = MultiActionButtonGesture(configuration: configuration(double: false, long: true))
        _ = gesture.handle(.down, nowMs: 0)
        _ = gesture.handle(.up, nowMs: 50)
        _ = gesture.handle(.down, nowMs: 100)
        #expect(gesture.reset() == [.endHold])
        #expect(gesture.isFinished)
    }

    @Test func lateReleaseStillProducesBalancedLongHoldEdges() {
        var gesture = MultiActionButtonGesture(configuration: configuration(double: false, long: true))
        _ = gesture.handle(.down, nowMs: 0)
        #expect(gesture.handle(.up, nowMs: 700) == [.beginLongHold, .endHold])
        #expect(gesture.isFinished)
    }

    @Test func timingNormalizesRangesAndMaintainsGap() {
        let low = MultiActionTiming.normalized(doubleClickMs: 20, longPressMs: 30)
        #expect(low.doubleClickMs == 200)
        #expect(low.longPressMs == 300)

        let conflict = MultiActionTiming.normalized(doubleClickMs: 600, longPressMs: 400)
        #expect(conflict.doubleClickMs == 600)
        #expect(conflict.longPressMs == 650)

        let high = MultiActionTiming.normalized(doubleClickMs: 900, longPressMs: 9_000)
        #expect(high.doubleClickMs == 600)
        #expect(high.longPressMs == 1_500)
    }

    @Test func configuredDoubleClickIntervalChangesTheDecisionBoundary() {
        let configuration = MultiActionGestureConfiguration(
            hasDoublePress: true,
            hasLongPress: false,
            doubleClickMs: 220,
            longPressMs: 900
        )

        var single = MultiActionButtonGesture(configuration: configuration)
        _ = single.handle(.down, nowMs: 1_000)
        _ = single.handle(.up, nowMs: 1_080)
        #expect(single.nextDeadlineMs == 1_220)
        #expect(single.handleDeadline(nowMs: 1_219).isEmpty)
        #expect(single.handleDeadline(nowMs: 1_220) == [.performSingle(count: 1)])

        var tooLateForDouble = MultiActionButtonGesture(configuration: configuration)
        _ = tooLateForDouble.handle(.down, nowMs: 1_000)
        _ = tooLateForDouble.handle(.up, nowMs: 1_080)
        #expect(tooLateForDouble.handle(.down, nowMs: 1_221) == [.performSingle(count: 1)])
    }

    @Test func configuredLongPressDurationChangesTheHoldThreshold() {
        let configuration = MultiActionGestureConfiguration(
            hasDoublePress: false,
            hasLongPress: true,
            doubleClickMs: 350,
            longPressMs: 900
        )
        var gesture = MultiActionButtonGesture(configuration: configuration)

        _ = gesture.handle(.down, nowMs: 100)
        #expect(gesture.nextDeadlineMs == 1_000)
        #expect(gesture.handleDeadline(nowMs: 999).isEmpty)
        #expect(gesture.handleDeadline(nowMs: 1_000) == [.beginLongHold])
    }
}
