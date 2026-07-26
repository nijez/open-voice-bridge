import CoreAudio
import Foundation

/// Runtime coordinator for the "compatible Mac keyboard Fn" path. It owns the
/// pure `LocalMicArbiter`, the passive `FunctionKeyMonitor`, and the
/// `LocalMicrophoneCapture` engine, and reconciles arbiter commands into real
/// capture start/stop.
///
/// RC003 always wins by using the remote's own microphone (F5) HID edge as a
/// pre-marker (`noteRemoteSource`) — the same physical press the system remaps
/// into an Fn edge — plus its ATVV stream as a second preempt source. There is
/// no fixed timing guess: the local mic only starts on a physical Fn-down while
/// no RC003 source is active, and any RC003 signal preempts immediately.
///
/// Everything runs on the main run loop: Fn edges, RC003 edges, readiness,
/// liveness, and — via a token check — the delivery of captured samples. That
/// makes local enqueue, RC003 enqueue, flush, and source switching one ordered
/// execution domain, so a preempted session's late audio-thread callbacks are
/// dropped instead of racing back into the shared output.
final class LocalMicrophoneBridge {
    struct OutputContext {
        let deviceUID: String
        let isRunning: Bool
    }

    /// Delivers normalised 16 kHz mono PCM to the shared output (BlackHole etc).
    var sampleSink: (([Int16]) -> Void)?
    /// Flushes any pending PCM already queued on the output player node.
    var flushOutput: (() -> Void)?
    /// Current output device UID + running state, read from `VirtualAudioOutput`.
    var outputContextProvider: (() -> OutputContext)?
    /// Current voice gain (dB) snapshot, applied to captured samples.
    var gainProvider: (() -> Double)?
    /// Human-readable status for the Settings UI (already de-identified).
    var onStatus: ((String) -> Void)?

    private var arbiter = LocalMicArbiter()
    private let monitor = FunctionKeyMonitor()
    private let capture = LocalMicrophoneCapture()
    private var router = LocalMicSampleRouter()

    private var enabled = false
    private var inputUID = ""
    /// Whether a healthy RC003 F5 reader (HID monitor or standalone observer) is
    /// currently supplying the remote-source pre-marker. When false the local mic
    /// path fails closed: without a reader we cannot guarantee RC003 preemption,
    /// so a physical Fn must not open the built-in microphone. Set by the
    /// coordinator from real reader health, never from the mapping checkbox.
    private var remoteReaderReady = false
    private var pendingStart: DispatchWorkItem?
    private var livenessTimer: DispatchSourceTimer?

    private(set) var status = "兼容 Mac 键盘 Fn：已关闭" {
        didSet { onStatus?(status) }
    }

    init() {
        capture.onSamples = { [weak self] samples, session in
            // Hop from the audio render thread to the ordered main domain, then
            // drop the buffer if its session is no longer active.
            DispatchQueue.main.async {
                self?.deliverLocalSamples(samples, session: session)
            }
        }
        monitor.onTransition = { [weak self] transition in
            self?.handleFunctionKey(transition)
        }
        monitor.onDisrupted = { [weak self] in
            // The monitor already re-enables its tap; here we only fail closed
            // for the interrupted cycle.
            self?.handleMonitorDisrupted(recover: false)
        }
    }

    // MARK: Configuration

    func configure(enabled: Bool, inputUID: String) {
        self.inputUID = inputUID
        setEnabled(enabled)
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if on {
            if !monitor.isRunning {
                _ = monitor.start()
            }
            apply(arbiter.handle(.setEnabled(true)), reason: "enabled")
            startLivenessTimer()
            updateReadiness()
            AppLogger.shared.write("LOCAL MIC ENABLED enabled=true monitor=\(monitor.isRunning)")
        } else {
            apply(arbiter.handle(.setEnabled(false)), reason: "disabled")
            stopLivenessTimer()
            monitor.stop()
            updateReadiness()
            status = "兼容 Mac 键盘 Fn：已关闭"
            AppLogger.shared.write("LOCAL MIC ENABLED enabled=false")
        }
    }

    func setInputUID(_ uid: String) {
        guard uid != inputUID else { return }
        inputUID = uid
        // Drop any in-flight capture bound to the previous input; the next Fn
        // press re-opens with the new source.
        forceStopCapture(reason: "input_changed")
    }

    /// Reports whether a healthy RC003 F5 reader is currently available. When it
    /// drops to false any in-flight capture is stopped and further physical Fn
    /// presses are refused (fail closed) until a reader recovers.
    func setRemoteSourceReaderReady(_ ready: Bool) {
        guard ready != remoteReaderReady else { return }
        remoteReaderReady = ready
        updateReadiness()
    }

