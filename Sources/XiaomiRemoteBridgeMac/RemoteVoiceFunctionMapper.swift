import Foundation
import IOKit.hid
import IOKit.hidsystem

struct HIDUsageMapping: Equatable {
    static let sourceKey = "HIDKeyboardModifierMappingSrc"
    static let destinationKey = "HIDKeyboardModifierMappingDst"

    let source: UInt64
    let destination: UInt64

    init(source: UInt64, destination: UInt64) {
        self.source = source
        self.destination = destination
    }

    init?(property: [String: NSNumber]) {
        guard let source = property[Self.sourceKey],
              let destination = property[Self.destinationKey]
        else { return nil }
        self.source = source.uint64Value
        self.destination = destination.uint64Value
    }

    var property: [String: NSNumber] {
        [
            Self.sourceKey: NSNumber(value: source),
            Self.destinationKey: NSNumber(value: destination),
        ]
    }
}

enum VoiceMappingRestoreLedger {
    static func remainingSavedIDs(
        saved: Set<UInt64>,
        present: Set<UInt64>,
        restored: Set<UInt64>
    ) -> Set<UInt64> {
        // An absent service no longer carries a live per-device mapping, so its
        // snapshot can be discarded. A present service whose property write
        // failed MUST remain, otherwise a later retry loses the rollback value.
        saved.intersection(present).subtracting(restored)
    }
}

enum SavedVoiceMappingState: Equatable {
    /// No in-process rollback snapshot exists (for example after a relaunch).
    case unknown
    /// This process observed that F5 had no mapping before it installed F5→Fn.
    case absent
    /// This process observed an existing F5 mapping before it installed F5→Fn.
    case present(HIDUsageMapping)
}

enum CustomVoiceMappingCleanupPlan: Equatable {
    case safe
    case write([HIDUsageMapping])
    case rejectUnknown
}

enum CustomVoiceMappingCleanupPolicy {
    static func plan(
        current: [HIDUsageMapping],
        savedOriginal: SavedVoiceMappingState
    ) -> CustomVoiceMappingCleanupPlan {
        // A pre-existing F5 mapping owned by somebody else cannot safely coexist
        // with a custom microphone chord. Never guess its provenance or delete it.
        if case let .present(original) = savedOriginal,
           original != RemoteVoiceFunctionMappingPolicy.remoteVoiceKey {
            return .rejectUnknown
        }

        let voiceMappings = current.filter {
            $0.source == RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source
        }
        guard !voiceMappings.isEmpty else { return .safe }
        guard voiceMappings.count == 1,
              voiceMappings[0] == RemoteVoiceFunctionMappingPolicy.remoteVoiceKey
        else { return .rejectUnknown }

        // The only F5 mapping is the exact value this project writes. This is
        // safe to remove even when the process-local ledger was lost in a crash.
        return .write(
            RemoteVoiceFunctionMappingPolicy.restoring(
                originalVoiceMapping: nil,
                in: current
            )
        )
    }
}

enum CustomVoiceMappingCleanupCoordinator {
    /// Runs already-audited writes. Keeping this small seam pure lets tests prove
    /// that a property-write or read-back failure blocks custom injection.
    static func execute(
        plans: [CustomVoiceMappingCleanupPlan],
        writeAndVerify: (Int, [HIDUsageMapping]) -> Bool
    ) -> Bool {
        guard !plans.contains(.rejectUnknown) else { return false }
        for (index, plan) in plans.enumerated() {
            if case let .write(desired) = plan,
               !writeAndVerify(index, desired) {
                return false
            }
        }
        return true
    }
}

enum RemoteVoiceFunctionMappingPolicy {
    // RC003 exposes its microphone button as keyboard F5 (usage page 7,
    // usage 0x3e). macOS represents the laptop Fn/Globe key as the Apple
    // vendor top-case usage (usage page 0xff, usage 3).
    static let remoteVoiceKey = HIDUsageMapping(
        source: 0x0000_0007_0000_003E,
        destination: 0x0000_00FF_0000_0003
    )

