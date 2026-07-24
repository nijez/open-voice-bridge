import AppKit
import Combine
import Foundation

final class BridgeAppModel: ObservableObject, XiaomiBluetoothBridgeDelegate {
    let settings = AppSettings()

    @Published private(set) var connectionStatus = "正在初始化蓝牙"
    @Published private(set) var hidStatus = "按键映射未启用"
    @Published private(set) var audioStatus = "未选择语音输出设备"
    @Published private(set) var isStreaming = false
    @Published private(set) var audioDevices: [AudioDeviceInfo] = []
    @Published private(set) var testToneStatus = "未选择语音输出设备"
    @Published private(set) var isPlayingTestTone = false
    @Published private(set) var isAudioReady = false
    @Published private(set) var voiceShortcutStatus = "正在准备遥控器 Fn 硬件映射"

    private let audioOutput = VirtualAudioOutput()
    private let audioDeviceMonitor = CoreAudioDeviceMonitor()
    private let voiceFunctionMapper = RemoteVoiceFunctionMapper()
    private var testToneGeneration = 0
    private var voiceFunctionKeyLatch = VoiceFunctionKeyLatch()
    private var audioRecoveryState = AudioRecoveryState()
    private var audioRecoveryWorkItem: DispatchWorkItem?
    private var pendingAudioRecoveryReason: AudioRecoveryReason?
    private var didRequestAudioRecoveryForCurrentStream = false
    private lazy var bluetoothBridge = XiaomiBluetoothBridge(settings: settings, delegate: self)
    private lazy var hidMonitor: HIDRemoteMonitor = {
        let monitor = HIDRemoteMonitor(settings: settings)
        monitor.onStatus = { [weak self] value in
            self?.hidStatus = value
        }
        return monitor
    }()
    private var started = false
    private var terminationObserver: NSObjectProtocol?

