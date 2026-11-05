import Foundation
import IOKit.hid
import IOKit.hidsystem

/// Device-local suppression precedes macOS power/media hotkeys. Destination 0
/// makes IOHIDKeyboardFilter discard the event; raw device reports still arrive.
/// Voice keeps its existing F5/Fn mapping and reader lifecycle.
enum RemoteButtonNativeMappingPolicy {
    static let mappings = RemoteButton.allCases.filter { $0 != .microphone }.map {
        HIDUsageMapping(source: (UInt64(7) << 32) | UInt64($0.hidUsage), destination: 0)
    }
    static let sources = Set(mappings.map(\.source))

    static func applying(to current: [HIDUsageMapping]) -> [HIDUsageMapping] {
        current.filter { !sources.contains($0.source) } + mappings
    }

    static func restoring(
        originals: [HIDUsageMapping],
        in current: [HIDUsageMapping],
        includesHardwareVoiceMapping: Bool = false
    ) -> [HIDUsageMapping] {
        // Restore only mappings that still equal our value. A later third-party
        // edit/removal wins; F5 is included only when this record explicitly
        // installed the hardware-voice mapping as part of the combined write.
        let ownedMappings = mappings + (includesHardwareVoiceMapping
            ? [RemoteVoiceFunctionMappingPolicy.remoteVoiceKey]
            : [])
        let ownedSources = Set(ownedMappings.filter { mapping in
            current.filter { $0.source == mapping.source } == [mapping]
        }.map(\.source))
        return current.filter { !ownedSources.contains($0.source) } +
            originals.filter { ownedSources.contains($0.source) }
    }
}

struct RemoteButtonNativeMappingRecord: Codable, Equatable {
    let registryID: UInt64
    let originals: [HIDUsageMapping]
    let includesHardwareVoiceMapping: Bool

    init(
        registryID: UInt64,
        originals: [HIDUsageMapping],
        includesHardwareVoiceMapping: Bool = false
    ) {
        self.registryID = registryID
        self.originals = originals
        self.includesHardwareVoiceMapping = includesHardwareVoiceMapping
    }

    private enum CodingKeys: String, CodingKey {
        case registryID
        case originals
        case includesHardwareVoiceMapping
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        registryID = try container.decode(UInt64.self, forKey: .registryID)
        originals = try container.decode([HIDUsageMapping].self, forKey: .originals)
        includesHardwareVoiceMapping = try container.decodeIfPresent(
            Bool.self,
            forKey: .includesHardwareVoiceMapping
        ) ?? false
    }
}

/// A fresh service snapshot. Its writer verifies read-back while retaining the
/// IOHID service's owning client. Tests replace this seam without touching HID.
struct RemoteButtonNativeMappingService {
    let registryID: UInt64
    let locationID: UInt64
    let mappings: [HIDUsageMapping]
    let writeAndVerify: ([HIDUsageMapping]) -> RemoteNativeMappingWriteResult
}

enum RemoteNativeMappingWriteResult: Equatable {
    case verified
    case setRejected
    case readbackUnavailable
    case readbackMismatch

    var logValue: String {
        switch self {
        case .verified: return "verified"
        case .setRejected: return "set_rejected"
        case .readbackUnavailable: return "readback_unavailable"
        case .readbackMismatch: return "readback_mismatch"
        }
    }
}

/// Shared ownership ledger for the two policies that compose UserKeyMapping.
/// It prevents the voice policy from mistaking an F5→Fn value just installed by
/// the ordinary-button policy for a pre-existing user mapping.
final class RemoteNativeMappingOwnership {
    private var combinedVoiceRegistryIDs = Set<UInt64>()

    func ownsCombinedVoiceMapping(registryID: UInt64) -> Bool {
        combinedVoiceRegistryIDs.contains(registryID)
    }

    func setCombinedVoiceMappingOwned(_ owned: Bool, registryID: UInt64) {
        if owned {
            combinedVoiceRegistryIDs.insert(registryID)
        } else {
            combinedVoiceRegistryIDs.remove(registryID)
        }
    }
}

struct RemoteButtonNativeMappingStore {
    let load: () -> Data?
    let save: (Data) -> Bool

    static func preferences(_ defaults: UserDefaults = .standard) -> Self {
        let key = "remoteButtonNativeMappingLedgerV1"
        return Self(
            load: { defaults.data(forKey: key) },
            save: { data in
                defaults.set(data, forKey: key)
                return defaults.synchronize() && defaults.data(forKey: key) == data
            }
        )
    }
}

enum RemoteButtonNativeMappingApplyResult: Equatable {
    case applied
    case serviceNotReady
    case failed
}

enum RemoteButtonNativeMappingRetryPolicy {
    /// The IOHID device-match callback can precede publication of the matching
    /// AppleUserHIDEventService, and a published service can reject writes briefly.
    /// Back off to a bounded cadence while the device generation remains active;
    /// structural safety failures still fail closed immediately.
    private static let initialDelays: [TimeInterval] = [0.05, 0.15, 0.35, 0.75, 1.2]
    private static let steadyDelay: TimeInterval = 2