    /// Recompute readiness after output-device, permission, or device-topology
    /// changes. Also refreshes the visible status.
    func refreshReadiness() {
        updateReadiness()
    }

    /// RC003 ATVV voice-stream boundary — second, independent preempt source.
    func noteRemoteVoice(active: Bool) {
        if active {
            apply(arbiter.handle(.remoteVoiceStart), reason: "remote_preempt")
        } else {
            apply(arbiter.handle(.remoteVoiceStop), reason: "remote_stop")
        }
    }

    /// RC003 microphone (F5) HID edge — the reliable remote-source pre-marker.
    func noteRemoteSource(_ edge: RemoteEventEdge) {
        switch edge {
        case .down:
            apply(arbiter.handle(.remoteSourceDown), reason: "remote_source_down")
        case .up:
            apply(arbiter.handle(.remoteSourceUp), reason: "remote_source_up")
        }
    }

    func teardown() {
        pendingStart?.cancel()
        pendingStart = nil
        stopLivenessTimer()
        router.invalidate()
        apply(arbiter.handle(.teardown), reason: "teardown")
        monitor.stop()
        capture.stop()
        enabled = false
    }

    var isCapturing: Bool { capture.isCapturing }

    // MARK: Event plumbing

    private func handleFunctionKey(_ transition: VoiceFunctionKeyTransition) {
        switch transition {
        case .press:
            apply(arbiter.handle(.physicalFnDown), reason: "fn_down")
        case .release:
            apply(arbiter.handle(.physicalFnUp), reason: "fn_up")
        }
    }

    private func handleMonitorDisrupted(recover: Bool) {
        apply(arbiter.handle(.functionMonitorDisrupted), reason: "fn_monitor_disrupted")
        if recover {
            monitor.stop()
            _ = monitor.start()
        }
        updateReadiness()
        AppLogger.shared.write(
            "LOCAL MIC FN_MONITOR disrupted recover=\(recover) running=\(monitor.isRunning)"
        )
    }

    private func apply(_ command: LocalMicCommand, reason: String) {
        switch command {
        case .none:
            break
        case .startCapture:
            scheduleStart()
        case .stopCapture:
            stopActiveCapture(reason: reason)
        }
    }

