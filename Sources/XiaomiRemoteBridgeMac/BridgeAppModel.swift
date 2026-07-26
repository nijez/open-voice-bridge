import AppKit
import Combine
import Foundation

final class BridgeAppModel: ObservableObject, XiaomiBluetoothBridgeDelegate {
    let settings = AppSettings()
    let launchAtLoginManager = LaunchAtLoginManager.shared
    /// Read-only cross-platform catalog. Phase 0 deliberately does not feed
    /// this into the live RC003/DJI adapter selection or connection path.
    let deviceProfileCatalog = DeviceProfileCatalog.loadBundled()

    @Published private(set) var connectionStatus = "正在初始化蓝牙"
    @Published private(set) var hidStatus = "按键映射未启用"
    @Published private(set) var audioStatus = "未选择语音输出设备"
    @Published private(set) var isStreaming = false
    @Published private(set) var audioDevices: [AudioDeviceInfo] = []
    @Published private(set) var audioInputDevices: [AudioDeviceInfo] = []
    @Published private(set) var testToneStatus = "未选择语音输出设备"
    @Published private(set) var isPlayingTestTone = false
    /// An event-scoped UI snapshot of the audio boundaries this application can
    /// actually observe. It intentionally contains no claim about input-method
    /// consumption or text insertion, and it is never refreshed repeatedly while
    /// the RC003 voice path is idle.
    @Published private(set) var audioPathSnapshot = AudioPathSnapshot.empty
    @Published private(set) var voiceShortcutStatus = "正在准备遥控器 Fn 硬件映射"
    @Published private(set) var localMicStatus = "兼容 Mac 键盘 Fn：已关闭"
    @Published private(set) var microphonePermission: MicrophoneAuthorization = .notDetermined
    /// Non-`.none` asks the app delegate to show an explicit setup reminder.
    /// macOS alone can grant these TCC permissions; this app can only guide the
    /// user to the correct system page and restart its HID pipeline afterwards.
    @Published private(set) var pendingHIDPermissionReminder: HIDPermissionRequest = .none
    /// Runtime bridge on/off state. Defaults to enabled on every launch and is
    /// intentionally NOT persisted, so a forgotten "off" can never look like a
    /// broken device after a restart.
    @Published private(set) var bridgeEnabled = true
    @Published private(set) var bridgeRuntimeStatus = "桥接已启用"
    @Published private(set) var detectedXiaomiModelNumber: String?

    var djiMic2Status: String {
        audioInputDevices.contains { ExternalMicrophoneProfile.isDJIMic2(displayName: $0.name) }
            ? "已发现 DJI Mic 2 系统输入，可直接作为麦克风使用"
            : "未发现 DJI Mic 2 音频输入（仅蓝牙配对不代表已连接）"
    }

    var djiMic2InputDevices: [AudioDeviceInfo] {
        audioInputDevices.filter { ExternalMicrophoneProfile.isDJIMic2(displayName: $0.name) }
    }

