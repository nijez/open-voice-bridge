import Testing
@testable import XiaomiRemoteBridgeMac

@Suite("RC003 hardware Fn mapping")
struct RemoteVoiceFunctionMapperTests {
    @Test func replacesOnlyTheRemoteF5Mapping() {
        let unrelated = HIDUsageMapping(
            source: 0x0000_0007_0000_0004,
            destination: 0x0000_0007_0000_0005
        )
        let stale = HIDUsageMapping(
            source: RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source,
            destination: 0x0000_0007_0000_00E1
        )

        #expect(
            RemoteVoiceFunctionMappingPolicy.applying(to: [unrelated, stale]) == [
                unrelated,
                RemoteVoiceFunctionMappingPolicy.remoteVoiceKey,
            ]
        )
    }

    @Test func isIdempotentAndRoundTripsItsProperty() {
        let mapping = RemoteVoiceFunctionMappingPolicy.remoteVoiceKey
        #expect(RemoteVoiceFunctionMappingPolicy.applying(to: [mapping]) == [mapping])
        #expect(HIDUsageMapping(property: mapping.property) == mapping)
    }

    @Test func restorePreservesUnrelatedChangesMadeWhileRunning() {
        let originalVoice = HIDUsageMapping(
            source: RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source,
            destination: 0x0000_0007_0000_00E1
        )
        let changedUnrelated = HIDUsageMapping(
            source: 0x0000_0007_0000_0004,
            destination: 0x0000_0007_0000_0006
        )

        #expect(
            RemoteVoiceFunctionMappingPolicy.restoring(
                originalVoiceMapping: originalVoice,
                in: [changedUnrelated, RemoteVoiceFunctionMappingPolicy.remoteVoiceKey]
            ) == [changedUnrelated, originalVoice]
        )
        #expect(
            RemoteVoiceFunctionMappingPolicy.restoring(
                originalVoiceMapping: nil,
                in: [changedUnrelated, RemoteVoiceFunctionMappingPolicy.remoteVoiceKey]
            ) == [changedUnrelated]
        )
    }

    @Test func failedPresentRestoreKeepsRollbackSnapshotForRetry() {
        #expect(
            VoiceMappingRestoreLedger.remainingSavedIDs(
                saved: [1, 2, 3],
                present: [1, 2],
                restored: [1]
            ) == [2]
        )
        #expect(
            VoiceMappingRestoreLedger.remainingSavedIDs(
                saved: [1],
                present: [],
                restored: []
            ).isEmpty
        )
    }

    @Test func customCleanupRemovesOnlyKnownProjectMappingWithoutLedger() {
        let unrelated = HIDUsageMapping(
            source: 0x0000_0007_0000_0004,
            destination: 0x0000_0007_0000_0005
        )
        #expect(
            CustomVoiceMappingCleanupPolicy.plan(
                current: [unrelated, RemoteVoiceFunctionMappingPolicy.remoteVoiceKey],
                savedOriginal: .unknown
            ) == .write([unrelated])
        )
        #expect(
            CustomVoiceMappingCleanupPolicy.plan(
                current: [unrelated],
                savedOriginal: .unknown
            ) == .safe
        )
    }

    @Test func customCleanupRejectsUnknownOrPreexistingF5Owner() {
        let unknownF5 = HIDUsageMapping(
            source: RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source,
            destination: 0x0000_0007_0000_00E1
        )
        #expect(
            CustomVoiceMappingCleanupPolicy.plan(
                current: [unknownF5],
                savedOriginal: .unknown
            ) == .rejectUnknown
        )
        #expect(
            CustomVoiceMappingCleanupPolicy.plan(
                current: [RemoteVoiceFunctionMappingPolicy.remoteVoiceKey],
                savedOriginal: .present(unknownF5)
            ) == .rejectUnknown
        )
    }

    @Test func customCleanupFailsClosedOnWriteOrReadBackFailure() {
        let plans: [CustomVoiceMappingCleanupPlan] = [.safe, .write([])]
        var attemptedIndexes: [Int] = []
        #expect(
            !CustomVoiceMappingCleanupCoordinator.execute(plans: plans) { index, _ in
                attemptedIndexes.append(index)
                return false
            }
        )
        #expect(attemptedIndexes == [1])

        var called = false
        #expect(
            !CustomVoiceMappingCleanupCoordinator.execute(
                plans: [.write([]), .rejectUnknown]
            ) { _, _ in
                called = true
                return true
            }
        )
        #expect(!called)
    }
}
