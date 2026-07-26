import Foundation

enum DeviceProfileStatus: String, Codable, CaseIterable {
    case implemented
    case research
    case planned
    case unsupported

    var displayName: String {
        switch self {
        case .implemented: return "已实现"
        case .research: return "调研中"
        case .planned: return "已计划"
        case .unsupported: return "不支持"
        }
    }

    fileprivate var sortOrder: Int {
        switch self {
        case .implemented: return 0
        case .research: return 1
        case .planned: return 2
        case .unsupported: return 3
        }
    }
}

enum DeviceProfileTransportKind: String, Codable {
    case bleGATT = "ble-gatt"
    case bluetoothHID = "bluetooth-hid"
    case bluetoothBREDRAudio = "bluetooth-br-edr-audio"
    case usbDigitalAudio = "usb-digital-audio"
    case analogAudio = "analog-audio"
    case systemAudioInput = "system-audio-input"

    var displayName: String {
        switch self {
        case .bleGATT: return "BLE GATT"
        case .bluetoothHID: return "Bluetooth HID"
        case .bluetoothBREDRAudio: return "Bluetooth 音频"
        case .usbDigitalAudio: return "USB 数字音频"
        case .analogAudio: return "模拟音频"
        case .systemAudioInput: return "系统音频输入"
        }
    }
}

enum DeviceProfileTransportRole: String, Codable {
    case control
    case buttonInput = "button-input"
    case voiceInput = "voice-input"
    case voiceOutput = "voice-output"
}

enum DeviceProfileCapability: String, Codable {
    case voiceCapture = "voice-capture"
    case pressToTalk = "press-to-talk"
    case buttonInput = "button-input"
    case hostKeyMapping = "host-key-mapping"
    case gainControl = "gain-control"
    case channelSelection = "channel-selection"
    case deviceStatus = "device-status"

    var displayName: String {
        switch self {
        case .voiceCapture: return "语音采集"
        case .pressToTalk: return "按住说话"
        case .buttonInput: return "按键输入"
        case .hostKeyMapping: return "主机按键映射"
        case .gainControl: return "增益控制"
        case .channelSelection: return "声道选择"
        case .deviceStatus: return "设备状态"
        }
    }
}

enum DeviceProfilePlatformName: String, Codable, CaseIterable {
    case macos
    case windows
    case linux

    var displayName: String {
        switch self {
        case .macos: return "macOS"
        case .windows: return "Windows"
        case .linux: return "Linux"
        }
    }
}

struct DeviceProfileSupport: Codable, Equatable {
    let status: DeviceProfileStatus
    let notes: String
}

struct DeviceProfileHIDIdentity: Codable, Equatable {
    let vendorId: Int
    let productId: Int
}

struct DeviceProfileIdentity: Codable, Equatable {
    let bluetoothNames: [String]?
    let bluetoothNamePrefixes: [String]?
    let audioInputNamePrefixes: [String]?
    let hid: DeviceProfileHIDIdentity?
}

struct DeviceProfileTransport: Codable, Equatable, Identifiable {
    let kind: DeviceProfileTransportKind
    let role: DeviceProfileTransportRole
    let status: DeviceProfileStatus
    let notes: String

    var id: String { "\(kind.rawValue):\(role.rawValue)" }
}

struct DeviceProfileProtocol: Codable, Equatable {
    let id: String
    let status: DeviceProfileStatus
    let notes: String
}

struct DeviceProfilePlatform: Codable, Equatable, Identifiable {
    let platform: DeviceProfilePlatformName
    let status: DeviceProfileStatus
    let notes: String

    var id: String { platform.rawValue }
}

struct DeviceProfileDescriptor: Codable, Equatable, Identifiable {
    let schemaVersion: Int
    let id: String
    let displayName: String
    let vendor: String
    let model: String
    let support: DeviceProfileSupport
    let identity: DeviceProfileIdentity
    let transports: [DeviceProfileTransport]
    let capabilities: [DeviceProfileCapability]
    let protocols: [DeviceProfileProtocol]?
    let platforms: [DeviceProfilePlatform]
    let sources: [String]
}

enum DeviceProfileCatalogError: Error, Equatable, CustomStringConvertible {
    case directoryUnavailable
    case noProfiles
    case unreadableProfile(String)
    case invalidProfile(String, String)
    case duplicateID(String)

    var description: String {
        switch self {
        case .directoryUnavailable:
            return "未找到内置设备目录"
        case .noProfiles:
            return "内置设备目录中没有 profile JSON"
        case let .unreadableProfile(filename):
            return "无法读取设备资料记录 \(filename)"
        case let .invalidProfile(filename, reason):
            return "设备资料记录 \(filename) 无效：\(reason)"
        case let .duplicateID(id):
            return "设备目录包含重复 ID：\(id)"
        }
    }
}