    private let audioPathDiagnostics = AudioPathDiagnostics()
    private lazy var audioOutput = VirtualAudioOutput(diagnostics: audioPathDiagnostics)
    /// The diagnostics are intentionally scoped to a live RC003 voice stream.
    /// Local physical-Fn audio shares the output node but never affects these
    /// remote PCM / queue / playback indicators.
    private var remoteAudioDiagnosticsSession: AudioPathDiagnostics.Session?
    private let voiceFunctionMapper = RemoteVoiceFunctionMapper()
    private let localMicBridge = LocalMicrophoneBridge()
    private let remoteVoiceKeyMonitor = RemoteVoiceKeyMonitor()
    private var testToneGeneration = 0
    /// Tracks a real TCC loss across the trip to System Settings. This lets us
    /// reopen the HID manager exactly once when both grants return, instead of
    /// restarting it every time the app merely becomes active.
    private var hidPermissionsWereMissing = false
    /// A privacy pane can return focus before macOS refreshes its TCC decision.
    /// Do not repeatedly interrupt the user with the same setup alert in one
    /// launch; the next launch always rechecks it from scratch.
    private var suppressedHIDPermissionReminderForCurrentLaunch: HIDPermissionRequest?
    private var voiceFunctionKeyLatch = VoiceFunctionKeyLatch()
    /// Recognises the RC003 voice-key double-click that toggles the bridge. It only
    /// observes the single voice-key edge stream, so it never delays hold-to-talk.
    private var toggleDetector = RemoteBridgeToggleGestureDetector()
    /// True when the last disable could not restore the F5→Fn system mapping, so
    /// the bridge stays in a failed-disabled state with a visible warning.
    private var mappingRestoreFailed = false
    private lazy var bluetoothBridge = XiaomiBluetoothBridge(settings: settings, delegate: self)
    private lazy var hidMonitor: HIDRemoteMonitor = {
        let monitor = HIDRemoteMonitor(settings: settings)
        monitor.onStatus = { [weak self] value in
            self?.hidStatus = value
        }
        // When custom mapping is ON this monitor already reads the RC003 device,
        // so it supplies the microphone-key edge (the standalone observer stays
        // off to avoid double-opening / contending with its seize). The edge feeds
        // both the local-mic pre-marker and the double-click bridge toggle.
        monitor.onVoiceKeyEdge = { [weak self] edge in
            self?.handleRemoteVoiceKeyEdge(edge)
        }
        // A forced balancing `.up` or an adopted-device generation change from this
        // reader must drop only the in-flight double-click, synchronously and BEFORE
        // the balancing `.up` arrives — so a synthetic `.up` cannot falsely toggle
        // the bridge while the local-mic arbiter still receives that `.up`.
        monitor.onGestureInvalidate = { [weak self] in
            self?.handleReaderLifecycleInvalidation()
        }
        // Re-select the single F5 reader whenever the HID monitor actually starts
        // or stops reading (open success, permission revocation, teardown), so the
        // choice tracks real reader health at runtime, not the mapping checkbox.
        monitor.onReaderHealthChange = { [weak self] in
            self?.updateRemoteVoiceKeyObservation()
        }
        return monitor
    }()
    private var started = false
    private var activeDeviceProfile: MacDeviceProfile?
    private var terminationObserver: NSObjectProtocol?
    private lazy var audioDiagnosticsRefreshController = AudioDiagnosticsRefreshController {
        [weak self] in self?.refreshAudioPathSnapshot()
    }

    func reconcileLaunchAtLogin() {
        launchAtLoginManager.apply(desiredEnabled: settings.launchAtLoginEnabled)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        settings.launchAtLoginEnabled = enabled
        launchAtLoginManager.apply(desiredEnabled: enabled)
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginManager.refreshStatus()
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        refreshAudioDevices()
        refreshMicrophonePermission()
        activeDeviceProfile = settings.selectedDeviceProfile
        switch settings.selectedDeviceProfile {
        case .xiaomiRC003:
            configureLocalMicBridge()
            applyAudioSettings()
            localMicBridge.configure(
                enabled: settings.localFnMicEnabled,
                inputUID: settings.localMicInputUID
            )
            hidStatus = "等待识别遥控器型号"
            voiceShortcutStatus = "等待识别遥控器型号"
            localMicBridge.setRemoteSourceReaderReady(false)
            bluetoothBridge.start()
        case .djiMic2:
            connectionStatus = djiMic2Status
            hidStatus = "DJI Mic 2 无可用的 macOS HID 按键映射"
            audioStatus = "由 macOS 系统输入直接管理"
            voiceShortcutStatus = "不注入 RC003 Fn 映射"
            localMicStatus = "DJI Mic 2 独立设备模式"
        }
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
        cancelTestToneIfNeeded(statusMessage: "应用已停止", logReason: "app_stop")
        // Drop any in-flight double-click so a late edge cannot complete an old
        // toggle across teardown.
        toggleDetector.reset()
        if activeDeviceProfile == .xiaomiRC003 {
            remoteVoiceKeyMonitor.stop()
            localMicBridge.teardown()
            bluetoothBridge.stop()
            updateVoiceFunctionKeyState(streaming: false)
            hidMonitor.stop()
            resetRemoteAudioDiagnostics()
            audioOutput.stop()
            voiceFunctionMapper.restore()
        }
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        started = false
        activeDeviceProfile = nil
        AppLogger.shared.write("APP STOP")
    }