    // The raw keyboard usage (0x3e) that the RC003 microphone button reports in
    // its HID input report — the low 16 bits of `remoteVoiceKey.source`. Reading
    // this edge directly from the RC003 device is the reliable "remote source"
    // pre-marker that gates the local microphone, independent of the ATVV BLE
    // timing and independent of `customMappingEnabled`.
    static let remoteVoiceKeyUsage: UInt16 = 0x003E

    static func applying(to existing: [HIDUsageMapping]) -> [HIDUsageMapping] {
        existing.filter { $0.source != remoteVoiceKey.source } + [remoteVoiceKey]
    }

    static func restoring(
        originalVoiceMapping: HIDUsageMapping?,
        in current: [HIDUsageMapping]
    ) -> [HIDUsageMapping] {
        let withoutVoiceKey = current.filter { $0.source != remoteVoiceKey.source }
        guard let originalVoiceMapping else { return withoutVoiceKey }
        return withoutVoiceKey + [originalVoiceMapping]
    }
}

final class RemoteVoiceFunctionMapper {
    private static let mappingProperty = "UserKeyMapping" as CFString

    private struct OriginalVoiceMapping {
        let mapping: HIDUsageMapping?
    }

    private var originalMappings: [UInt64: OriginalVoiceMapping] = [:]
    private(set) var isApplied = false

    @discardableResult
    func apply() -> Bool {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        var matchedCount = 0
        var appliedCount = 0

        for service in services where Self.isTarget(service) {
            matchedCount += 1
            guard let registryID = Self.registryID(service) else { continue }
            let current = Self.readMappings(service)
            if originalMappings[registryID] == nil {
                originalMappings[registryID] = OriginalVoiceMapping(
                    mapping: current.first {
                        $0.source == RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source
                    }
                )
            }
            let desired = RemoteVoiceFunctionMappingPolicy.applying(to: current)
            if IOHIDServiceClientSetProperty(
                service,
                Self.mappingProperty,
                desired.map(\.property) as CFArray
            ) {
                appliedCount += 1
            }
        }

        isApplied = appliedCount > 0
        AppLogger.shared.write(
            "VOICE FN MAPPING applied=\(isApplied) matched=\(matchedCount)"
        )
        return isApplied
    }

    /// Proves that no target service can still translate the remote F5 key while
    /// the HID layer injects a user-defined microphone chord. This deliberately
    /// audits live IOHID service state even when the in-memory rollback ledger is
    /// empty, covering relaunch after a crash or force-quit.
    @discardableResult
    func prepareForCustom(requirePresentTarget: Bool = false) -> Bool {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? [])
            .filter(Self.isTarget)
        guard !requirePresentTarget || !services.isEmpty else {
            AppLogger.shared.write("VOICE CUSTOM AUDIT rejected no_target")
            return false
        }

        struct PendingWrite {
            let service: IOHIDServiceClient
            let registryID: UInt64
            let desired: [HIDUsageMapping]
        }
        var plans: [CustomVoiceMappingCleanupPlan] = []
        var pendingByPlanIndex: [Int: PendingWrite] = [:]

        for service in services {
            guard let registryID = Self.registryID(service) else {
                AppLogger.shared.write("VOICE CUSTOM AUDIT rejected missing_registry_id")
                return false
            }
            let savedState: SavedVoiceMappingState
            if let original = originalMappings[registryID] {
                savedState = original.mapping.map(SavedVoiceMappingState.present) ?? .absent
            } else {
                savedState = .unknown
            }
            let plan = CustomVoiceMappingCleanupPolicy.plan(
                current: Self.readMappings(service),
                savedOriginal: savedState
            )
            plans.append(plan)
            if case let .write(desired) = plan {
                pendingByPlanIndex[plans.count - 1] = PendingWrite(
                    service: service,
                    registryID: registryID,
                    desired: desired
                )
            }
        }