    static func delay(afterAttempt attempt: Int) -> TimeInterval {
        guard initialDelays.indices.contains(attempt) else { return steadyDelay }
        return initialDelays[attempt]
    }
}

/// Main-thread lifecycle owner for the adopted RC003's ordinary-key mappings.
/// Persist rollback data BEFORE writing so relaunch can recover after a crash.
/// The registry ID restricts rollback to the original service; a disconnected
/// service loses its device-local property and its ledger entry can be dropped.
final class RemoteButtonNativeMapper {
    private let services: () -> [RemoteButtonNativeMappingService]?
    private let store: RemoteButtonNativeMappingStore
    private let ownership: RemoteNativeMappingOwnership
    private let log: (String) -> Void
    private var records: [RemoteButtonNativeMappingRecord]?
    /// A property set was accepted but its read-back was not yet authoritative.
    /// Restoration must force-write the backup even if a stale snapshot still
    /// looks original, otherwise the delayed set could land after ledger clear.
    private var pendingAcceptedWriteRegistryIDs = Set<UInt64>()

    init(
        services: @escaping () -> [RemoteButtonNativeMappingService]? = RemoteButtonNativeMapper.liveServices(),
        store: RemoteButtonNativeMappingStore = .preferences(),
        ownership: RemoteNativeMappingOwnership = RemoteNativeMappingOwnership(),
        log: @escaping (String) -> Void = { AppLogger.shared.write($0) }
    ) {
        self.services = services
        self.store = store
        self.ownership = ownership
        self.log = log
        if let data = store.load() {
            records = try? JSONDecoder().decode([RemoteButtonNativeMappingRecord].self, from: data)
            let allowedSources = RemoteButtonNativeMappingPolicy.sources.union([
                RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source,
            ])
            if let decoded = records,
               Set(decoded.map(\.registryID)).count != decoded.count ||
                decoded.contains(where: { record in
                    record.originals.contains { !allowedSources.contains($0.source) }
                }) {
                records = nil
            }
        } else {
            records = []
        }
        records?.forEach {
            ownership.setCombinedVoiceMappingOwned(
                $0.includesHardwareVoiceMapping,
                registryID: $0.registryID
            )
        }
    }

    @discardableResult
    func apply(locationID: UInt64) -> Bool {
        applyResult(locationID: locationID) == .applied
    }

    func applyResult(
        locationID: UInt64,
        includeHardwareVoiceMapping: Bool = false
    ) -> RemoteButtonNativeMappingApplyResult {
        guard let records else {
            log("HID NATIVE MAPPING apply_failed invalid_ledger")
            return .failed
        }
        guard let present = services() else {
            log("HID NATIVE MAPPING service_not_ready enumeration")
            return .serviceNotReady
        }
        let targets = present.filter { $0.locationID == locationID }
        guard !targets.isEmpty else {
            log("HID NATIVE MAPPING service_not_ready location=\(locationID) present=\(present.count)")
            return .serviceNotReady
        }
        guard targets.count == 1, let service = targets.first else {
            log("HID NATIVE MAPPING apply_failed ambiguous=\(targets.count) location=\(locationID)")
            return .failed
        }
        if records.isEmpty {
            let managedSources = RemoteButtonNativeMappingPolicy.sources.union(
                includeHardwareVoiceMapping
                    ? [RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source]
                    : []
            )
            let saved = RemoteButtonNativeMappingRecord(
                registryID: service.registryID,
                originals: service.mappings.filter { managedSources.contains($0.source) },
                includesHardwareVoiceMapping: includeHardwareVoiceMapping
            )
            guard save([saved]) else {
                log("HID NATIVE MAPPING apply_failed backup")
                return .failed
            }
            ownership.setCombinedVoiceMappingOwned(
                includeHardwareVoiceMapping,
                registryID: service.registryID
            )
        } else if records.count != 1 ||
            records[0].registryID != service.registryID ||
            records[0].includesHardwareVoiceMapping != includeHardwareVoiceMapping {
            log("HID NATIVE MAPPING apply_failed pending_rollback=\(records.count)")
            return .failed
        }
        var desired = RemoteButtonNativeMappingPolicy.applying(to: service.mappings)
        if includeHardwareVoiceMapping {
            desired = RemoteVoiceFunctionMappingPolicy.applying(to: desired)
        }
        if Self.canonical(service.mappings) == Self.canonical(desired) {
            pendingAcceptedWriteRegistryIDs.remove(service.registryID)
            log("HID NATIVE MAPPING settled registry=\(service.registryID) keys=\(RemoteButtonNativeMappingPolicy.mappings.count)")
            return .applied
        }
        let writeResult = service.writeAndVerify(desired)
        guard writeResult == .verified else {
            if writeResult != .setRejected {
                pendingAcceptedWriteRegistryIDs.insert(service.registryID)
            }
            // A newly published AppleUserHIDEventService can be enumerable before
            // it accepts or reflects UserKeyMapping. Keep the persisted rollback
            // record and retry while this exact device generation remains active.
            log("HID NATIVE MAPPING write_pending result=\(writeResult.logValue) registry=\(service.registryID)")
            return .serviceNotReady
        }
        pendingAcceptedWriteRegistryIDs.remove(service.registryID)
        log("HID NATIVE MAPPING applied registry=\(service.registryID) keys=\(RemoteButtonNativeMappingPolicy.mappings.count)")
        return .applied
    }