    func selectDeviceProfile(_ profile: MacDeviceProfile) {
        guard profile != settings.selectedDeviceProfile else { return }
        let wasStarted = started
        if wasStarted { stop() }
        settings.selectedDeviceProfile = profile
        bridgeEnabled = true
        mappingRestoreFailed = false
        if wasStarted { startIfNeeded() }
        AppLogger.shared.write("DEVICE PROFILE selected=\(profile.rawValue)")
    }

    func reconnect() {
        guard settings.selectedDeviceProfile == .xiaomiRC003 else {
            refreshAudioDevices()
            connectionStatus = djiMic2Status
            return
        }
        bluetoothBridge.reconnectNow()
    }

    func refreshAudioDevices() {
        audioDevices = CoreAudioDeviceCatalog.outputDevices()
        audioInputDevices = CoreAudioDeviceCatalog.inputDevices()
    }

    func applyAudioSettings() {
        cancelTestToneIfNeeded(statusMessage: "设备已更新，测试音已取消", logReason: "device_reconfigure")
        resetRemoteAudioDiagnostics()
        _ = audioOutput.configure(deviceUID: settings.selectedAudioDeviceUID)
        audioStatus = audioOutput.status
        testToneStatus = audioOutput.isReadyForTestTone
            ? "可发送测试音"
            : "未选择语音输出设备或设备不可用"
        localMicBridge.refreshReadiness()
    }

    // MARK: Local Mac-keyboard Fn microphone compatibility

    private func configureLocalMicBridge() {
        localMicBridge.sampleSink = { [weak self] samples in
            self?.audioOutput.enqueue(samples: samples)
        }
        localMicBridge.flushOutput = { [weak self] in
            self?.audioOutput.flushPending()
        }
        localMicBridge.outputContextProvider = { [weak self] in
            let output = self?.audioOutput.currentOutput
            return LocalMicrophoneBridge.OutputContext(
                deviceUID: output?.uid ?? "",
                isRunning: output?.isRunning ?? false
            )
        }
        localMicBridge.gainProvider = { [weak self] in
            self?.settings.gainDB ?? 0
        }
        localMicBridge.onStatus = { [weak self] value in
            self?.localMicStatus = value
        }
        remoteVoiceKeyMonitor.onVoiceKeyEdge = { [weak self] edge in
            self?.handleRemoteVoiceKeyEdge(edge)
        }
        // Same forced-release/generation-change contract as the HID reader: reset
        // only the toggle detector, synchronously and before the balancing `.up`.
        remoteVoiceKeyMonitor.onGestureInvalidate = { [weak self] in
            self?.handleReaderLifecycleInvalidation()
        }
        // Re-select the reader and re-push readerReady whenever the standalone
        // observer's health flips from a source the coordinator did not drive: a
        // match open-failure, a device removal that clears an unreadable block, or
        // a runtime Input Monitoring revoke/restore. This is what makes a runtime
        // revocation fail the local mic closed even if the Fn monitor recovers
        // independently, and lets a genuine reopen re-admit it.
        remoteVoiceKeyMonitor.onReaderHealthChange = { [weak self] in
            self?.updateRemoteVoiceKeyObservation()
        }
    }