        // Reject the whole transition before the first write when any service has
        // an unknown F5 owner. For write failures the caller re-applies hardware
        // mode across every target, repairing any earlier successful cleanup.
        guard !plans.contains(.rejectUnknown) else {
            AppLogger.shared.write("VOICE CUSTOM AUDIT rejected unknown_f5_mapping")
            return false
        }
        let succeeded = CustomVoiceMappingCleanupCoordinator.execute(
            plans: plans
        ) { index, desired in
            guard let pending = pendingByPlanIndex[index], pending.desired == desired else {
                return false
            }
            guard IOHIDServiceClientSetProperty(
                pending.service,
                Self.mappingProperty,
                desired.map(\.property) as CFArray
            ) else { return false }
            let verified = Self.readMappings(pending.service)
            return !verified.contains {
                $0.source == RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source
            }
        }
        guard succeeded else {
            AppLogger.shared.write("VOICE CUSTOM AUDIT rejected cleanup_or_verify_failed")
            return false
        }
        for write in pendingByPlanIndex.values {
            originalMappings.removeValue(forKey: write.registryID)
        }
        isApplied = false
        AppLogger.shared.write("VOICE CUSTOM AUDIT safe targets=\(services.count)")
        return true
    }

    /// Restores the original F5 system mapping for every present target service.
    /// Returns `true` when the restore is clean — either there was nothing applied,
    /// or every present target service that had a saved original was restored
    /// successfully. Returns `false` when a present target service could not be
    /// restored (its F5 may still be remapped to Fn), so the caller can stay in a
    /// failed-disabled state and surface an understandable error.
    @discardableResult
    func restore() -> Bool {
        guard !originalMappings.isEmpty else {
            isApplied = false
            return true
        }

        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        var attemptedCount = 0
        var restoredCount = 0
        var presentIDs = Set<UInt64>()
        var restoredIDs = Set<UInt64>()

        for service in services where Self.isTarget(service) {
            guard let registryID = Self.registryID(service) else { continue }
            presentIDs.insert(registryID)
            guard let original = originalMappings[registryID] else { continue }
            attemptedCount += 1
            let restored = RemoteVoiceFunctionMappingPolicy.restoring(
                originalVoiceMapping: original.mapping,
                in: Self.readMappings(service)
            )
            if IOHIDServiceClientSetProperty(
                service,
                Self.mappingProperty,
                restored.map(\.property) as CFArray
            ) {
                restoredCount += 1
                restoredIDs.insert(registryID)
            }
        }

        let remainingIDs = VoiceMappingRestoreLedger.remainingSavedIDs(
            saved: Set(originalMappings.keys),
            present: presentIDs,
            restored: restoredIDs
        )
        originalMappings = originalMappings.filter { remainingIDs.contains($0.key) }
        isApplied = !originalMappings.isEmpty
        AppLogger.shared.write("VOICE FN MAPPING restored=\(restoredCount)")
        // Clean when no present target service failed to restore. A device that is
        // absent (attempted == 0) is also clean: its service — and any mapping on
        // it — is gone until it reconnects, at which point apply/restore run afresh.
        return restoredCount == attemptedCount
    }

    private static func isTarget(_ service: IOHIDServiceClient) -> Bool {
        guard let hidIdentity = VoiceBridgeDeviceProfiles.xiaomiRC003.hidIdentity else {
            return false
        }
        let vendor = IOHIDServiceClientCopyProperty(
            service,
            kIOHIDVendorIDKey as CFString
        ) as? NSNumber
        let product = IOHIDServiceClientCopyProperty(
            service,
            kIOHIDProductIDKey as CFString
        ) as? NSNumber
        return vendor?.intValue == hidIdentity.vendorID &&
            product?.intValue == hidIdentity.productID
    }

    private static func registryID(_ service: IOHIDServiceClient) -> UInt64? {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value
    }

    private static func readMappings(_ service: IOHIDServiceClient) -> [HIDUsageMapping] {
        let properties = IOHIDServiceClientCopyProperty(
            service,
            mappingProperty
        ) as? [[String: NSNumber]] ?? []
        return properties.compactMap(HIDUsageMapping.init(property:))
    }
}
