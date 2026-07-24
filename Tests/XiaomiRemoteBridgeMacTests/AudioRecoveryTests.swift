import Foundation
import Testing
@testable import XiaomiRemoteBridgeMac

@Suite("Audio recovery")
struct AudioRecoveryTests {
    @Test func recoveryReasonsChooseExpectedAction() {
        #expect(
            AudioRecoveryPolicy.action(for: .engineConfigurationChanged) ==
                .inspectBoundOutput
        )
        #expect(
            AudioRecoveryPolicy.action(for: .devicesChanged) ==
                .inspectBoundOutput
        )
        #expect(
            AudioRecoveryPolicy.action(for: .defaultOutputChanged) ==
                .restartBoundOutput
        )
        #expect(
            AudioRecoveryPolicy.action(for: .streamUnavailable) ==
                .restartBoundOutput
        )
    }

    @Test func repeatedRequestsRemainSingleFlight() throws {
        var state = AudioRecoveryState()
        let initialRequest = state.request(delay: 0.3)
        let initial = try #require(initialRequest)

        for _ in 0..<3 {
            let duplicate = state.request(delay: 0)
            #expect(duplicate == nil)
        }

        let beganInitial = state.begin(generation: initial.generation)
        #expect(beganInitial)
        let duplicateWhileRecovering = state.request(delay: 0)
        #expect(duplicateWhileRecovering == nil)
        let firstRetryRequest = state.retry()
        let firstRetry = try #require(firstRetryRequest)
        #expect(firstRetry.attempt == 1)
        #expect(firstRetry.delay == 0.25)

        for _ in 0..<3 {
            let duplicate = state.request(delay: 0)
            #expect(duplicate == nil)
        }

        let beganFirstRetry = state.begin(generation: firstRetry.generation)
        #expect(beganFirstRetry)
        let secondRetryRequest = state.retry()
        let secondRetry = try #require(secondRetryRequest)
        #expect(secondRetry.attempt == 2)
        #expect(secondRetry.delay == 0.5)
    }

    @Test func cancellationInvalidatesDelayedWork() throws {
        var state = AudioRecoveryState()
        let staleRequest = state.request(delay: 0.3)
        let stale = try #require(staleRequest)

        state.cancel()

        let currentRequest = state.request(delay: 0)
        let current = try #require(currentRequest)
        let beganStale = state.begin(generation: stale.generation)
        #expect(!beganStale)
        #expect(state.pendingGeneration == current.generation)
        #expect(current.generation > stale.generation)
        let beganCurrent = state.begin(generation: current.generation)
        #expect(beganCurrent)
    }

    @Test func urgentRequestExpeditesPendingRecovery() throws {
        var state = AudioRecoveryState()
        let delayedRequest = state.request(delay: 0.5)
        let delayed = try #require(delayedRequest)
        let urgentRequest = state.expedite(delay: 0)
        let urgent = try #require(urgentRequest)

        #expect(urgent.generation > delayed.generation)
        #expect(urgent.attempt == delayed.attempt)
        #expect(urgent.delay == 0)
        let beganDelayed = state.begin(generation: delayed.generation)
        #expect(!beganDelayed)
        #expect(state.pendingGeneration == urgent.generation)
        let beganUrgent = state.begin(generation: urgent.generation)
        #expect(beganUrgent)
    }

    @Test func retriesAreBounded() throws {
        var state = AudioRecoveryState()
        let initialRequest = state.request(delay: 0)
        let initial = try #require(initialRequest)
        let beganInitial = state.begin(generation: initial.generation)
        #expect(beganInitial)

        let expectedDelays: [TimeInterval] = [0.25, 0.5, 1.0]
        for (index, expectedDelay) in expectedDelays.enumerated() {
            let retryRequest = state.retry()
            let retry = try #require(retryRequest)
            #expect(retry.attempt == index + 1)
            #expect(retry.delay == expectedDelay)
            let beganRetry = state.begin(generation: retry.generation)
            #expect(beganRetry)
        }
        let exhaustedRetry = state.retry()
        #expect(exhaustedRetry == nil)
    }

    @Test func successfulRecoveryResetsBackoff() throws {
        var state = AudioRecoveryState()
        let initial = try #require(state.request(delay: 0))
        #expect(state.begin(generation: initial.generation))
        let firstRetry = try #require(state.retry())
        #expect(firstRetry.attempt == 1)
        #expect(state.begin(generation: firstRetry.generation))
        #expect(state.retryIndex == 1)
        state.succeeded()
        #expect(state.retryIndex == 0)
        let next = try #require(state.request(delay: 0))
        #expect(state.begin(generation: next.generation))
        let resetRetry = state.retry()
        #expect(resetRetry?.attempt == 1)
    }

    @Test func forcedRecoveryReasonIsNotDowngraded() {
        #expect(
            AudioRecoveryPolicy.merge(.defaultOutputChanged, with: .devicesChanged) ==
                .defaultOutputChanged
        )
        #expect(
            AudioRecoveryPolicy.merge(.streamUnavailable, with: .engineConfigurationChanged) ==
                .streamUnavailable
        )
        #expect(
            AudioRecoveryPolicy.merge(.devicesChanged, with: .defaultOutputChanged) ==
                .defaultOutputChanged
        )
    }
}
