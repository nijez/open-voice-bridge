import AppKit
import Combine
import Darwin
import Foundation
import ServiceManagement

enum LegacyLaunchAgentStatus: Equatable {
    case disabled
    case enabled
    case stale
}

enum LegacyLaunchAgentError: LocalizedError {
    case bootoutFailed
    case bootstrapFailed

    var errorDescription: String? {
        switch self {
        case .bootoutFailed:
            return "无法停止旧登录项"
        case .bootstrapFailed:
            return "无法加载登录项"
        }
    }
}

struct LegacyLaunchAgentBackend {
    typealias LaunchctlRunner = ([String]) -> Bool

    let bundleIdentifier: String
    let propertyListURL: URL
    let userID: uid_t
    let fileManager: FileManager
    let runLaunchctl: LaunchctlRunner

    var label: String {
        LaunchAtLoginManager.legacyLaunchAgentLabel(bundleIdentifier: bundleIdentifier)
    }

    var jobTarget: String { "gui/\(userID)/\(label)" }

    var status: LegacyLaunchAgentStatus {
        let fileExists = fileManager.fileExists(atPath: propertyListURL.path)
        let loaded = isJobLoaded
        if fileExists && loaded { return .enabled }
        if fileExists || loaded { return .stale }
        return .disabled
    }

    func enable() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: LaunchAtLoginManager.legacyLaunchAgentPropertyList(
                bundleIdentifier: bundleIdentifier
            ),
            format: .xml,
            options: 0
        )
        let existingMatches = (try? Data(contentsOf: propertyListURL)) == data
        let loaded = isJobLoaded

        if existingMatches && loaded { return }
        if loaded && !runLaunchctl(["bootout", jobTarget]) {
            throw LegacyLaunchAgentError.bootoutFailed
        }

        try fileManager.createDirectory(
            at: propertyListURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !existingMatches {
            try data.write(to: propertyListURL, options: .atomic)
        }

        guard runLaunchctl([
            "bootstrap",
            "gui/\(userID)",
            propertyListURL.path,
        ]) else {
            try? fileManager.removeItem(at: propertyListURL)
            throw LegacyLaunchAgentError.bootstrapFailed
        }
    }

    func disable() throws {
        if isJobLoaded && !runLaunchctl(["bootout", jobTarget]) {
            throw LegacyLaunchAgentError.bootoutFailed
        }
        if fileManager.fileExists(atPath: propertyListURL.path) {
            try fileManager.removeItem(at: propertyListURL)
        }
    }

    private var isJobLoaded: Bool {
        runLaunchctl(["print", jobTarget])
    }
}

