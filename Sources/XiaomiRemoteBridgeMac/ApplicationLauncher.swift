import AppKit
import Foundation

enum ApplicationLauncher {
    /// Prefer the user's chosen copy. Resolve by bundle ID if it moved, while
    /// refusing a different application that has since occupied the saved path.
    static func resolve(
        _ target: ApplicationTarget,
        applicationAt: (URL) -> ApplicationTarget? = ApplicationTarget.application,
        installedApplicationURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    ) -> URL? {
        guard target.isValid else { return nil }
        let selected = URL(fileURLWithPath: target.path)
        if let current = applicationAt(selected),
           target.bundleIdentifier == nil || current.bundleIdentifier == target.bundleIdentifier {
            return selected
        }
        guard let identifier = target.bundleIdentifier,
              let relocated = installedApplicationURL(identifier),
              applicationAt(relocated)?.bundleIdentifier == identifier
        else { return nil }
        return relocated
    }

    /// Launch Services reuses the existing process and brings it to the front.
    /// Opening is asynchronous; failures are action errors, not keyboard/TCC
    /// failures, so they must not stop the remote's entire HID pipeline.
    static func open(_ target: ApplicationTarget) {
        guard let url = resolve(target) else {
            reportFailure("找不到应用 \(target.name)，请在按键设置中重新选择")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                DispatchQueue.main.async {
                    reportFailure("打开 \(target.name) 失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private static func reportFailure(_ message: String) {
        AppLogger.shared.write("APPLICATION OPEN \(message)")
        NSSound.beep()
    }
}
