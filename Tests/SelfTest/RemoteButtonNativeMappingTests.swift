import Foundation

private final class NativeMappingFixture {
    var mappings: [HIDUsageMapping] = [RemoteVoiceFunctionMappingPolicy.remoteVoiceKey]
    var data: Data?
    var present = true
    var enumerationWorks = true
    var ambiguous = false
    var saveWorks = true
    var writeWorks = true
    var verifyWorks = true
    var writeCount = 0
    var wroteWithBackup = false

    func mapper() -> RemoteButtonNativeMapper {
        RemoteButtonNativeMapper(
            services: { [self] in
                guard enumerationWorks else { return nil }
                guard present else { return [] }
                let service = RemoteButtonNativeMappingService(
                    registryID: 42, locationID: 7, mappings: mappings,
                    writeAndVerify: { [self] desired in
                        writeCount += 1
                        wroteWithBackup = data.flatMap {
                            try? JSONDecoder().decode([RemoteButtonNativeMappingRecord].self, from: $0)
                        }?.contains(where: { $0.registryID == 42 }) == true
                        guard writeWorks else { return false }
                        mappings = desired
                        return verifyWorks
                    }
                )
                return ambiguous ? [service, service] : [service]
            },
            store: RemoteButtonNativeMappingStore(
                load: { [self] in data },
                save: { [self] updated in
                    guard saveWorks else { return false }
                    data = updated
                    return true
                }
            ),
            log: { _ in }
        )
    }

    var savedRecords: [RemoteButtonNativeMappingRecord]? {
        data.flatMap { try? JSONDecoder().decode([RemoteButtonNativeMappingRecord].self, from: $0) }
    }
}

