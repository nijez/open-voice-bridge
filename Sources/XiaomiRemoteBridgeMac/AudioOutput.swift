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
            guard outputChannelCount(for: deviceID) > 0,
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

    private static func outputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
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
    private var configurationObserver: NSObjectProtocol?
    private var engineGeneration: UInt64 = 0
    private let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private(set) var selectedDevice: AudioDeviceInfo?
    private(set) var status = "未选择语音输出设备"
    var onConfigurationChange: (() -> Void)?

    @discardableResult
    func configure(deviceUID: String) -> Bool {
        stop()
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
            installConfigurationObserver(
                for: engine,
                generation: engineGeneration
            )
            status = "语音输出：\(device.name)"
            AppLogger.shared.write("AUDIO READY device=\(device.name)")
            return true
        } catch {
            status = "启动音频输出失败：\(error.localizedDescription)"
            AppLogger.shared.write("AUDIO ERROR start_failed=\(error.localizedDescription)")
            return false
        }
    }

    var isReadyForTestTone: Bool {
        guard let selectedDevice else { return false }
        return isConfigured(deviceUID: selectedDevice.uid)
    }

    func isConfigured(
        deviceUID: String,
        expectedDeviceID: AudioDeviceID? = nil
    ) -> Bool {
        guard !deviceUID.isEmpty,
              let selectedDevice,
              selectedDevice.uid == deviceUID,
              let engine,
              engine.isRunning,
              let player,
              player.isPlaying,
              let outputUnit = engine.outputNode.audioUnit,
              let currentDeviceID = currentDeviceID(for: outputUnit)
        else { return false }
        let expectedDeviceID = expectedDeviceID ?? selectedDevice.id
        return selectedDevice.id == expectedDeviceID &&
            currentDeviceID == expectedDeviceID
    }

    /// Configuration changes can leave AVAudioEngine stopped while its nodes remain
    /// attached. If the output unit is still bound to the selected device, restarting
    /// this graph avoids an unnecessary CurrentDevice mutation and its notifications.
    @discardableResult
    func restoreIfBound(
        deviceUID: String,
        expectedDeviceID: AudioDeviceID? = nil,
        forceRestart: Bool = false
    ) -> Bool {
        guard !deviceUID.isEmpty,
              let selectedDevice,
              selectedDevice.uid == deviceUID,
              let engine,
              let player,
              let outputUnit = engine.outputNode.audioUnit,
              let boundDeviceID = currentDeviceID(for: outputUnit)
        else { return false }

        let expectedDeviceID = expectedDeviceID ?? selectedDevice.id
        guard selectedDevice.id == expectedDeviceID,
              boundDeviceID == expectedDeviceID
        else { return false }

        if engine.isRunning && !forceRestart {
            if !player.isPlaying {
                player.play()
            }
            return player.isPlaying
        }

        if engine.isRunning {
            engine.stop()
        }
        do {
            engine.prepare()
            try engine.start()
            player.play()
            guard engine.isRunning,
                  player.isPlaying,
                  currentDeviceID(for: outputUnit) == expectedDeviceID
            else { return false }
            status = "语音输出：\(selectedDevice.name)"
            AppLogger.shared.write(
                "AUDIO ENGINE restarted device=\(selectedDevice.name)"
            )
            return true
        } catch {
            AppLogger.shared.write(
                "AUDIO ENGINE restart_failed error=\(error.localizedDescription)"
            )
            return false
        }
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
    func enqueue(samples: [Int16]) -> Bool {
        guard let player,
              player.isPlaying,
              engine?.isRunning == true,
              let buffer = makeBuffer(samples: samples)
        else {
            return false
        }
        player.scheduleBuffer(buffer)
        return true
    }

    func endSession() {
        flushPlayer()
    }

    private func flushPlayer() {
        guard let player else { return }
        player.stop()
        player.reset()
        if engine?.isRunning == true {
            player.play()
        }
    }

    func stop() {
        engineGeneration &+= 1
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        selectedDevice = nil
    }

    private func installConfigurationObserver(
        for engine: AVAudioEngine,
        generation: UInt64
    ) {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self, weak engine] _ in
            // Configuration changes may arrive off-main. Serialize engine recovery
            // with the rest of the app model on the main queue.
            DispatchQueue.main.async { [weak self, weak engine] in
                guard let self,
                      let engine,
                      self.engineGeneration == generation,
                      self.engine === engine
                else { return }
                AppLogger.shared.write("AUDIO ENGINE configuration_changed")
                self.onConfigurationChange?()
            }
        }
    }

    private func currentDeviceID(for outputUnit: AudioUnit) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let result = AudioUnitGetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        return result == noErr ? deviceID : nil
    }
}