    private func scheduleStart() {
        pendingStart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.beginCapture()
        }
        pendingStart = work
        status = "兼容 Mac 键盘 Fn：本机麦克风准备中"
        // Yield the run loop once (no fixed delay). This lets a causally-earlier
        // RC003 F5 HID report — dispatched to main from the same physical press
        // that the system remaps into this Fn edge — mark the remote source and
        // preempt (cancelling this work item) before the mic engine ever opens.
        DispatchQueue.main.async(execute: work)
    }

    private func beginCapture() {
        pendingStart = nil
        if let block = fullBlock(captureEngineHealthy: true) {
            apply(arbiter.handle(.setReady(false)), reason: "not_ready_at_start")
            AppLogger.shared.write("LOCAL MIC START aborted=\(block)")
            updateReadiness()
            return
        }

        let deviceID: AudioDeviceID?
        if inputUID.isEmpty {
            deviceID = nil
        } else if let found = CoreAudioDeviceCatalog.inputDevices().first(where: { $0.uid == inputUID }) {
            deviceID = found.id
        } else {
            apply(arbiter.handle(.setReady(false)), reason: "input_missing")
            AppLogger.shared.write("LOCAL MIC START aborted=inputMissing")
            updateReadiness()
            return
        }

        let gain = gainProvider?() ?? 0
        let session = router.begin()
        if capture.start(inputDeviceID: deviceID, gainDB: gain, session: session) {
            status = "兼容 Mac 键盘 Fn：本机麦克风采集中（松开 Fn 结束）"
            AppLogger.shared.write("LOCAL MIC CAPTURE start source=\(inputUID.isEmpty ? "default" : "selected")")
        } else {
            router.invalidate()
            apply(arbiter.handle(.setReady(false)), reason: "engine_failed")
            AppLogger.shared.write("LOCAL MIC CAPTURE start_failed=\(capture.lastError ?? "unknown")")
            status = "兼容 Mac 键盘 Fn：无法启动麦克风，已停止"
            updateReadiness()
        }
    }

    private func deliverLocalSamples(_ samples: [Int16], session: UInt64) {
        guard router.accepts(session) else { return }
        sampleSink?(samples)
    }

    private func stopActiveCapture(reason: String) {
        pendingStart?.cancel()
        pendingStart = nil
        // Invalidate the session first so any main-queued sample from the audio
        // thread is dropped before we flush and (maybe) RC003 takes over.
        router.invalidate()
        if capture.isCapturing {
            capture.stop()
            flushOutput?()
            AppLogger.shared.write("LOCAL MIC CAPTURE stop reason=\(reason)")
        }
        if enabled {
            status = arbiter.remoteActive
                ? "兼容 Mac 键盘 Fn：RC003 语音优先，本机麦克风已让出"
                : "兼容 Mac 键盘 Fn：就绪，按住物理 Fn 使用本机麦克风"
        }
    }

    private func forceStopCapture(reason: String) {
        apply(arbiter.handle(.setReady(false)), reason: reason)
        updateReadiness()
    }

    // MARK: Readiness & liveness

    private func updateReadiness() {
        let block = fullBlock(captureEngineHealthy: true)
        apply(arbiter.handle(.setReady(block == nil)), reason: "readiness")
        if enabled, !capture.isCapturing {
            status = statusText(for: block)
        }
    }

    private func startLivenessTimer() {
        stopLivenessTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.livenessTick()
        }
        livenessTimer = timer
        timer.resume()
    }

    private func stopLivenessTimer() {
        livenessTimer?.cancel()
        livenessTimer = nil
    }

    /// Runs while the feature is enabled. Catches conditions that arrive without
    /// an explicit event: mic permission revoked, output/input device removed,
    /// the system default input becoming the output device, the capture engine
    /// dying, or the Fn tap being silently disabled — all fail closed.
    private func livenessTick() {
        guard enabled else {
            stopLivenessTimer()
            return
        }
        if !monitor.isRunning || !monitor.isTapEnabled {
            handleMonitorDisrupted(recover: true)
            return
        }
        if capture.isCapturing {
            if let block = fullBlock(captureEngineHealthy: capture.engineIsHealthy) {
                stopActiveCapture(reason: "liveness_\(block)")
                apply(arbiter.handle(.setReady(false)), reason: "liveness")
                updateReadiness()
            }
            return
        }
        // Idle: a cheap permission/monitor check only. The full device + loop
        // re-check runs at the next capture start and on event-driven refreshes.
        if let block = lightBlock() {
            apply(arbiter.handle(.setReady(false)), reason: "liveness_idle")
            status = statusText(for: block)
        }
    }

    private func fullBlock(captureEngineHealthy: Bool) -> LocalMicBlock? {
        let output = outputContextProvider?() ?? OutputContext(deviceUID: "", isRunning: false)
        return LocalMicGate.block(
            enabled: enabled,
            micAuthorized: MicrophonePermission.status.isAuthorized,
            fnMonitorRunning: monitor.isRunning && monitor.isTapEnabled,
            remoteSourceReaderReady: remoteReaderReady,
            outputRunning: output.isRunning,
            outputUID: output.deviceUID,
            resolvedInputUID: resolvedInputUID(),
            captureEngineHealthy: captureEngineHealthy
        )
    }

    private func lightBlock() -> LocalMicBlock? {
        guard enabled else { return .disabled }
        guard MicrophonePermission.status.isAuthorized else { return .micPermission }
        guard monitor.isRunning, monitor.isTapEnabled else { return .fnMonitor }
        guard remoteReaderReady else { return .remoteReader }
        return nil
    }

    private func resolvedInputUID() -> String? {
        if inputUID.isEmpty {
            return CoreAudioDeviceCatalog.defaultInputDeviceUID()
        }
        return CoreAudioDeviceCatalog.inputDevices().contains { $0.uid == inputUID } ? inputUID : nil
    }

    private func statusText(for block: LocalMicBlock?) -> String {
        guard enabled else { return "兼容 Mac 键盘 Fn：已关闭" }
        switch block {
        case .none:
            return "兼容 Mac 键盘 Fn：就绪，按住物理 Fn 使用本机麦克风"
        case .disabled:
            return "兼容 Mac 键盘 Fn：已关闭"
        case .micPermission:
            return "兼容 Mac 键盘 Fn：需要麦克风权限"
        case .fnMonitor:
            return "兼容 Mac 键盘 Fn：需要输入监控权限以监听物理 Fn"
        case .remoteReader:
            return "兼容 Mac 键盘 Fn：暂无法读取遥控器语音键，已暂停以确保遥控器优先"
        case .outputMissing:
            return "兼容 Mac 键盘 Fn：请先在上方选择语音输出设备"
        case .inputMissing:
            return "兼容 Mac 键盘 Fn：所选输入设备不可用"
        case .sameDevice:
            return "兼容 Mac 键盘 Fn：输入与输出为同一设备，已停用以避免回声"
        case .captureEngine:
            return "兼容 Mac 键盘 Fn：麦克风采集已停止"
        }
    }
}
