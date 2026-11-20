import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct AudioDeviceInfo: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum CoreAudioDeviceCatalog {
    static func outputDevices() -> [AudioDeviceInfo] {
        devices(scope: kAudioDevicePropertyScopeOutput)
    }

    static func inputDevices() -> [AudioDeviceInfo] {
        devices(scope: kAudioDevicePropertyScopeInput)
    }

    /// UID of the current system default input device, or `nil` if none is set.
    /// Read only — the app never changes the system default input.
    static func defaultInputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != 0 else { return nil }
        return stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func devices(scope: AudioObjectPropertyScope) -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard channelCount(for: deviceID, scope: scope) > 0,
                  let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(deviceID, selector: kAudioObjectPropertyName)
            else { return nil }
            return AudioDeviceInfo(id: deviceID, uid: uid, name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func stringProperty(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }

    private static func channelCount(
        for deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size)
        else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let bufferList = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

final class VirtualAudioOutput {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let diagnostics: AudioPathDiagnostics
    private let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private(set) var selectedDevice: AudioDeviceInfo?
    private(set) var status = "未选择语音输出设备"

    /// UID the caller asked for, kept so a dead engine can be rebuilt on the same
    /// device after CoreAudio renumbers or drops it.
    private var configuredDeviceUID = ""
    private var configurationObserver: NSObjectProtocol?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var recoveryPolicy = AudioOutputRecoveryPolicy()
    private var recoveryWork: DispatchWorkItem?
    private var isRebuilding = false
    private let stallLock = NSLock()
    private var stalledReported = false

    init(diagnostics: AudioPathDiagnostics = AudioPathDiagnostics()) {
        self.diagnostics = diagnostics
    }

    /// Current output routing, used by the local-microphone feedback-loop guard.
    var currentOutput: (uid: String, isRunning: Bool) {
        (selectedDevice?.uid ?? "", engine?.isRunning == true)
    }

    @discardableResult
    func configure(deviceUID: String) -> Bool {
        stop()
        configuredDeviceUID = deviceUID
        guard !deviceUID.isEmpty else {
            status = "未选择语音输出设备"
            return false
        }
        guard let device = CoreAudioDeviceCatalog.outputDevices().first(where: { $0.uid == deviceUID }) else {
            status = "所选语音输出设备不可用"
            return false
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: sourceFormat)

        guard let outputUnit = engine.outputNode.audioUnit else {
            status = "无法打开 CoreAudio 输出单元"
            return false
        }
        var deviceID = device.id
        let result = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard result == noErr else {
            status = "无法选择音频设备（错误 \(result)）"
            return false
        }

        do {
            engine.prepare()
            try engine.start()
            player.play()
            self.engine = engine
            self.player = player
            selectedDevice = device
            status = "语音输出：\(device.name)"
            recoveryPolicy.reset()
            clearStalledFlag()
            observeConfigurationChanges(of: engine)
            installDeviceListListener()
            // Log de-identified: the device name/UID is shown in the UI status
            // above but must never be written to the on-disk log.
            AppLogger.shared.write("AUDIO READY")
            return true
        } catch {
            status = "启动音频输出失败：\(error.localizedDescription)"
            AppLogger.shared.write("AUDIO ERROR start_failed=\(error.localizedDescription)")
            return false
        }
    }

    var isReadyForTestTone: Bool {
        selectedDevice != nil && engine?.isRunning == true
    }

    /// Schedules the test tone and reports actual playback completion via `scheduleBuffer`'s
    /// `.dataPlayedBack` callback rather than a fixed timer. `completion` receives `true` only
    /// when the tone finished sounding; `false` if it was cut short (device torn down, real
    /// voice preempted it, etc.). Returns `false` immediately if scheduling never happened.
    @discardableResult
    func playTestTone(completion: @escaping (Bool) -> Void) -> Bool {
        guard isReadyForTestTone,
              let player,
              let buffer = makeBuffer(samples: TestToneGenerator.samples(sampleRate: sourceFormat.sampleRate))
        else { return false }
        player.scheduleBuffer(
            buffer,
            at: nil,
            options: [],
            completionCallbackType: .dataPlayedBack
        ) { callbackType in
            completion(callbackType == .dataPlayedBack)
        }
        return true
    }

    /// Flushes any buffer currently queued on the player node (including an in-flight test
    /// tone) so real RC003 voice audio scheduled right after this call is not delayed behind it.
    func cancelTestTone() {
        flushPlayer()
    }

    private func makeBuffer(samples: [Int16]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?[0]
        else { return nil }

        for index in samples.indices {
            channel[index] = Float(samples[index]) / Float(Int16.max)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    @discardableResult
    func enqueue(
        samples: [Int16],
        diagnosticsSession: AudioPathDiagnostics.Session? = nil
    ) -> Bool {
        guard let player, engine?.isRunning == true else {
            if let diagnosticsSession {
                diagnostics.recordQueueRejected(for: diagnosticsSession)
            }
            noteOutputStalled()
            return false
        }
        guard let buffer = makeBuffer(samples: samples) else {
            if let diagnosticsSession {
                diagnostics.recordQueueRejected(for: diagnosticsSession)
            }
            return false
        }
        guard let diagnosticsSession else {
            player.scheduleBuffer(buffer)
            return true
        }
        diagnostics.recordQueueAccepted(samples: samples, for: diagnosticsSession)
        if let watermark = diagnostics.requestPlaybackWatermark(for: diagnosticsSession) {
            player.scheduleBuffer(
                buffer,
                at: nil,
                options: [],
                completionCallbackType: .dataPlayedBack
            ) { [weak self] callbackType in
                guard callbackType == .dataPlayedBack else { return }
                self?.diagnostics.recordPlaybackWatermarkCompleted(watermark)
            }
        } else {
            player.scheduleBuffer(buffer)
        }
        return true
    }

    func endSession(diagnosticsSession: AudioPathDiagnostics.Session) {
        diagnostics.endSession(diagnosticsSession)
        flushPlayer()
    }

    /// Flushes shared playback when no RC003 diagnostic session owns it (for
    /// example the test-tone helper). It deliberately cannot update the remote
    /// diagnostics, so local audio never contaminates RC003 status.
    func endSession() {
        flushPlayer()
    }

    /// Flushes PCM already queued on the player node — used when the local
    /// microphone session ends or is preempted so no residual local audio plays
    /// after RC003 takes over.
    func flushPending() {
        flushPlayer()
    }

    private func flushPlayer() {
        guard let player, engine?.isRunning == true else { return }
        player.stop()
        player.reset()
        player.play()
    }

    func stop() {
        recoveryWork?.cancel()
        recoveryWork = nil
        removeConfigurationObserver()
        removeDeviceListListener()
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        selectedDevice = nil
        configuredDeviceUID = ""
        clearStalledFlag()
    }

    // MARK: - Output self-healing

    /// A voice buffer could not be scheduled because the engine is gone. That is
    /// the silent failure this app used to hide: the remote keeps streaming and
    /// the UI keeps reporting a configured device while nothing reaches the
    /// virtual output, so report it once per outage and start rebuilding.
    private func noteOutputStalled() {
        stallLock.lock()
        let firstReport = !stalledReported
        stalledReported = true
        stallLock.unlock()
        if firstReport {
            AppLogger.shared.write("AUDIO STALLED output_running=\(engine?.isRunning == true)")
        }
        requestRecovery(reason: "queue_rejected")
    }

    private func clearStalledFlag() {
        stallLock.lock()
        stalledReported = false
        stallLock.unlock()
    }

    private func requestRecovery(reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.configuredDeviceUID.isEmpty else { return }
            self.recoveryPolicy.noteConfigurationChange(now: Date())
            self.scheduleRecovery(reason: reason)
        }
    }

    private func scheduleRecovery(reason: String) {
        recoveryWork?.cancel()
        recoveryWork = nil
        let now = Date()
        guard let due = recoveryPolicy.nextAttemptDate(now: now) else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.attemptRecovery(reason: reason)
        }
        recoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due.timeIntervalSince(now)), execute: work)
    }

    private func attemptRecovery(reason: String) {
        guard !isRebuilding, !configuredDeviceUID.isEmpty else { return }
        // A device coming or going does not necessarily break our engine — the virtual
        // output often keeps playing through an unrelated device change. Rebuilding then
        // would drop the voice that is in flight, so the rebuild only happens once the
        // engine really stopped (AVAudioEngine stops it before posting the notification,
        // and a rejected buffer already means it is gone).
        guard engine?.isRunning != true else {
            recoveryPolicy.reset()
            return
        }
        let now = Date()
        guard recoveryPolicy.attemptIsDue(now: now) else {
            scheduleRecovery(reason: reason)
            return
        }
        guard recoveryPolicy.attempts < recoveryPolicy.maxAttempts else {
            recoveryPolicy.noteExhausted(now: now)
            AppLogger.shared.write("AUDIO RECOVER gave_up reason=\(reason)")
            scheduleRecovery(reason: reason)
            return
        }

        recoveryPolicy.noteAttempt(now: now)
        let attempt = recoveryPolicy.attempts
        let deviceUID = configuredDeviceUID
        isRebuilding = true
        // configure() resets the policy on success, so the attempt number is
        // captured before the rebuild starts.
        let rebuilt = configure(deviceUID: deviceUID)
        isRebuilding = false
        if rebuilt {
            AppLogger.shared.write("AUDIO RECOVERED attempts=\(attempt) reason=\(reason)")
        } else {
            AppLogger.shared.write("AUDIO RECOVER failed attempts=\(attempt) reason=\(reason)")
            recoveryPolicy.noteConfigurationChange(now: Date())
            scheduleRecovery(reason: reason)
        }
    }

    /// AVAudioEngine stops itself when the hardware graph changes; the system
    /// expects the owner to reconnect and restart it.
    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        removeConfigurationObserver()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isRebuilding else { return }
            self.requestRecovery(reason: "configuration_change")
        }
    }

    private func removeConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    /// A device list change is what renumbers the virtual output (the UID survives,
    /// the AudioDeviceID does not), so it must also kick a rebuild.
    private func installDeviceListListener() {
        guard deviceListListener == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.requestRecovery(reason: "device_list")
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            listener
        )
        if status == noErr {
            deviceListListener = listener
        } else {
            AppLogger.shared.write("AUDIO LISTENER failed status=\(status)")
        }
    }

    private func removeDeviceListListener() {
        guard let deviceListListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            deviceListListener
        )
        self.deviceListListener = nil
    }
}
