import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdateController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = true

    private let controller: SPUStandardUpdaterController
    private var observations: [NSKeyValueObservation] = []

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        let updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates

        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                DispatchQueue.main.async {
                    self?.canCheckForUpdates = updater.canCheckForUpdates
                }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                DispatchQueue.main.async {
                    self?.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
                }
            }
        ]
    }

    func start() {
        controller.startUpdater()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func makeCheckForUpdatesMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "检查更新…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        item.target = controller
        return item
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    var currentVersionText: String {
        UpdatePolicy.displayVersion()
    }
}
