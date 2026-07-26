import AppKit
import Combine
import Darwin
import SwiftUI

@main
enum XiaomiRemoteBridgeMacApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = XiaomiRemoteBridgeAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
private final class XiaomiRemoteBridgeAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let model = BridgeAppModel()
    private var statusItem: NSStatusItem?
    private var settingsWindowController: NSWindowController?
    private var subscriptions = Set<AnyCancellable>()
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private var presentingHIDPermissionReminder = false

    private let connectionItem = NSMenuItem(title: "正在初始化蓝牙", action: nil, keyEquivalent: "")
    private let audioItem = NSMenuItem(title: "未选择语音输出设备", action: nil, keyEquivalent: "")
    private let hidItem = NSMenuItem(title: "按键映射未启用", action: nil, keyEquivalent: "")
    private let bridgeStatusItem = NSMenuItem(title: "桥接已启用", action: nil, keyEquivalent: "")
    private let bridgeToggleItem = NSMenuItem(title: "停用桥接", action: nil, keyEquivalent: "")
    private let reconnectItem = NSMenuItem(title: "立即重新连接", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminationSignalHandlers()
        configureStatusItem()
        observeModel()
        model.reconcileLaunchAtLogin()
        model.startIfNeeded()
        refreshMenuStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        terminationSignalSources.forEach { $0.cancel() }
        terminationSignalSources.removeAll()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshLaunchAtLoginStatus()
        model.refreshHIDPermissionReminder()
    }

    private func installTerminationSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .main
            )
            source.setEventHandler {
                NSApp.terminate(nil)
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuStatus()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showSettings()
        return true
    }

    private func configureStatusItem() {
        // squareLength keeps the menu-bar footprint as small as macOS allows.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.toolTip = "Open Voice Bridge"
            if let image = NSImage(
                systemSymbolName: "dot.radiowaves.left.and.right",
                accessibilityDescription: "小米遥控器"
            ) {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "小米遥控器"
            }
        }

        connectionItem.isEnabled = false
        audioItem.isEnabled = false
        hidItem.isEnabled = false
        bridgeStatusItem.isEnabled = false

        bridgeToggleItem.target = self
        bridgeToggleItem.action = #selector(toggleBridge)
        reconnectItem.target = self
        reconnectItem.action = #selector(reconnect)

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(connectionItem)
        menu.addItem(audioItem)
        menu.addItem(hidItem)
        menu.addItem(bridgeStatusItem)
        menu.addItem(.separator())
        menu.addItem(bridgeToggleItem)
        menu.addItem(reconnectItem)
        menu.addItem(menuItem("打开设置…", action: #selector(showSettings)))
        menu.addItem(menuItem("显示日志", action: #selector(showLog)))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出", action: #selector(quit)))
        item.menu = menu
        statusItem = item
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func observeModel() {
        Publishers.CombineLatest4(
            model.$connectionStatus,
            model.$audioStatus,
            model.$hidStatus,
            model.$isStreaming
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.refreshMenuStatus()
        }
        .store(in: &subscriptions)

        model.$bridgeRuntimeStatus
            .combineLatest(model.$bridgeEnabled)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshMenuStatus()
            }
        .store(in: &subscriptions)

        model.settings.$selectedDeviceProfile
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshMenuStatus()
            }
        .store(in: &subscriptions)

        model.$pendingHIDPermissionReminder
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] request in
                self?.presentHIDPermissionReminderIfNeeded(for: request)
            }
            .store(in: &subscriptions)
    }

    private func presentHIDPermissionReminderIfNeeded(for request: HIDPermissionRequest) {
        guard request != .none, !presentingHIDPermissionReminder else { return }
        presentingHIDPermissionReminder = true
        showSettings()
        guard let window = settingsWindowController?.window else {
            presentingHIDPermissionReminder = false
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        switch request {
        case .inputMonitoring:
            alert.messageText = "按键映射需要重新开启“输入监控”"
            alert.informativeText = "macOS 未授予输入监控。系统不允许应用自行开启此权限；请在系统设置中打开“小米遥控器桥接”。如果返回后仍显示同一项，不需要反复开关：完全退出并重新打开应用一次即可复检。"
            alert.addButton(withTitle: "打开输入监控设置")
        case .accessibility:
            alert.messageText = "按键映射需要重新开启“辅助功能”"
            alert.informativeText = "macOS 未授予辅助功能。系统不允许应用自行开启此权限；请在系统设置中打开“小米遥控器桥接”。完成后返回应用会自动重新连接按键映射。"
            alert.addButton(withTitle: "打开辅助功能设置")
        case .none:
            presentingHIDPermissionReminder = false
            return
        }
        alert.addButton(withTitle: "稍后")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.presentingHIDPermissionReminder = false
            self.model.dismissHIDPermissionReminder()
            guard response == .alertFirstButtonReturn else { return }
            switch request {
            case .inputMonitoring:
                self.model.requestInputMonitoringPermission()
            case .accessibility:
                self.model.requestAccessibilityPermission()
            case .none:
                break
            }
        }
    }

    private func refreshMenuStatus() {
        let isRC003 = model.settings.selectedDeviceProfile == .xiaomiRC003
        connectionItem.title = model.connectionStatus
        audioItem.title = isRC003
            ? (model.isStreaming ? "语音中" : model.audioStatus)
            : "音频由 macOS 系统输入管理"
        hidItem.title = isRC003 ? model.hidStatus : "DJI Mic 2 无应用按键映射"
        bridgeStatusItem.title = isRC003 ? model.bridgeRuntimeStatus : "RC003 桥接未运行"
        bridgeToggleItem.title = model.bridgeEnabled ? "停用桥接" : "启用桥接"
        bridgeToggleItem.isHidden = !isRC003
        reconnectItem.isHidden = !isRC003
        let symbol: String
        if !isRC003 {
            symbol = "mic"
        } else if !model.bridgeEnabled {
            symbol = "pause.circle"
        } else if model.isStreaming {
            symbol = "mic.fill"
        } else {
            symbol = "dot.radiowaves.left.and.right"
        }
        statusItem?.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: isRC003
                ? (model.bridgeEnabled
                    ? (model.isStreaming ? "小米遥控器语音中" : "小米遥控器")
                    : "小米遥控器桥接已停用")
                : "DJI Mic 2 系统输入"
        )
    }

    @objc private func reconnect() {
        model.reconnect()
    }

    @objc private func toggleBridge() {
        model.toggleBridgeEnabled(source: "menu")
    }

    @objc private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = makeSettingsWindowController()
        }
        guard let windowController = settingsWindowController,
              let window = windowController.window else { return }
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindowController() -> NSWindowController {
        let hostingController = NSHostingController(rootView: SettingsView(model: model))
        // The window owns its size. Letting NSHostingController also push the
        // SwiftUI tree's preferred/intrinsic size back into a resizable AppKit
        // window creates a two-way sizing loop on newer macOS releases:
        // window layout -> SwiftUI measurement -> preferredContentSize -> window
        // layout. In the failure mode this never settles and the main thread stays
        // in `layoutIfNeeded` even when the user is not interacting with the app.
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = []
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Open Voice Bridge"
        window.contentViewController = hostingController
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 800, height: 650)
        window.setFrameAutosaveName("XiaomiRemoteBridgeSettings")
        window.center()
        return NSWindowController(window: window)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === settingsWindowController?.window
        else { return }

        // Closing Settings must also destroy its SwiftUI observation tree. Keeping
        // a hidden NSHostingController forever means every later model publication
        // can still schedule an off-screen layout pass; once AppKit enters a bad
        // sizing cycle, merely hiding the window does not stop the CPU spin.
        closingWindow.contentViewController = nil
        settingsWindowController = nil
    }

    @objc private func showLog() {
        model.openLogFolder()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