    @discardableResult
    func restore() -> Bool {
        guard let records else {
            log("HID NATIVE MAPPING restore_failed invalid_ledger")
            return false
        }
        guard !records.isEmpty else { return true }
        guard let present = services() else { return false }
        var remaining: [RemoteButtonNativeMappingRecord] = []
        for record in records {
            guard let service = present.first(where: { $0.registryID == record.registryID }) else {
                pendingAcceptedWriteRegistryIDs.remove(record.registryID)
                ownership.setCombinedVoiceMappingOwned(false, registryID: record.registryID)
                continue
            }
            let desired = RemoteButtonNativeMappingPolicy.restoring(
                originals: record.originals,
                in: service.mappings,
                includesHardwareVoiceMapping: record.includesHardwareVoiceMapping
            )
            if pendingAcceptedWriteRegistryIDs.contains(record.registryID) ||
                Self.canonical(desired) != Self.canonical(service.mappings) {
                let result = service.writeAndVerify(desired)
                if result != .verified {
                    log("HID NATIVE MAPPING restore_pending result=\(result.logValue) registry=\(record.registryID)")
                    remaining.append(record)
                } else {
                    pendingAcceptedWriteRegistryIDs.remove(record.registryID)
                    ownership.setCombinedVoiceMappingOwned(false, registryID: record.registryID)
                }
            } else {
                ownership.setCombinedVoiceMappingOwned(false, registryID: record.registryID)
            }
        }
        let persisted = save(remaining)
        let succeeded = persisted && remaining.isEmpty
        log("HID NATIVE MAPPING restored=\(succeeded) pending=\(remaining.count)")
        return succeeded
    }

    private func save(_ updated: [RemoteButtonNativeMappingRecord]) -> Bool {
        guard let data = try? JSONEncoder().encode(updated), store.save(data) else { return false }
        records = updated
        return true
    }

    private static func canonical(_ mappings: [HIDUsageMapping]) -> [HIDUsageMapping] {
        mappings.sorted {
            ($0.source, $0.destination) < ($1.source, $1.destination)
        }
    }

    static func liveServices() -> () -> [RemoteButtonNativeMappingService]? {
        // Keep the client alive for enumeration, property writes, and read-back.
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        return {
            guard let identity = VoiceBridgeDeviceProfiles.xiaomiRC003.hidIdentity,
                  let live = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]
            else { return nil }
            var snapshots: [RemoteButtonNativeMappingService] = []
            for service in live {
                let vendor = IOHIDServiceClientCopyProperty(service, kIOHIDVendorIDKey as CFString) as? NSNumber
                let product = IOHIDServiceClientCopyProperty(service, kIOHIDProductIDKey as CFString) as? NSNumber
                guard vendor?.intValue == identity.vendorID, product?.intValue == identity.productID else { continue }
                guard let id = IOHIDServiceClientGetRegistryID(service) as? NSNumber,
                      let location = IOHIDServiceClientCopyProperty(service, kIOHIDLocationIDKey as CFString) as? NSNumber,
                      let mappings = read(service)
                else { return nil }
                snapshots.append(RemoteButtonNativeMappingService(
                    registryID: id.uint64Value, locationID: location.uint64Value,
                    mappings: mappings,
                    writeAndVerify: { desired in
                        withExtendedLifetime(client) {
                            guard IOHIDServiceClientSetProperty(
                                service,
                                "UserKeyMapping" as CFString,
                                desired.map(\.property) as CFArray
                            ) else {
                                AppLogger.shared.write(
                                    "HID NATIVE WRITE registry=\(id.uint64Value) result=set_rejected"
                                )
                                return .setRejected
                            }
                            guard let actual = read(service) else {
                                AppLogger.shared.write(
                                    "HID NATIVE WRITE registry=\(id.uint64Value) result=readback_unavailable"
                                )
                                return .readbackUnavailable
                            }
                            let verified = canonical(actual) == canonical(desired)
                            AppLogger.shared.write(
                                "HID NATIVE WRITE registry=\(id.uint64Value) result=\(verified ? "verified" : "readback_mismatch") desired=\(desired.count) actual=\(actual.count)"
                            )
                            return verified ? .verified : .readbackMismatch
                        }
                    }
                ))
            }
            return snapshots
        }
    }

    private static func read(_ service: IOHIDServiceClient) -> [HIDUsageMapping]? {
        guard let raw = IOHIDServiceClientCopyProperty(service, "UserKeyMapping" as CFString) else { return [] }
        guard let values = raw as? [[String: NSNumber]] else { return nil }
        let parsed = values.compactMap(HIDUsageMapping.init(property:))
        return parsed.count == values.count ? parsed : nil
    }
}
