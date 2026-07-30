import Foundation

enum UpdatePolicy {
    static let feedURLString = "https://raw.githubusercontent.com/nijez/open-voice-bridge/main/appcast.xml"
    static let scheduledCheckInterval: TimeInterval = 86_400
    static let allowsAutomaticInstallation = false

    static func displayVersion(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        return "\(version)（\(build)）"
    }
}