    /// Selects the single RC003 microphone-key (F5) pre-marker reader from the HID
    /// monitor's *actual* reading state — never from the `customMappingEnabled`
    /// checkbox. When `hidMonitor` is truly open and reading (custom mapping ON
    /// with permissions granted) it supplies the edge and the standalone observer
    /// stays off (no double-open, no seize contention). Otherwise — custom mapping
    /// off, or on but the HID monitor is not actually reading (first install
    /// without Accessibility, runtime revocation, HID open failure) — the
    /// standalone non-seize observer is the fallback reader. `readerReady` is the
    /// selected reader's real *health* (for the standalone: observing AND Input
    /// Monitoring granted AND no unreadable device), not a bare "manager open"
    /// bool — so a match failure or runtime revoke pushes `readerReady=false` and
    /// fails the local mic closed. Re-run whenever the feature toggles, mapping
    /// changes, or either monitor's health flips; it only reads HID health and
    /// starts/stops the standalone reader (never calls back into `HIDRemoteMonitor`
    /// or self-notifies from those calls), so it does not recurse unboundedly.
    private func updateRemoteVoiceKeyObservation() {
        // A reader re-selection or health flip can drop edges mid-gesture, so clear
        // any in-flight double-click here: a stale edge (reader unhealthy, device
        // generation change, permission loss) must never complete an old toggle.
        toggleDetector.reset()
        let hidReading = hidMonitor.isReadingRemoteKeys
        let target = RemoteSourceReaderPolicy.targetReader(
            localFnMicEnabled: settings.localFnMicEnabled,
            doubleClickEnabled: settings.doubleClickToggleEnabled,
            hidMonitorReading: hidReading
        )
        switch target {
        case .none, .hidMonitor:
            // Feature off, or the HID monitor already owns the device: the
            // standalone observer must be off so exactly one reader is live.
            remoteVoiceKeyMonitor.stop()
        case .standalone:
            // Start only when not already observing. A match-failure or
            // permission-revoke unhealthy state keeps the observer *observing*, so
            // this guard cannot restart it in a loop — health drives readerReady
            // below, and the observer self-heals (device removal / permission
            // reopen) and re-notifies.
            if !remoteVoiceKeyMonitor.isObserving {
                _ = remoteVoiceKeyMonitor.start()
            }
        }
        let ready = RemoteSourceReaderPolicy.readerReady(
            target: target,
            hidMonitorReading: hidReading,
            standaloneHealthy: remoteVoiceKeyMonitor.isHealthy
        )
        localMicBridge.setRemoteSourceReaderReady(ready)
        // Refresh the disabled-bridge suppression hint: whether ordinary keys are
        // fully suppressed depends on the reader's exclusive (seize) state, which
        // this re-selection may have changed.
        updateBridgeRuntimeStatus()
    }

    func setLocalFnMicEnabled(_ enabled: Bool) {
        settings.localFnMicEnabled = enabled
        refreshMicrophonePermission()
        localMicBridge.setEnabled(enabled)
        if enabled {
            // Re-sync the ATVV preempt state in case RC003 is already streaming.
            localMicBridge.noteRemoteVoice(active: isStreaming)
        }
        updateRemoteVoiceKeyObservation()
    }

    func setLocalMicInput(_ uid: String) {
        settings.localMicInputUID = uid
        localMicBridge.setInputUID(uid)
    }

    // MARK: RC003 voice-key double-click bridge toggle

    /// The single sink for the RC003 voice-key (F5) edge from whichever reader is
    /// active. It feeds the local-mic pre-marker (RC003 priority — unchanged by the
    /// bridge switch, so physical-Fn behaviour is unaffected) and the double-click
    /// detector. The detector only *observes* the edge, so hold-to-talk voice
    /// startup keeps its original latency — no waiting for a possible second tap.
    private func handleRemoteVoiceKeyEdge(_ edge: RemoteEventEdge) {
        localMicBridge.noteRemoteSource(edge)
        guard settings.doubleClickToggleEnabled else { return }
        if toggleDetector.handle(edge, nowMs: Self.monotonicMillis()) {
            setBridgeEnabled(!bridgeEnabled, source: "double_click")
        }
    }