enum DeviceProfileCatalogState: Equatable {
    case available([DeviceProfileDescriptor])
    case unavailable(String)

    var profiles: [DeviceProfileDescriptor] {
        guard case let .available(profiles) = self else { return [] }
        return profiles
    }

    var errorMessage: String? {
        guard case let .unavailable(message) = self else { return nil }
        return message
    }
}

enum DeviceProfileCatalog {
    static func loadBundled(bundle: Bundle = .main) -> DeviceProfileCatalogState {
        guard let resourceURL = bundle.resourceURL else {
            return .unavailable(DeviceProfileCatalogError.directoryUnavailable.description)
        }
        do {
            return .available(
                try load(directory: resourceURL.appendingPathComponent("device-profiles", isDirectory: true))
            )
        } catch {
            return .unavailable((error as? DeviceProfileCatalogError)?.description ?? "设备目录加载失败")
        }
    }

    static func load(directory: URL) throws -> [DeviceProfileDescriptor] {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw DeviceProfileCatalogError.directoryUnavailable
        }

        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw DeviceProfileCatalogError.directoryUnavailable
        }
        guard !urls.isEmpty else { throw DeviceProfileCatalogError.noProfiles }

        var profiles: [DeviceProfileDescriptor] = []
        var seenIDs = Set<String>()
        let decoder = JSONDecoder()
        for url in urls {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw DeviceProfileCatalogError.unreadableProfile(url.lastPathComponent)
            }

            let profile: DeviceProfileDescriptor
            do {
                profile = try decoder.decode(DeviceProfileDescriptor.self, from: data)
            } catch {
                throw DeviceProfileCatalogError.invalidProfile(
                    url.lastPathComponent,
                    Self.decodeFailureReason(error)
                )
            }
            try validate(profile, filename: url.lastPathComponent)
            guard seenIDs.insert(profile.id).inserted else {
                throw DeviceProfileCatalogError.duplicateID(profile.id)
            }
            profiles.append(profile)
        }

        return profiles.sorted {
            if $0.support.status.sortOrder != $1.support.status.sortOrder {
                return $0.support.status.sortOrder < $1.support.status.sortOrder
            }
            return $0.id < $1.id
        }
    }

    private static func validate(_ profile: DeviceProfileDescriptor, filename: String) throws {
        func reject(_ reason: String) throws {
            throw DeviceProfileCatalogError.invalidProfile(filename, reason)
        }

        guard profile.schemaVersion == 1 else { try reject("schemaVersion 不受支持"); return }
        let idPattern = "^[a-z0-9]+([.-][a-z0-9]+)*$"
        guard profile.id.range(of: idPattern, options: .regularExpression) != nil else {
            try reject("id 格式无效"); return
        }
        guard !profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !profile.vendor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !profile.support.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { try reject("必填文本为空"); return }
        guard !profile.transports.isEmpty, !profile.capabilities.isEmpty,
              !profile.platforms.isEmpty, !profile.sources.isEmpty
        else { try reject("必填列表为空"); return }
        guard Set(profile.capabilities.map(\.rawValue)).count == profile.capabilities.count else {
            try reject("capabilities 重复"); return
        }
        guard Set(profile.platforms.map(\.platform.rawValue)).count == profile.platforms.count else {
            try reject("platforms 重复"); return
        }
        if let hid = profile.identity.hid,
           !(0...65_535).contains(hid.vendorId) || !(0...65_535).contains(hid.productId)
        {
            try reject("HID ID 超出 16 位范围"); return
        }
        for transport in profile.transports
        where transport.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try reject("transport notes 为空"); return
        }
        for item in profile.protocols ?? []
        where item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            item.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try reject("protocol 必填文本为空"); return
        }
        for source in profile.sources {
            guard let url = URL(string: source),
                  ["http", "https"].contains(url.scheme?.lowercased()),
                  url.host != nil
            else {
                try reject("source URL 无效"); return
            }
        }
    }

    private static func decodeFailureReason(_ error: Error) -> String {
        if case let DecodingError.keyNotFound(key, _) = error {
            return "缺少字段 \(key.stringValue)"
        }
        if case let DecodingError.dataCorrupted(context) = error {
            if context.debugDescription.contains("Cannot initialize") {
                return "包含未知枚举值"
            }
            return "JSON 内容损坏"
        }
        if error is DecodingError { return "字段类型不匹配" }
        return "JSON 解析失败"
    }
}
