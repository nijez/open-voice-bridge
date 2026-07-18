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
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
private final class XiaomiRemoteBridgeAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = BridgeAppModel()
    private var statusItem: NSStatusItem?
    private var settingsWindowController: NSWindowController?
    private var subscriptions = Set<AnyCancellable>()
    private var terminationSignalSources: [DispatchSourceSignal] = []

    private let connectionItem = NSMenuItem(title: "正在初始化蓝牙", action: nil, keyEquivalent: "")
    private let audioItem = NSMenuItem(title: "未选择语音输出设备", action: nil, keyEquivalent: "")
    private let hidItem = NSMenuItem(title: "按键映射未启用", action: nil, keyEquivalent: "")
    private let bridgeStatusItem = NSMenuItem(title: "桥接已启用", action: nil, keyEquivalent: "")
    private let bridgeToggleItem = NSMenuItem(title: "停用桥接", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminationSignalHandlers()
        configureStatusItem()
        observeModel()
        model.startIfNeeded()
        refreshMenuStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        terminationSignalSources.forEach { $0.cancel() }
        terminationSignalSources.removeAll()
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

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.toolTip = "小米遥控器桥接"
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

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(connectionItem)
        menu.addItem(audioItem)
        menu.addItem(hidItem)
        menu.addItem(bridgeStatusItem)
        menu.addItem(.separator())
        menu.addItem(bridgeToggleItem)
        menu.addItem(menuItem("立即重新连接", action: #selector(reconnect)))
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
    }

    private func refreshMenuStatus() {
        connectionItem.title = model.connectionStatus
        audioItem.title = model.isStreaming ? "语音中" : model.audioStatus
        hidItem.title = model.hidStatus
        bridgeStatusItem.title = model.bridgeRuntimeStatus
        bridgeToggleItem.title = model.bridgeEnabled ? "停用桥接" : "启用桥接"
        let symbol: String
        if !model.bridgeEnabled {
            symbol = "pause.circle"
        } else if model.isStreaming {
            symbol = "mic.fill"
        } else {
            symbol = "dot.radiowaves.left.and.right"
        }
        statusItem?.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: model.bridgeEnabled
                ? (model.isStreaming ? "小米遥控器语音中" : "小米遥控器")
                : "小米遥控器桥接已停用"
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "小米遥控器桥接"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 800, height: 650)
        window.setFrameAutosaveName("XiaomiRemoteBridgeSettings")
        window.center()
        return NSWindowController(window: window)
    }

    @objc private func showLog() {
        model.openLogFolder()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