    /// Invoked synchronously by either reader on a forced balancing `.up` or an
    /// adopted-device generation change (successful match / removal), AFTER the
    /// reader has updated its `activeDevice` / seize state. It (1) resets ONLY the
    /// toggle detector — kept first so a synthetic `.up` that follows cannot toggle —
    /// and (2) refreshes `bridgeRuntimeStatus`, whose disabled-state native-key
    /// warning depends on the reader's exclusive/monitored mode. That mode can flip
    /// on reconnect WITHOUT a reader-health flip (so `updateRemoteVoiceKeyObservation`
    /// is not called), which would otherwise leave a disabled bridge showing a stale
    /// status that falsely omits the warning. It only reads reader state and sets a
    /// status string — it never restarts or re-selects a reader, so it cannot recurse.
    private func handleReaderLifecycleInvalidation() {
        toggleDetector.reset()
        updateBridgeRuntimeStatus()
    }

    func setDoubleClickToggleEnabled(_ enabled: Bool) {
        settings.doubleClickToggleEnabled = enabled
        toggleDetector.reset()
        // The reader may now be needed (or no longer needed) purely for gestures.
        updateRemoteVoiceKeyObservation()
    }

    /// Explicit toggle used by the Settings button and the menu bar — a
    /// double-click-free recovery path.
    func toggleBridgeEnabled(source: String) {
        setBridgeEnabled(!bridgeEnabled, source: source)
    }

    func setBridgeEnabled(_ enabled: Bool, source: String) {
        guard enabled != bridgeEnabled else { return }
        bridgeEnabled = enabled
        toggleDetector.reset()
        applyBridgeRuntimeState(source: source)
    }

    /// Reconciles every subsystem to the current runtime state. Disabling gates
    /// voice, suppresses HID actions, cleans up any in-flight voice/latch/arbiter/
    /// audio state, and restores the F5 system mapping; enabling reverses this and
    /// re-applies the F5→Fn mapping only when the health gate (device present) is met.
    private func applyBridgeRuntimeState(source: String) {
        if bridgeEnabled {
            mappingRestoreFailed = false
            hidMonitor.setActionsSuppressed(false)
            bluetoothBridge.setVoiceBridgingEnabled(true)
            // Re-apply F5→Fn only if the health gate is satisfied; apply() matches
            // no service (and stays "waiting") when the device is absent.
            applyVoiceFunctionMapping()
        } else {
            hidMonitor.setActionsSuppressed(true)
            // Stops any active stream and closes the mic; the delegate stop path
            // clears isStreaming, releases the Fn latch, and flushes the output.
            bluetoothBridge.setVoiceBridgingEnabled(false)
            // Deliver the remote release/stop to the local-mic arbiter without
            // disabling the user's separate physical-Fn compatibility feature.
            localMicBridge.noteRemoteVoice(active: false)
            localMicBridge.noteRemoteSource(.up)
            // Explicitly release the hardware Fn latch and restore F5's system
            // mapping so the remote no longer injects Fn/Globe while disabled.
            updateVoiceFunctionKeyState(streaming: false)
            mappingRestoreFailed = !voiceFunctionMapper.restore()
            // Flush any residual PCM already queued on the output.
            resetRemoteAudioDiagnostics()
        }
        updateBridgeRuntimeStatus()
        AppLogger.shared.write(
            "BRIDGE RUNTIME enabled=\(bridgeEnabled) source=\(source) " +
                "restore_ok=\(!mappingRestoreFailed)"
        )
    }

    private func updateBridgeRuntimeStatus() {
        let value = BridgeRuntimeStatusText.text(
            enabled: bridgeEnabled,
            mappingRestoreFailed: mappingRestoreFailed,
            customMappingEnabled: settings.customMappingEnabled,
            exclusivelyReading: hidMonitor.isExclusivelyReading
        )
        if bridgeRuntimeStatus != value { bridgeRuntimeStatus = value }
    }