func runRemoteButtonNativeMappingTests(_ check: (Bool, String) -> Void) {
    let policy = RemoteButtonNativeMappingPolicy.mappings
    check(
        policy.count == RemoteButton.allCases.count - 1 &&
            policy.allSatisfy { $0.destination == 0 } &&
            !RemoteButtonNativeMappingPolicy.sources.contains(RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source),
        "native mapping: every ordinary button is suppressed without a gesture/physical-key whitelist"
    )

    do {
        let fixture = NativeMappingFixture()
        let unrelated = HIDUsageMapping(source: 0x700000004, destination: 0x700000005)
        let originalPower = HIDUsageMapping(source: 0x700000066, destination: 0x70000003A)
        fixture.mappings += [unrelated, originalPower]
        let mapper = fixture.mapper()
        let applied = mapper.apply(locationID: 7)
        check(
            applied && fixture.wroteWithBackup && fixture.mappings ==
                [RemoteVoiceFunctionMappingPolicy.remoteVoiceKey, unrelated] + policy,
            "native mapping: backup precedes write; F5 and unrelated mappings survive apply"
        )
        let changedFn = HIDUsageMapping(source: RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source, destination: 123)
        fixture.mappings = fixture.mappings.filter { $0.source != changedFn.source } + [changedFn]
        let restored = mapper.restore()
        check(
            restored && fixture.mappings == [unrelated, changedFn, originalPower] && fixture.savedRecords == [],
            "native mapping: restore reinstates original power mapping and preserves a concurrent F5 edit"
        )
    }

    do {
        let fixture = NativeMappingFixture()
        let originalNull = policy[0]
        fixture.mappings.append(originalNull)
        let mapper = fixture.mapper()
        _ = mapper.apply(locationID: 7)
        check(
            mapper.restore() && fixture.mappings.contains(originalNull),
            "native mapping: a pre-existing user-owned null mapping is restored rather than deleted"
        )
    }

    do {
        let fixture = NativeMappingFixture()
        let mapper = fixture.mapper()
        _ = mapper.apply(locationID: 7)
        let edited = HIDUsageMapping(source: policy[0].source, destination: 999)
        fixture.mappings = fixture.mappings.filter { $0.source != edited.source && $0.source != policy[1].source } + [edited]
        check(
            mapper.restore() && fixture.mappings == [RemoteVoiceFunctionMappingPolicy.remoteVoiceKey, edited],
            "native mapping: third-party replacements and removals win during restore"
        )
    }

    do {
        let fixture = NativeMappingFixture()
        let mapper = fixture.mapper()
        _ = mapper.apply(locationID: 7)
        let relaunched = fixture.mapper()
        check(
            relaunched.restore() && fixture.mappings == [RemoteVoiceFunctionMappingPolicy.remoteVoiceKey] && fixture.savedRecords == [],
            "native mapping: a new process recovers the persisted rollback ledger"
        )
        check(relaunched.apply(locationID: 7), "native mapping: relaunch can reapply after successful recovery")
        fixture.present = false
        check(
            relaunched.restore() && fixture.savedRecords == [],
            "native mapping: a removed service drops its obsolete ledger without touching another device"
        )
    }

    do {
        let fixture = NativeMappingFixture()
        let mapper = fixture.mapper()
        _ = mapper.apply(locationID: 7)
        fixture.writeWorks = false
        check(
            !mapper.restore() && fixture.savedRecords?.count == 1 && fixture.mappings.contains(policy[0]),
            "native mapping: failed restore retains both ownership and the rollback snapshot"
        )
        fixture.writeWorks = true
        check(
            mapper.restore() && fixture.mappings == [RemoteVoiceFunctionMappingPolicy.remoteVoiceKey],
            "native mapping: restore retries successfully after a property write failure"
        )
    }

    do {
        let fixture = NativeMappingFixture()
        fixture.saveWorks = false
        check(
            !fixture.mapper().apply(locationID: 7) && fixture.writeCount == 0,
            "native mapping: backup failure prevents any live mapping write"
        )
        fixture.saveWorks = true
        fixture.ambiguous = true
        check(
            !fixture.mapper().apply(locationID: 7) && fixture.writeCount == 0,
            "native mapping: ambiguous matching services are rejected before mutation"
        )
        fixture.ambiguous = false
        check(
            !fixture.mapper().apply(locationID: 8) && fixture.writeCount == 0,
            "native mapping: another device location is never modified"
        )
        fixture.present = false
        check(
            fixture.mapper().applyResult(locationID: 7) == .serviceNotReady && fixture.writeCount == 0,
            "native mapping: absence of an adopted service does not claim successful suppression"
        )
        fixture.present = true
        fixture.enumerationWorks = false
        check(
            fixture.mapper().applyResult(locationID: 7) == .serviceNotReady && fixture.writeCount == 0,
            "native mapping: a temporarily unavailable service enumeration is retryable"
        )
        fixture.enumerationWorks = true
        fixture.ambiguous = true
        check(
            fixture.mapper().applyResult(locationID: 7) == .failed && fixture.writeCount == 0,
            "native mapping: an ambiguous service remains a non-retryable safety failure"
        )
    }

    check(
        RemoteButtonNativeMappingRetryPolicy.delay(afterAttempt: 0) == 0.05 &&
            RemoteButtonNativeMappingRetryPolicy.delay(afterAttempt: 4) == 1.2 &&
            RemoteButtonNativeMappingRetryPolicy.delay(afterAttempt: 5) == nil,
        "native mapping: service-enumeration retries are bounded"
    )

    do {
        let fixture = NativeMappingFixture()
        fixture.verifyWorks = false
        let mapper = fixture.mapper()
        check(!mapper.apply(locationID: 7), "native mapping: failed read-back never reports success")
        fixture.verifyWorks = true
        check(
            mapper.restore() && fixture.mappings == [RemoteVoiceFunctionMappingPolicy.remoteVoiceKey],
            "native mapping: a partially applied property remains recoverable"
        )
    }

    do {
        let fixture = NativeMappingFixture()
        let mapper = fixture.mapper()
        _ = mapper.apply(locationID: 7)
        fixture.enumerationWorks = false
        check(
            !mapper.restore() && fixture.savedRecords?.count == 1,
            "native mapping: enumeration failure does not masquerade as device removal"
        )
        fixture.enumerationWorks = true
        check(mapper.restore(), "native mapping: recovery retries after enumeration resumes")
    }

    do {
        let fixture = NativeMappingFixture()
        fixture.data = Data("invalid ledger".utf8)
        let mapper = fixture.mapper()
        check(
            !mapper.restore() && !mapper.apply(locationID: 7) && fixture.writeCount == 0,
            "native mapping: invalid persistent ownership data fails closed"
        )
    }

    do {
        let fixture = NativeMappingFixture()
        let mapper = fixture.mapper()
        _ = mapper.apply(locationID: 7)
        fixture.saveWorks = false
        check(
            !mapper.restore() && fixture.savedRecords?.count == 1 &&
                fixture.mappings == [RemoteVoiceFunctionMappingPolicy.remoteVoiceKey],
            "native mapping: ledger-clear failure remains retryable after live restoration"
        )
        fixture.saveWorks = true
        check(mapper.restore() && fixture.savedRecords == [], "native mapping: a repeated restoration is idempotent")
    }
}
