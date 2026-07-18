import AVFoundation
import CoreAudio
import Foundation

// MARK: - Microphone permission

enum MicrophoneAuthorization: Equatable {
    case authorized
    case denied
    case notDetermined
    case restricted

    var isAuthorized: Bool { self == .authorized }

    var statusText: String {
        switch self {
        case .authorized: return "已授权"
        case .denied: return "已拒绝（请在系统设置中开启）"
        case .notDetermined: return "尚未请求"
        case .restricted: return "受系统策略限制"
        }
    }
}

/// Thin wrapper over `AVCaptureDevice` audio authorisation. The app never asks
/// for the microphone implicitly — only the explicit Settings button calls
/// `request`. Uses its own TCC service; it does not reuse Accessibility or Input
/// Monitoring to stand in for microphone consent.
enum MicrophonePermission {
    static var status: MicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    static func request(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}

// MARK: - Capture engine

/// Captures the Mac's built-in (or a user-selected) microphone and emits
/// normalised 16 kHz mono `Int16` PCM, matching the format the RC003 voice path
/// already writes to the selected output. The engine only runs while a capture
/// session is active; there is no continuous recording and nothing is written to
/// disk. Any configuration or engine failure fails closed (`start` returns
/// `false` and the caller must not treat the session as running).
final class LocalMicrophoneCapture {
    /// Emits normalised 16 kHz mono samples on the audio render thread, tagged
    /// with the session token they belong to. The coordinator drops samples
    /// whose token is no longer the active session (stop/preempt/source switch).
    var onSamples: (([Int16], UInt64) -> Void)?

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var gainDB: Double = 0
    private var session: UInt64 = 0
    private(set) var isCapturing = false
    private(set) var lastError: String?

    /// True only while the engine is attached and actually running. Used by the
    /// liveness timer to fail closed if the capture engine dies mid-session.
    var engineIsHealthy: Bool {
        isCapturing && engine?.isRunning == true
    }

    /// Starts capture for `session`. Pass `nil` for `inputDeviceID` to follow the
    /// current system default input device; pass a concrete id to pin a specific
    /// input.
    @discardableResult
    func start(inputDeviceID: AudioDeviceID?, gainDB: Double, session: UInt64) -> Bool {
        stop()
        lastError = nil
        self.gainDB = gainDB
        self.session = session

        let engine = AVAudioEngine()
        let input = engine.inputNode

        if let inputDeviceID {
            guard let unit = input.audioUnit else {
                lastError = "input_unit_unavailable"
                return false
            }
            var deviceID = inputDeviceID
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                lastError = "input_device_select_failed"
                return false
            }
        }

        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            lastError = "input_format_unavailable"
            return false
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            lastError = "converter_unavailable"
            return false
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, session: session)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.converter = nil
            lastError = "engine_start_failed"
            return false
        }

        self.engine = engine
        isCapturing = true
        return true
    }

    func stop() {
        // Invalidate the session first so any tap callback already in flight on
        // the audio thread drops its buffer instead of emitting after teardown.
        session &+= 1
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil
        isCapturing = false
    }

    private func process(buffer: AVAudioPCMBuffer, session: UInt64) {
        guard isCapturing, session == self.session, let converter, buffer.frameLength > 0 else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        var providedInput = false
        var conversionError: NSError?
        let statusCode = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if providedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            providedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard statusCode != .error,
              output.frameLength > 0,
              let channel = output.int16ChannelData
        else { return }

        let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
        let shaped = LocalMicGain.apply(samples, gainDB: gainDB)
        onSamples?(shaped, session)
    }
}