    private static func monotonicMillis() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    func refreshMicrophonePermission() {
        microphonePermission = MicrophonePermission.status
    }

    func requestMicrophonePermission() {
        let current = MicrophonePermission.status
        guard current == .notDetermined else {
            // Already decided: the system will not reprompt, so send the user to
            // the microphone privacy pane instead of silently doing nothing.
            refreshMicrophonePermission()
            if current != .authorized {
                openPrivacyPane("Privacy_Microphone")
            }
            return
        }
        MicrophonePermission.request { [weak self] granted in
            guard let self else { return }
            self.microphonePermission = MicrophonePermission.status
            self.localMicBridge.refreshReadiness()
            AppLogger.shared.write("LOCAL MIC PERMISSION granted=\(granted)")
        }
    }

    var canSendTestTone: Bool {
        TestToneGate.canPlay(
            hasSelectedDevice: audioOutput.isReadyForTestTone,
            isStreaming: isStreaming,
            isPlaying: isPlayingTestTone
        )
    }

    func sendTestTone() {
        guard TestToneGate.canPlay(
            hasSelectedDevice: audioOutput.isReadyForTestTone,
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
        guard let modelNumber = detectedXiaomiModelNumber,
              XiaomiRemoteVariant.detected(fromModelNumber: modelNumber) != nil
        else {
            remoteVoiceKeyMonitor.stop()
            hidMonitor.stop()
            localMicBridge.setRemoteSourceReaderReady(false)
            hidStatus = "等待识别遥控器型号"
            return
        }
        requestNextHIDPermissionIfNeeded()
        // Release the standalone observer first so it never holds the RC003
        // device while HIDRemoteMonitor (re)opens and may seize it. The observer
        // is then restarted only if custom mapping is now off (device is free).
        remoteVoiceKeyMonitor.stop()
        hidMonitor.start()
        // A restart re-opens the monitor with actions un-gated; re-assert the
        // current runtime gate so a disabled bridge keeps suppressing injection.
        hidMonitor.setActionsSuppressed(!bridgeEnabled)
        hidStatus = hidMonitor.status
        updateRemoteVoiceKeyObservation()
    }

    /// Re-evaluates permissions after launch and after the user returns from
    /// System Settings. A locally re-signed update can make macOS revoke either
    /// grant, so never assume a previously saved choice remains usable.
    func refreshHIDPermissionReminder() {
        guard settings.selectedDeviceProfile == .xiaomiRC003,
              settings.customMappingEnabled
        else {
            pendingHIDPermissionReminder = .none
            hidPermissionsWereMissing = false
            suppressedHIDPermissionReminderForCurrentLaunch = nil
            return
        }
        let request = HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: settings.customMappingEnabled,
            inputMonitoringGranted: HIDRemoteMonitor.isInputMonitoringGranted,
            accessibilityGranted: KeyboardInjector.isAccessibilityTrusted
        )
        if request != .none {
            hidPermissionsWereMissing = true
            pendingHIDPermissionReminder = request == suppressedHIDPermissionReminderForCurrentLaunch
                ? .none
                : request
        } else {
            pendingHIDPermissionReminder = .none
            suppressedHIDPermissionReminderForCurrentLaunch = nil
            guard hidPermissionsWereMissing else { return }
            hidPermissionsWereMissing = false
            // A permission change takes effect only after the HID manager is
            // reopened, so recover automatically when the user returns.
            applyHIDSettings()
        }
    }