    init() {
        audioOutput.onConfigurationChange = { [weak self] in
            self?.requestAudioRecovery(reason: .engineConfigurationChanged)
        }
        audioDeviceMonitor.onEvent = { [weak self] event in
            let reason: AudioRecoveryReason = event == .devicesChanged
                ? .devicesChanged
                : .defaultOutputChanged
            self?.requestAudioRecovery(reason: reason)
        }
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        refreshAudioDevices()
        applyAudioSettings()
        audioDeviceMonitor.start()
        applyHIDSettings()
        applyVoiceFunctionMapping()
        bluetoothBridge.start()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stop()
        }
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        AppLogger.shared.write("APP START version=\(version)")
    }

    func stop() {
        guard started else { return }
        cancelScheduledAudioRecovery()
        cancelTestToneIfNeeded(statusMessage: "应用已停止", logReason: "app_stop")
        bluetoothBridge.stop()
        updateVoiceFunctionKeyState(streaming: false)
        hidMonitor.stop()
        audioDeviceMonitor.stop()
        audioOutput.stop()
        isAudioReady = false
        voiceFunctionMapper.restore()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        started = false
        AppLogger.shared.write("APP STOP")
    }

    func reconnect() {
        bluetoothBridge.reconnectNow()
    }

    func refreshAudioDevices() {
        audioDevices = CoreAudioDeviceCatalog.outputDevices()
    }

    func applyAudioSettings() {
        cancelScheduledAudioRecovery()
        didRequestAudioRecoveryForCurrentStream = false
        _ = configureSelectedAudioOutput(recoveryReason: nil)
    }

    @discardableResult
    private func configureSelectedAudioOutput(
        recoveryReason: AudioRecoveryReason?
    ) -> Bool {
        cancelTestToneIfNeeded(statusMessage: "设备已更新，测试音已取消", logReason: "device_reconfigure")
        let deviceUID = settings.selectedAudioDeviceUID
        let configured = audioOutput.configure(deviceUID: deviceUID)
        isAudioReady = configured && audioOutput.restoreIfBound(deviceUID: deviceUID)
        audioStatus = audioOutput.status
        testToneStatus = isAudioReady
            ? "可发送测试音"
            : "未选择语音输出设备或设备不可用"
        if let recoveryReason {
            AppLogger.shared.write(
                "AUDIO RECOVERY \(isAudioReady ? "ready" : "failed") " +
                    "reason=\(recoveryReason.rawValue)"
            )
        }
        return isAudioReady
    }

    var canSendTestTone: Bool {
        TestToneGate.canPlay(
            hasSelectedDevice: isAudioReady,
            isStreaming: isStreaming,
            isPlaying: isPlayingTestTone
        )
    }

    func sendTestTone() {
        guard TestToneGate.canPlay(
            hasSelectedDevice: isAudioReady,
            isStreaming: isStreaming,
            isPlaying: isPlayingTestTone
        ) else {
            if isStreaming {
                testToneStatus = "RC003 语音进行中，已拒绝测试音"
                AppLogger.shared.write("AUDIO TEST_TONE rejected_streaming")
            } else if isPlayingTestTone {
                testToneStatus = "测试音正在播放中"
            } else {
                testToneStatus = "未选择语音输出设备或设备不可用"
            }
            return
        }

        testToneGeneration &+= 1
        let generation = testToneGeneration
        let started = audioOutput.playTestTone { [weak self] finished in
            DispatchQueue.main.async {
                self?.handleTestToneCompletion(generation: generation, finished: finished)
            }
        }
        guard started else {
            testToneStatus = "测试音发送失败：设备未就绪"
            return
        }
        isPlayingTestTone = true
        testToneStatus = "正在播放约 1 秒测试音"
        AppLogger.shared.write("AUDIO TEST_TONE played")
    }

    private func handleTestToneCompletion(generation: Int, finished: Bool) {
        guard generation == testToneGeneration, isPlayingTestTone else { return }
        isPlayingTestTone = false
        testToneStatus = finished ? "测试音已完成" : "测试音已取消"
        AppLogger.shared.write("AUDIO TEST_TONE \(finished ? "finished" : "cut_short")")
    }

    private func cancelTestToneIfNeeded(statusMessage: String, logReason: String) {
        guard isPlayingTestTone else { return }
        testToneGeneration &+= 1
        isPlayingTestTone = false
        audioOutput.cancelTestTone()
        testToneStatus = statusMessage
        AppLogger.shared.write("AUDIO TEST_TONE cancelled reason=\(logReason)")
    }

    func applyHIDSettings() {
        requestNextHIDPermissionIfNeeded()
        hidMonitor.start()
        hidStatus = hidMonitor.status
    }

    private func requestNextHIDPermissionIfNeeded() {
        let request = HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: settings.customMappingEnabled,
            inputMonitoringGranted: HIDRemoteMonitor.isInputMonitoringGranted,
            accessibilityGranted: KeyboardInjector.isAccessibilityTrusted
        )
        switch request {
        case .none:
            break
        case .inputMonitoring:
            _ = HIDRemoteMonitor.requestInputMonitoringAccess()
        case .accessibility:
            _ = KeyboardInjector.requestAccessibilityAccess()
        }
    }

    func requestInputMonitoringPermission() {
        _ = HIDRemoteMonitor.requestInputMonitoringAccess()
        openPrivacyPane("Privacy_ListenEvent")
    }

    func requestAccessibilityPermission() {
        _ = KeyboardInjector.requestAccessibilityAccess()
        openPrivacyPane("Privacy_Accessibility")
    }

    func openLogFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([AppLogger.shared.logURL])
    }

    func openProjectFolder() {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var candidate = executable.deletingLastPathComponent()
        if candidate.path.contains(".app/Contents/MacOS") {
            candidate.deleteLastPathComponent()
            candidate.deleteLastPathComponent()
            candidate.deleteLastPathComponent()
        }
        NSWorkspace.shared.open(candidate)
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func bluetoothBridge(
        _ bridge: XiaomiBluetoothBridge,
        didChange state: BluetoothBridgeState
    ) {
        connectionStatus = state.displayText
        if case .ready = state {
            applyVoiceFunctionMapping()
        }
    }

    func bluetoothBridgeDidStartVoice(_ bridge: XiaomiBluetoothBridge) {
        cancelTestToneIfNeeded(statusMessage: "RC003 语音进行中，已拒绝测试音", logReason: "voice_start")
        updateVoiceFunctionKeyState(streaming: true)
        isStreaming = true
        didRequestAudioRecoveryForCurrentStream = false
        if audioRecoveryState.hasWork {
            didRequestAudioRecoveryForCurrentStream = true
            requestAudioRecovery(reason: .streamUnavailable, delay: 0)
        } else if !audioOutput.restoreIfBound(deviceUID: settings.selectedAudioDeviceUID) {
            didRequestAudioRecoveryForCurrentStream = true
            requestAudioRecovery(reason: .streamUnavailable, delay: 0)
        }
    }

    func bluetoothBridgeDidStopVoice(_ bridge: XiaomiBluetoothBridge) {
        updateVoiceFunctionKeyState(streaming: false)
        isStreaming = false
        didRequestAudioRecoveryForCurrentStream = false
        audioOutput.endSession()
    }

    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didDecode samples: [Int16]) {
        guard !audioOutput.enqueue(samples: samples) else { return }
        guard !didRequestAudioRecoveryForCurrentStream,
              !audioOutput.isConfigured(deviceUID: settings.selectedAudioDeviceUID)
        else { return }
        didRequestAudioRecoveryForCurrentStream = true
        requestAudioRecovery(reason: .streamUnavailable, delay: 0)
        if !didRequestAudioRecoveryForCurrentStream {
            _ = audioOutput.enqueue(samples: samples)
        }
    }

    private func requestAudioRecovery(
        reason: AudioRecoveryReason,
        delay: TimeInterval = 0.3
    ) {
        guard started, !settings.selectedAudioDeviceUID.isEmpty else { return }
        let requestedDelay = isStreaming ? 0 : delay
        if audioRecoveryState.hasWork {
            mergePendingAudioRecoveryReason(reason)
            if requestedDelay == 0,
               let expedited = audioRecoveryState.expedite(delay: 0) {
                audioRecoveryWorkItem?.cancel()
                AppLogger.shared.write(
                    "AUDIO RECOVERY expedited reason=\(reason.rawValue) " +
                        "generation=\(expedited.generation)"
                )
                scheduleAudioRecovery(
                    expedited,
                    reason: pendingAudioRecoveryReason ?? reason,
                    expectedDeviceUID: settings.selectedAudioDeviceUID
                )
                if isStreaming {
                    performPendingAudioRecoveryNow(fallbackReason: reason)
                }
            }
            return
        }
        guard let schedule = audioRecoveryState.request(delay: requestedDelay) else { return }
        pendingAudioRecoveryReason = reason

        isAudioReady = false
        audioStatus = "音频环境已变化，正在恢复语音输出"
        testToneStatus = "正在重新连接语音输出设备"
        AppLogger.shared.write(
            "AUDIO RECOVERY scheduled reason=\(reason.rawValue) generation=\(schedule.generation)"
        )
        scheduleAudioRecovery(
            schedule,
            reason: reason,
            expectedDeviceUID: settings.selectedAudioDeviceUID
        )
        if isStreaming {
            performPendingAudioRecoveryNow(fallbackReason: reason)
        }
    }

    private func scheduleAudioRecovery(
        _ schedule: AudioRecoverySchedule,
        reason: AudioRecoveryReason,
        expectedDeviceUID: String
    ) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.performAudioRecovery(
                generation: schedule.generation,
                reason: reason,
                expectedDeviceUID: expectedDeviceUID
            )
        }

        audioRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + schedule.delay,
            execute: workItem
        )
    }

    private func performPendingAudioRecoveryNow(
        fallbackReason: AudioRecoveryReason
    ) {
        guard let generation = audioRecoveryState.pendingGeneration else { return }
        let reason = pendingAudioRecoveryReason ?? fallbackReason
        let expectedDeviceUID = settings.selectedAudioDeviceUID
        audioRecoveryWorkItem?.cancel()
        audioRecoveryWorkItem = nil
        performAudioRecovery(
            generation: generation,
            reason: reason,
            expectedDeviceUID: expectedDeviceUID
        )
    }

    private func performAudioRecovery(
        generation: UInt64,
        reason: AudioRecoveryReason,
        expectedDeviceUID: String
    ) {
        guard audioRecoveryState.begin(generation: generation) else { return }
        audioRecoveryWorkItem = nil
        let effectiveReason = pendingAudioRecoveryReason ?? reason
        pendingAudioRecoveryReason = nil

        guard started,
              settings.selectedAudioDeviceUID == expectedDeviceUID
        else {
            audioRecoveryState.cancel()
            return
        }

        refreshAudioDevices()
        let refreshedDevice = audioDevices.first {
            $0.uid == expectedDeviceUID
        }
        let action = AudioRecoveryPolicy.action(for: effectiveReason)
        if let refreshedDevice,
           audioOutput.restoreIfBound(
               deviceUID: expectedDeviceUID,
               expectedDeviceID: refreshedDevice.id,
               forceRestart: action == .restartBoundOutput
           ) {
            isAudioReady = true
            audioStatus = audioOutput.status
            testToneStatus = "可发送测试音"
            audioRecoveryState.succeeded()
            didRequestAudioRecoveryForCurrentStream = false
            AppLogger.shared.write(
                "AUDIO RECOVERY healthy reason=\(effectiveReason.rawValue)"
            )
            return
        }

        let recovered = configureSelectedAudioOutput(recoveryReason: effectiveReason)
        guard !recovered else {
            audioRecoveryState.succeeded()
            didRequestAudioRecoveryForCurrentStream = false
            return
        }

        guard let retry = audioRecoveryState.retry() else {
            AppLogger.shared.write(
                "AUDIO RECOVERY exhausted reason=\(effectiveReason.rawValue)"
            )
            return
        }
        pendingAudioRecoveryReason = effectiveReason
        AppLogger.shared.write(
            "AUDIO RECOVERY retry reason=\(effectiveReason.rawValue) attempt=\(retry.attempt)"
        )
        scheduleAudioRecovery(
            retry,
            reason: effectiveReason,
            expectedDeviceUID: expectedDeviceUID
        )
    }

    private func cancelScheduledAudioRecovery() {
        audioRecoveryWorkItem?.cancel()
        audioRecoveryWorkItem = nil
        pendingAudioRecoveryReason = nil
        audioRecoveryState.cancel()
    }

    private func mergePendingAudioRecoveryReason(_ reason: AudioRecoveryReason) {
        guard let current = pendingAudioRecoveryReason else {
            pendingAudioRecoveryReason = reason
            return
        }
        pendingAudioRecoveryReason = AudioRecoveryPolicy.merge(current, with: reason)
    }

    private func applyVoiceFunctionMapping() {
        let applied = voiceFunctionMapper.apply()
        guard !isStreaming else { return }
        voiceShortcutStatus = applied
            ? "遥控器语音键已硬件映射为 Fn"
            : "等待遥控器 Fn 硬件映射"
    }

    private func updateVoiceFunctionKeyState(streaming: Bool) {
        guard let transition = voiceFunctionKeyLatch.transition(streaming: streaming) else { return }
        let shouldHold = transition == .press
        voiceShortcutStatus = shouldHold
            ? "硬件 Fn 已按下；松开语音键即释放"
            : "硬件 Fn 已释放"
        AppLogger.shared.write(
            "VOICE FN HARDWARE \(shouldHold ? "DOWN" : "UP") " +
                "mapping=\(voiceFunctionMapper.isApplied)"
        )
    }
}
