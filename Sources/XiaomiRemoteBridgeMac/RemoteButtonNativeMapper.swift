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
        originals: [HIDUsageMapping], in current: [HIDUsageMapping]
    ) -> [HIDUsageMapping] {
        // Restore only mappings that still equal our value. A later third-party
        // edit/removal wins, and unrelated changes (including F5) are preserved.
        let ownedSources = Set(mappings.filter { mapping in
            current.filter { $0.source == mapping.source } == [mapping]
        }.map(\.source))
        return current.filter { !ownedSources.contains($0.source) } +
            originals.filter { ownedSources.contains($0.source) }
    }
}

struct RemoteButtonNativeMappingRecord: Codable, Equatable {
    let registryID: UInt64
    let originals: [HIDUsageMapping]
}

/// A fresh service snapshot. Its writer verifies read-back while retaining the
/// IOHID service's owning client. Tests replace this seam without touching HID.
struct RemoteButtonNativeMappingService {
    let registryID: UInt64
    let locationID: UInt64
    let mappings: [HIDUsageMapping]
    let writeAndVerify: ([HIDUsageMapping]) -> Bool
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
    /// AppleUserHIDEventService. Retry only that transient enumeration gap, with
    /// a finite 2.5-second budget; every other safety failure still fails closed.
    private static let delays: [TimeInterval] = [0.05, 0.15, 0.35, 0.75, 1.2]

    static func delay(afterAttempt attempt: Int) -> TimeInterval? {
        guard delays.indices.contains(attempt) else { return nil }
        return delays[attempt]
    }
}

/// Main-thread lifecycle owner for the adopted RC003's ordinary-key mappings.
/// Persist rollback data BEFORE writing so relaunch can recover after a crash.
/// The registry ID restricts rollback to the original service; a disconnected
/// service loses its device-local property and its ledger entry can be dropped.
final class RemoteButtonNativeMapper {
    private let services: () -> [RemoteButtonNativeMappingService]?
    private let store: RemoteButtonNativeMappingStore
    private let log: (String) -> Void
    private var records: [RemoteButtonNativeMappingRecord]?

    init(
        services: @escaping () -> [RemoteButtonNativeMappingService]? = RemoteButtonNativeMapper.liveServices(),
        store: RemoteButtonNativeMappingStore = .preferences(),
        log: @escaping (String) -> Void = { AppLogger.shared.write($0) }
    ) {
        self.services = services
        self.store = store
        self.log = log
        if let data = store.load() {
            records = try? JSONDecoder().decode([RemoteButtonNativeMappingRecord].self, from: data)
            if let decoded = records,
               Set(decoded.map(\.registryID)).count != decoded.count ||
                decoded.contains(where: { record in
                    record.originals.contains { !RemoteButtonNativeMappingPolicy.sources.contains($0.source) }
                }) {
                records = nil
            }
        } else {
            records = []
        }
    }

    @discardableResult
    func apply(locationID: UInt64) -> Bool {
        applyResult(locationID: locationID) == .applied
    }

    func applyResult(locationID: UInt64) -> RemoteButtonNativeMappingApplyResult {
        guard let records else {
            log("HID NATIVE MAPPING apply_failed invalid_ledger")
            return .failed
        }
        guard records.isEmpty else {
            log("HID NATIVE MAPPING apply_failed pending_rollback=\(records.count)")
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
        let saved = RemoteButtonNativeMappingRecord(
            registryID: service.registryID,
            originals: service.mappings.filter { RemoteButtonNativeMappingPolicy.sources.contains($0.source) }
        )
        guard save([saved]) else {
            log("HID NATIVE MAPPING apply_failed backup")
            return .failed
        }
        let desired = RemoteButtonNativeMappingPolicy.applying(to: service.mappings)
        guard service.writeAndVerify(desired) else {
            _ = restore()
            log("HID NATIVE MAPPING apply_failed write_verify")
            return .failed
        }
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
            guard let service = present.first(where: { $0.registryID == record.registryID }) else { continue }
            let desired = RemoteButtonNativeMappingPolicy.restoring(
                originals: record.originals, in: service.mappings
            )
            if desired != service.mappings && !service.writeAndVerify(desired) {
                remaining.append(record)
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
                            IOHIDServiceClientSetProperty(service, "UserKeyMapping" as CFString, desired.map(\.property) as CFArray) &&
                                read(service) == desired
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