    func dismissHIDPermissionReminder() {
        suppressedHIDPermissionReminderForCurrentLaunch = pendingHIDPermissionReminder
        pendingHIDPermissionReminder = .none
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

    func openSoundInputSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Sound-Settings.extension?input",
            "x-apple.systempreferences:com.apple.preference.sound?input",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
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
        guard settings.selectedDeviceProfile == .xiaomiRC003 else { return }
        if case .ready = state {
            // Keep the model reported during this connection's service discovery.
        } else {
            detectedXiaomiModelNumber = nil
            remoteVoiceKeyMonitor.stop()
            hidMonitor.stop()
            localMicBridge.setRemoteSourceReaderReady(false)
            updateVoiceFunctionKeyState(streaming: false)
            _ = voiceFunctionMapper.restore()
            hidStatus = "等待识别遥控器型号"
            voiceShortcutStatus = "等待识别遥控器型号"
        }
        connectionStatus = state.displayText
        if case .ready = state {
            applyVoiceFunctionMapping()
        }
    }

    func bluetoothBridge(
        _ bridge: XiaomiBluetoothBridge,
        didDetectModelNumber modelNumber: String
    ) {
        guard settings.selectedDeviceProfile == .xiaomiRC003 else { return }
        let normalized = modelNumber
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        detectedXiaomiModelNumber = normalized
        if let detectedVariant = XiaomiRemoteVariant.detected(fromModelNumber: normalized) {
            settings.xiaomiRemoteVariant = detectedVariant
            applyHIDSettings()
            refreshHIDPermissionReminder()
        }
    }

    func bluetoothBridgeDidStartVoice(_ bridge: XiaomiBluetoothBridge) {
        guard settings.selectedDeviceProfile == .xiaomiRC003 else { return }
        // RC003 always wins: stop any local-mic capture before the remote PCM
        // starts flowing to the shared output.
        localMicBridge.noteRemoteVoice(active: true)
        cancelTestToneIfNeeded(statusMessage: "RC003 语音进行中，已拒绝测试音", logReason: "voice_start")
        remoteAudioDiagnosticsSession = audioPathDiagnostics.beginSession()
        audioDiagnosticsRefreshController.beginActiveSession()
        updateVoiceFunctionKeyState(streaming: true)
        isStreaming = true
    }

    func bluetoothBridgeDidStopVoice(_ bridge: XiaomiBluetoothBridge) {
        guard settings.selectedDeviceProfile == .xiaomiRC003 else { return }
        updateVoiceFunctionKeyState(streaming: false)
        isStreaming = false
        endRemoteAudioDiagnosticsSession()
        localMicBridge.noteRemoteVoice(active: false)
    }

    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didDecode samples: [Int16]) {
        guard settings.selectedDeviceProfile == .xiaomiRC003 else { return }
        guard let session = remoteAudioDiagnosticsSession else { return }
        audioPathDiagnostics.recordDecoded(samples: samples, for: session)
        audioOutput.enqueue(samples: samples, diagnosticsSession: session)
    }

    private func endRemoteAudioDiagnosticsSession() {
        guard let session = remoteAudioDiagnosticsSession else {
            audioOutput.flushPending()
            return
        }
        remoteAudioDiagnosticsSession = nil
        audioOutput.endSession(diagnosticsSession: session)
        audioDiagnosticsRefreshController.endActiveSession()
    }

    private func resetRemoteAudioDiagnostics() {
        remoteAudioDiagnosticsSession = nil
        audioDiagnosticsRefreshController.reset(refreshNow: false)
        audioPathDiagnostics.reset()
        audioOutput.flushPending()
        refreshAudioPathSnapshot()
    }

    private func refreshAudioPathSnapshot() {
        let snapshot = audioPathDiagnostics.snapshot()
        guard snapshot != audioPathSnapshot else { return }
        audioPathSnapshot = snapshot
    }

    private func applyVoiceFunctionMapping() {
        // While the bridge is disabled the F5 key must stay native (its system
        // mapping was restored on disable); do not re-map it even if the device
        // (re)connects. Re-enabling re-applies the mapping through this same path.
        guard bridgeEnabled,
              let modelNumber = detectedXiaomiModelNumber,
              XiaomiRemoteVariant.detected(fromModelNumber: modelNumber) != nil
        else { return }
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