final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var statusText = "正在检查登录启动状态"
    @Published private(set) var isEffective = false
    @Published private(set) var requiresApproval = false

    private let bundleURL: URL
    private let fileManager: FileManager
    private let legacyBackend: LegacyLaunchAgentBackend

    init(
        bundleIdentifier: String = Bundle.main.bundleIdentifier
            ?? "com.kingwell.XiaomiRemoteBridgeMac",
        bundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default,
        userID: uid_t = getuid(),
        launchctlRunner: @escaping LegacyLaunchAgentBackend.LaunchctlRunner =
            LaunchAtLoginManager.runLaunchctl
    ) {
        self.bundleURL = bundleURL
        self.fileManager = fileManager
        let propertyListURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(
                "\(Self.legacyLaunchAgentLabel(bundleIdentifier: bundleIdentifier)).plist"
            )
        legacyBackend = LegacyLaunchAgentBackend(
            bundleIdentifier: bundleIdentifier,
            propertyListURL: propertyListURL,
            userID: userID,
            fileManager: fileManager,
            runLaunchctl: launchctlRunner
        )
        refreshStatus()
    }

    func apply(desiredEnabled: Bool) {
        guard Self.isInstalledApplicationBundle(
            bundleURL,
            homeDirectory: fileManager.homeDirectoryForCurrentUser
        ) else {
            isEffective = false
            requiresApproval = false
            statusText = "开发构建：安装到“应用程序”后生效"
            return
        }

        if #available(macOS 13.0, *) {
            do {
                try legacyBackend.disable()
                applyModernService(desiredEnabled: desiredEnabled)
            } catch {
                reportFailure(prefix: "清理旧登录项失败", error: error)
            }
        } else {
            applyLegacyLaunchAgent(desiredEnabled: desiredEnabled)
        }
    }

    func refreshStatus() {
        guard Self.isInstalledApplicationBundle(
            bundleURL,
            homeDirectory: fileManager.homeDirectoryForCurrentUser
        ) else {
            isEffective = false
            requiresApproval = false
            statusText = "开发构建：安装到“应用程序”后生效"
            return
        }

        if #available(macOS 13.0, *) {
            let legacyStatus = legacyBackend.status
            if legacyStatus == .disabled {
                updateModernStatus(SMAppService.mainApp.status)
            } else {
                reportLegacyConflict(legacyStatus)
            }
        } else {
            updateLegacyStatus(legacyBackend.status)
        }
    }

    func openLoginItemsSettings() {
        let rawURL: String
        if #available(macOS 13.0, *) {
            rawURL = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        } else {
            rawURL = "x-apple.systempreferences:com.apple.preference.users?LoginItems"
        }
        guard let url = URL(string: rawURL) else { return }
        NSWorkspace.shared.open(url)
    }

    static func isInstalledApplicationBundle(_ bundleURL: URL, homeDirectory: URL) -> Bool {
        guard bundleURL.pathExtension.lowercased() == "app" else { return false }
        let path = bundleURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .standardizedFileURL.path + "/"
        let userApplications = homeDirectory
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL.path + "/"
        return path.hasPrefix(systemApplications) || path.hasPrefix(userApplications)
    }

    static func legacyLaunchAgentLabel(bundleIdentifier: String) -> String {
        "\(bundleIdentifier).LaunchAtLogin"
    }

    static func legacyLaunchAgentPropertyList(bundleIdentifier: String) -> [String: Any] {
        [
            "Label": legacyLaunchAgentLabel(bundleIdentifier: bundleIdentifier),
            "LimitLoadToSessionType": "Aqua",
            "ProgramArguments": ["/usr/bin/open", "-b", bundleIdentifier],
            "RunAtLoad": true,
        ]
    }

    @available(macOS 13.0, *)
    private func applyModernService(desiredEnabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if desiredEnabled {
                if service.status != .enabled && service.status != .requiresApproval {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            updateModernStatus(service.status)
        } catch {
            reportFailure(prefix: "设置失败", error: error)
            AppLogger.shared.write("LOGIN ITEM failed desired=\(desiredEnabled) error=\(error)")
        }
    }

    @available(macOS 13.0, *)
    private func updateModernStatus(_ status: SMAppService.Status) {
        switch status {
        case .enabled:
            isEffective = true
            requiresApproval = false
            statusText = "已开启，下次登录时自动启动"
        case .requiresApproval:
            isEffective = false
            requiresApproval = true
            statusText = "需在系统“登录项”中允许"
        case .notFound:
            isEffective = false
            requiresApproval = false
            statusText = "未找到应用，请重新安装到“应用程序”"
        case .notRegistered:
            isEffective = false
            requiresApproval = false
            statusText = "已关闭"
        @unknown default:
            isEffective = false
            requiresApproval = false
            statusText = "无法确认登录启动状态"
        }
    }

    private func applyLegacyLaunchAgent(desiredEnabled: Bool) {
        do {
            if desiredEnabled {
                try legacyBackend.enable()
            } else {
                try legacyBackend.disable()
            }
            updateLegacyStatus(legacyBackend.status)
        } catch {
            reportFailure(prefix: desiredEnabled ? "开启失败" : "关闭失败", error: error)
            AppLogger.shared.write("LOGIN ITEM legacy desired=\(desiredEnabled) error=\(error)")
        }
    }

    private func updateLegacyStatus(_ status: LegacyLaunchAgentStatus) {
        requiresApproval = false
        switch status {
        case .enabled:
            isEffective = true
            statusText = "已开启，下次登录时自动启动"
        case .disabled:
            isEffective = false
            statusText = "已关闭"
        case .stale:
            isEffective = false
            statusText = "登录项未正常加载，请关闭后重新开启"
        }
    }

    private func reportLegacyConflict(_ status: LegacyLaunchAgentStatus) {
        isEffective = false
        requiresApproval = false
        switch status {
        case .enabled:
            statusText = "检测到仍在运行的旧登录项，请关闭后重新开启"
        case .stale:
            statusText = "检测到未清理的旧登录项，请关闭后重新开启"
        case .disabled:
            break
        }
    }

    private func reportFailure(prefix: String, error: Error) {
        isEffective = false
        requiresApproval = false
        statusText = "\(prefix)：\(error.localizedDescription)"
    }

    private static func runLaunchctl(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
