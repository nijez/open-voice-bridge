import Foundation

private var passed = 0
private var failed = 0

private func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        passed += 1
        print("PASS \(name)")
    } else {
        failed += 1
        print("FAIL \(name)")
    }
}

private func catalogFixture(id: String, status: String = "implemented") -> String {
    """
    {
      "schemaVersion": 1,
      "id": "\(id)",
      "displayName": "Self-test Device",
      "vendor": "Self-test Vendor",
      "model": "Self-test Model",
      "support": { "status": "\(status)", "notes": "Fixture." },
      "identity": {},
      "transports": [
        {
          "kind": "system-audio-input",
          "role": "voice-input",
          "status": "\(status)",
          "notes": "Fixture."
        }
      ],
      "capabilities": ["voice-capture"],
      "platforms": [
        { "platform": "macos", "status": "\(status)", "notes": "Fixture." }
      ],
      "sources": ["https://example.com/device"]
    }
    """
}

let versionOne = ATVVCapabilities.parse(Data([0x0B, 0x01, 0x00, 0x02, 0x03, 0x00, 0x78]))
check(
    versionOne?.version == 0x0100 &&
        versionOne?.selectedCodec == 0x02 &&
        versionOne?.sampleRate == 16_000 &&
        versionOne?.frameSize == 120,
    "ATVV v1 capabilities"
)

let legacyLayout = ATVVCapabilities.parse(
    Data([0x0B, 0x01, 0x00, 0x00, 0x02, 0x00, 0x78, 0x00, 0x00])
)

let rc003Profile = VoiceBridgeDeviceProfiles.xiaomiRC003
check(
    rc003Profile.id == "xiaomi-rc003" &&
        rc003Profile.hidIdentity == VoiceBridgeHIDIdentity(
            vendorID: 0x2717,
            productID: 0x32B8
        ) &&
        rc003Profile.transports == [.bluetoothLowEnergyGATT, .bluetoothHID] &&
        rc003Profile.capabilities.contains(.voiceCapture),
    "RC003 profile owns identity, transports, and capabilities"
)

if let profileDirectory = ProcessInfo.processInfo.environment["OVB_DEVICE_PROFILES_DIR"] {
    do {
        let catalog = try DeviceProfileCatalog.load(
            directory: URL(fileURLWithPath: profileDirectory, isDirectory: true)
        )
        check(
            catalog.map(\.id) == ["xiaomi-arn9", "xiaomi-rc003", "dji-mic-2"] &&
                catalog.first?.support.status == .implemented &&
                catalog.first(where: { $0.id == "dji-mic-2" })?.support.status == .research,
            "shared device catalog loads repository JSON and preserves declared support states"
        )
    } catch {
        check(false, "shared device catalog loads repository JSON and preserves declared support states")
    }
} else {
    check(false, "shared device catalog self-test directory is provided")
}
let missingProfileDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
do {
    _ = try DeviceProfileCatalog.load(directory: missingProfileDirectory)
    check(false, "shared device catalog fails closed when its directory cannot be located")
} catch let error as DeviceProfileCatalogError {
    check(
        error == .directoryUnavailable,
        "shared device catalog fails closed when its directory cannot be located"
    )
} catch {
    check(false, "shared device catalog fails closed when its directory cannot be located")
}
do {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let duplicateDirectory = root.appendingPathComponent("duplicate", isDirectory: true)
    try FileManager.default.createDirectory(at: duplicateDirectory, withIntermediateDirectories: true)
    let duplicate = Data(catalogFixture(id: "duplicate").utf8)
    try duplicate.write(to: duplicateDirectory.appendingPathComponent("one.json"))
    try duplicate.write(to: duplicateDirectory.appendingPathComponent("two.json"))
    do {
        _ = try DeviceProfileCatalog.load(directory: duplicateDirectory)
        check(false, "shared device catalog rejects duplicate device IDs")
    } catch let error as DeviceProfileCatalogError {
        check(error == .duplicateID("duplicate"), "shared device catalog rejects duplicate device IDs")
    }

    let unknownDirectory = root.appendingPathComponent("unknown", isDirectory: true)
    try FileManager.default.createDirectory(at: unknownDirectory, withIntermediateDirectories: true)
    try Data(catalogFixture(id: "unknown", status: "beta").utf8)
        .write(to: unknownDirectory.appendingPathComponent("unknown.json"))
    do {
        _ = try DeviceProfileCatalog.load(directory: unknownDirectory)
        check(false, "shared device catalog rejects unknown support states")
    } catch let error as DeviceProfileCatalogError {
        if case let .invalidProfile(_, reason) = error {
            check(reason == "包含未知枚举值", "shared device catalog rejects unknown support states")
        } else {
            check(false, "shared device catalog rejects unknown support states")
        }
    }

    let missingDirectory = root.appendingPathComponent("missing", isDirectory: true)
    try FileManager.default.createDirectory(at: missingDirectory, withIntermediateDirectories: true)
    let missingField = catalogFixture(id: "missing")
        .replacingOccurrences(of: "\n  \"displayName\": \"Self-test Device\",", with: "")
    try Data(missingField.utf8).write(to: missingDirectory.appendingPathComponent("missing.json"))
    do {
        _ = try DeviceProfileCatalog.load(directory: missingDirectory)
        check(false, "shared device catalog rejects a missing required field")
    } catch let error as DeviceProfileCatalogError {
        if case let .invalidProfile(_, reason) = error {
            check(reason.contains("displayName"), "shared device catalog rejects a missing required field")
        } else {
            check(false, "shared device catalog rejects a missing required field")
        }
    }
} catch {
    check(false, "shared device catalog strict fixture setup")
}
check(
    legacyLayout?.selectedCodec == 0x02 && legacyLayout?.interaction == 0x03,
    "ATVV legacy codec layout"
)
check(
    ATVVCapabilities.parse(Data()) == nil &&
        ATVVCapabilities.parse(Data([0x0B, 0x01])) == nil &&
        ATVVCapabilities.parse(Data([0x00, 1, 0, 2, 3, 0, 120])) == nil,
    "ATVV malformed capabilities"
)
check(
    ATVVProtocol.microphoneOpen(version: 0x0100, codec: 2) == Data([0x0C, 0x00]) &&
        ATVVProtocol.microphoneOpen(version: 1, codec: 2) == Data([0x0C, 0x00, 0x02]) &&
        ATVVProtocol.microphoneClose(version: 0x0100, sessionID: 7) == Data([0x0D, 0x07]) &&
        ATVVProtocol.microphoneClose(version: 1, sessionID: 7) == Data([0x0D]),
    "ATVV microphone commands"
)
check(
    ATVVProtocol.supportsAudio(sampleRate: 16_000) &&
        !ATVVProtocol.supportsAudio(sampleRate: 8_000),
    "ATVV audio rate gate"
)

check(
    RC003NameMatcher.matches("MI RC") &&
        RC003NameMatcher.matches("mi rc") &&
        RC003NameMatcher.matches("  MI RC  ") &&
        RC003NameMatcher.matches("Xiaomi Bluetooth Remote 2 Pro") &&
        RC003NameMatcher.matches("xiaomi bluetooth remote 2 pro") &&
        RC003NameMatcher.matches("小米蓝牙语音遥控器") &&
        RC003NameMatcher.matches(" 小米蓝牙语音遥控器 "),
    "RC003 name matcher accepts approved candidate names"
)
check(
    !RC003NameMatcher.matches(nil) &&
        !RC003NameMatcher.matches("") &&
        !RC003NameMatcher.matches("   ") &&
        !RC003NameMatcher.matches("Mi Mouse") &&
        !RC003NameMatcher.matches("小米蓝牙遥控器") &&
        !RC003NameMatcher.matches("Xiaomi Bluetooth Remote 2") &&
        !RC003NameMatcher.matches("MI RC2") &&
        !RC003NameMatcher.matches("小米"),
    "RC003 name matcher rejects blank, nil, and similar non-target names"
)

let generationOne: UInt64 = 1
let generationTwo: UInt64 = 2
let connecting = BluetoothLifecyclePhase.connecting(generationOne)
let discovering = BluetoothLifecyclePhase.discovering(generationOne)
let awaiting = BluetoothLifecyclePhase.awaitingCapabilities(generationOne)
let ready = BluetoothLifecyclePhase.ready(generationOne)
let disconnecting = BluetoothLifecyclePhase.disconnecting(generationOne)
check(
    connecting.acceptsDidConnect(generation: generationOne) &&
        connecting.acceptsDidFailToConnect(generation: generationOne) &&
        !connecting.acceptsDisconnect(generation: generationOne) &&
        !connecting.acceptsDidConnect(generation: generationTwo) &&
        disconnecting.acceptsDidFailToConnect(generation: generationOne),
    "Bluetooth generation and connect phase"
)
check(
    discovering.acceptsInitializationCallback(generation: generationOne) &&
        !discovering.acceptsCapabilities(generation: generationOne) &&
        awaiting.acceptsCapabilities(generation: generationOne) &&
        !awaiting.acceptsProtocolData(generation: generationOne) &&
        ready.acceptsProtocolData(generation: generationOne) &&
        !ready.acceptsProtocolData(generation: generationTwo) &&
        disconnecting.acceptsDisconnect(generation: generationOne),
    "Bluetooth lifecycle callback gates"
)
check(
    discovering.acceptsModelDiscovery(generation: generationOne) &&
        awaiting.acceptsModelDiscovery(generation: generationOne) &&
        discovering.acceptsModelValue(generation: generationOne) &&
        awaiting.acceptsModelValue(generation: generationOne),
    "model callbacks survive either parallel ATVV/device-information ordering"
)
check(
    !ready.acceptsModelValue(generation: generationOne) &&
        !disconnecting.acceptsModelValue(generation: generationOne) &&
        !BluetoothLifecyclePhase.waitingReconnect(generationOne)
            .acceptsModelValue(generation: generationOne) &&
        !BluetoothLifecyclePhase.stopped.acceptsModelValue(generation: generationOne) &&
        !discovering.acceptsModelValue(generation: generationTwo),
    "late or stale model callbacks fail closed after ready, disconnect, or generation change"
)
var modelConfirmationGate = XiaomiModelConfirmationGate()
let firstConfirmedVariant = modelConfirmationGate.accept(" arn9\n")
let duplicateVariant = modelConfirmationGate.accept("ARN9")
let conflictingVariant = modelConfirmationGate.accept("RC003")
check(
    firstConfirmedVariant == .arn9 &&
        duplicateVariant == nil &&
        conflictingVariant == nil &&
        modelConfirmationGate.modelNumber == "ARN9" &&
        modelConfirmationGate.variant == .arn9,
    "model confirmation is first-value-wins and duplicate/conflicting values are side-effect free"
)
modelConfirmationGate.reset()
check(
    !modelConfirmationGate.isConfirmed &&
        modelConfirmationGate.accept("RC003") == .rc003Pro,
    "model confirmation reset permits one value in the next connection generation"
)
check(
    !ATVVSessionGate.canOpenMicrophone(
        phase: awaiting,
        generation: generationOne,
        capabilitiesConfirmed: true,
        sampleRate: 16_000
    ) &&
        !ATVVSessionGate.canOpenMicrophone(
            phase: ready,
            generation: generationOne,
            capabilitiesConfirmed: false,
            sampleRate: 16_000
        ) &&
        !ATVVSessionGate.canOpenMicrophone(
            phase: ready,
            generation: generationOne,
            capabilitiesConfirmed: true,
            sampleRate: 8_000
        ) &&
        ATVVSessionGate.canOpenMicrophone(
            phase: ready,
            generation: generationOne,
            capabilitiesConfirmed: true,
            sampleRate: 16_000
        ),
    "ATVV READY microphone hard gate"
)

let decoder = IMAADPCMDecoder()
check(decoder.decode(Data([0x11])) == [1, 2], "ADPCM nibble order")
decoder.reset()
check(decoder.decode(Data([0x7F])) == [11, -19], "ADPCM signed decode")
decoder.reset(predictor: 100_000, stepIndex: 1_000)
check(decoder.predictor == 32_767 && decoder.stepIndex == 88, "ADPCM state clamping")

check(
    PCMPostprocessor.process([0, 1000, 0], gainDB: 0) == [0, 500, 0] &&
        PCMPostprocessor.process([20_000], gainDB: 24) == [Int16.max] &&
        PCMPostprocessor.process([20_000], gainDB: .infinity) == [20_000],
    "PCM smoothing and gain clamp"
)

var accumulator = FrameAccumulator()
let partial = accumulator.append(Data([1, 2]), frameSize: 3)
let frames = accumulator.append(Data([3, 4, 5, 6, 7]), frameSize: 3)
check(
    partial.isEmpty &&
        frames == [Data([1, 2, 3]), Data([4, 5, 6])] &&
        accumulator.pending == Data([7]),
    "frame accumulation"
)

check(
    RemoteHIDReportParser.usages(
        reportID: 1,
        data: Data([0xF1, 0x00, 0x80, 0x00, 0x00, 0x00])
    ) == Set([UInt16(0xF1), UInt16(0x80)]),
    "RC003 raw HID report"
)
check(
    RemoteHIDReportParser.usages(
        reportID: 1,
        data: Data([0x01, 0x35, 0x00, 0x00, 0x00, 0x00, 0x00])
    ) == Set([UInt16(0x35)]),
    "RC003 included report ID"
)
check(
    RemoteHIDReportParser.usages(reportID: 2, data: Data([0, 0])) == nil &&
        RemoteHIDReportParser.usages(reportID: 1, data: Data()) == nil &&
        RemoteHIDReportParser.usages(reportID: 1, data: Data([1])) == nil,
    "RC003 malformed report rejection"
)
check(
    Set(RemoteButton.usageMap.values).allSatisfy {
        AppSettings.defaultBindings[$0] != nil
    },
    "all known buttons have defaults"
)
check(
    RemoteButton.usageMap == [
        0x28: .ok,
        0x35: .tv,
        0x4A: .home,
        0x4F: .right,
        0x50: .left,
        0x51: .down,
        0x52: .up,
        0x65: .menu,
        0x66: .power,
        0x80: .volumeUp,
        0x81: .volumeDown,
        0xF1: .back,
    ],
    "verified RC003 usage table"
)
check(
    RemoteButton.up.nativeEvent == .keyboard(keyCode: 126) &&
        RemoteButton.ok.nativeEvent == .keyboard(keyCode: 36) &&
        RemoteButton.volumeUp.nativeEvent == .systemKey(type: 0) &&
        RemoteButton.back.nativeEvent == nil,
    "native duplicate-event descriptors"
)
check(
    !HIDPermissionGate.canMonitor(
        mappingEnabled: true,
        inputMonitoringGranted: false,
        accessibilityGranted: true
    ) &&
        !HIDPermissionGate.canMonitor(
            mappingEnabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: false
        ) &&
        HIDPermissionGate.canMonitor(
            mappingEnabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true
        ),
    "HID permission gate fails closed"
)

check(
    HIDPermissionGate.nextPermissionRequest(
        mappingEnabled: false,
        inputMonitoringGranted: false,
        accessibilityGranted: false
    ) == .none &&
        HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: true,
            inputMonitoringGranted: false,
            accessibilityGranted: false
        ) == .inputMonitoring &&
        HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: false
        ) == .accessibility &&
        HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true
        ) == .none,
    "HID permission requests are sequential and opt-in"
)

var voiceFunctionKeyLatch = VoiceFunctionKeyLatch()
let firstVoicePress = voiceFunctionKeyLatch.transition(streaming: true)
let duplicateVoicePress = voiceFunctionKeyLatch.transition(streaming: true)
let firstVoiceRelease = voiceFunctionKeyLatch.transition(streaming: false)
let duplicateVoiceRelease = voiceFunctionKeyLatch.transition(streaming: false)
check(
    firstVoicePress == .press &&
        duplicateVoicePress == nil &&
        firstVoiceRelease == .release &&
        duplicateVoiceRelease == nil &&
        !voiceFunctionKeyLatch.isHeld,
    "voice Fn latch emits one press and one release"
)

let failedVoicePress = voiceFunctionKeyLatch.transition(streaming: true)
if let failedVoicePress {
    voiceFunctionKeyLatch.rollback(failedVoicePress)
}
let voicePressForFailedRelease = voiceFunctionKeyLatch.transition(streaming: true)
let failedVoiceRelease = voiceFunctionKeyLatch.transition(streaming: false)
if let failedVoiceRelease {
    voiceFunctionKeyLatch.rollback(failedVoiceRelease)
}
check(
    failedVoicePress == .press &&
        voicePressForFailedRelease == .press &&
        failedVoiceRelease == .release &&
        voiceFunctionKeyLatch.isHeld,
    "voice Fn latch rolls back failed injection"
)
_ = voiceFunctionKeyLatch.transition(streaming: false)

let unrelatedMapping = HIDUsageMapping(source: 0x0000_0007_0000_0004, destination: 0x0000_0007_0000_0005)
let staleVoiceMapping = HIDUsageMapping(
    source: RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source,
    destination: 0x0000_0007_0000_00E1
)
let hardwareVoiceMappings = RemoteVoiceFunctionMappingPolicy.applying(
    to: [unrelatedMapping, staleVoiceMapping]
)
check(
    hardwareVoiceMappings == [
        unrelatedMapping,
        RemoteVoiceFunctionMappingPolicy.remoteVoiceKey,
    ],
    "RC003 hardware voice mapping replaces only F5 and preserves unrelated mappings"
)
check(
    RemoteVoiceFunctionMappingPolicy.applying(to: hardwareVoiceMappings) == hardwareVoiceMappings,
    "RC003 hardware voice mapping is idempotent"
)
let changedUnrelatedMapping = HIDUsageMapping(
    source: unrelatedMapping.source,
    destination: 0x0000_0007_0000_0006
)
check(
    RemoteVoiceFunctionMappingPolicy.restoring(
        originalVoiceMapping: staleVoiceMapping,
        in: [changedUnrelatedMapping, RemoteVoiceFunctionMappingPolicy.remoteVoiceKey]
    ) == [changedUnrelatedMapping, staleVoiceMapping] &&
        RemoteVoiceFunctionMappingPolicy.restoring(
            originalVoiceMapping: nil,
            in: [changedUnrelatedMapping, RemoteVoiceFunctionMappingPolicy.remoteVoiceKey]
        ) == [changedUnrelatedMapping],
    "RC003 hardware voice mapping restore preserves unrelated runtime changes"
)
check(
    HIDUsageMapping(property: RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.property) ==
        RemoteVoiceFunctionMappingPolicy.remoteVoiceKey,
    "RC003 hardware voice mapping property round-trips"
)

check(
    TestToneGenerator.samples(sampleRate: 16_000).count == 16_000 &&
        TestToneGenerator.samples(sampleRate: 8_000).count == 8_000 &&
        TestToneGenerator.samples(sampleRate: 0).isEmpty &&
        TestToneGenerator.samples(sampleRate: -1).isEmpty,
    "test tone sample count follows duration and sample rate"
)
check(
    TestToneGenerator.duration >= 0.8 && TestToneGenerator.duration <= 1.2,
    "test tone duration stays close to 1 second"
)
check(
    TestToneGenerator.frequency >= 200 && TestToneGenerator.frequency <= 2_000,
    "test tone frequency stays in an audible mid-range"
)
check(
    TestToneGenerator.amplitude > 0 && TestToneGenerator.amplitude <= 0.2,
    "test tone amplitude stays low volume"
)
let toneSamples = TestToneGenerator.samples(sampleRate: 16_000)
let toneLimit = Int((Double(Int16.max) * TestToneGenerator.amplitude).rounded()) + 1
check(
    toneSamples.allSatisfy { abs(Int($0)) <= toneLimit },
    "test tone samples never exceed the low-volume safety limit"
)
check(
    !TestToneGate.canPlay(hasSelectedDevice: false, isStreaming: false, isPlaying: false) &&
        !TestToneGate.canPlay(hasSelectedDevice: true, isStreaming: true, isPlaying: false) &&
        !TestToneGate.canPlay(hasSelectedDevice: false, isStreaming: true, isPlaying: false) &&
        !TestToneGate.canPlay(hasSelectedDevice: true, isStreaming: false, isPlaying: true) &&
        !TestToneGate.canPlay(hasSelectedDevice: true, isStreaming: true, isPlaying: true) &&
        !TestToneGate.canPlay(hasSelectedDevice: false, isStreaming: false, isPlaying: true) &&
        !TestToneGate.canPlay(hasSelectedDevice: false, isStreaming: true, isPlaying: true) &&
        TestToneGate.canPlay(hasSelectedDevice: true, isStreaming: false, isPlaying: false),
    "test tone safety gate rejects missing device, active RC003 voice stream, or in-flight playback"
)

var diagnosticsTime: UInt64 = 0
let audioDiagnostics = AudioPathDiagnostics(nowNanos: { diagnosticsTime })
let firstAudioSession = audioDiagnostics.beginSession()
audioDiagnostics.recordDecoded(samples: [Int16.max, 0, -Int16.max, 0], for: firstAudioSession)
audioDiagnostics.recordQueueAccepted(samples: [Int16.max, 0, -Int16.max, 0], for: firstAudioSession)
let firstWatermark = audioDiagnostics.requestPlaybackWatermark(for: firstAudioSession)
let secondWatermarkBeforeCompletion = audioDiagnostics.requestPlaybackWatermark(for: firstAudioSession)
let activeAudioSnapshot = audioDiagnostics.snapshot()
check(
    firstWatermark != nil &&
        secondWatermarkBeforeCompletion == nil &&
        activeAudioSnapshot.decoded.bufferCount == 1 &&
        activeAudioSnapshot.queued.bufferCount == 1 &&
        activeAudioSnapshot.decoded.isRecent &&
        activeAudioSnapshot.decoded.peakDBFS != nil &&
        activeAudioSnapshot.playbackState == .waiting,
    "audio diagnostics distinguish decoded PCM from an output queue watermark"
)
audioDiagnostics.recordPlaybackWatermarkCompleted(firstWatermark!)
let completedAudioSnapshot = audioDiagnostics.snapshot()
check(
    completedAudioSnapshot.playbackState == .completed &&
        completedAudioSnapshot.completedWatermarkCount == 1,
    "audio diagnostics record playback completion separately from queue acceptance"
)
diagnosticsTime += 1_100_000_000
let staleAudioSnapshot = audioDiagnostics.snapshot()
check(
    !staleAudioSnapshot.decoded.isRecent &&
        staleAudioSnapshot.decoded.meterValue == 0,
    "audio diagnostics expire stale PCM levels without retaining audio"
)
let timeoutAudioSession = audioDiagnostics.beginSession()
audioDiagnostics.recordQueueAccepted(samples: [1, 2, 3], for: timeoutAudioSession)
audioDiagnostics.recordQueueRejected(for: timeoutAudioSession)
_ = audioDiagnostics.requestPlaybackWatermark(for: timeoutAudioSession)
diagnosticsTime += 2_000_000_000
let timedOutAudioSnapshot = audioDiagnostics.snapshot()
check(
    timedOutAudioSnapshot.rejectedQueueCount == 1 &&
        timedOutAudioSnapshot.playbackState == .timedOut,
    "audio diagnostics expose output rejection and unconfirmed playback separately"
)
audioDiagnostics.recordQueueAccepted(samples: [4, 5, 6], for: timeoutAudioSession)
let recoveredWatermark = audioDiagnostics.requestPlaybackWatermark(for: timeoutAudioSession)
check(
    recoveredWatermark != nil && audioDiagnostics.snapshot().playbackState == .waiting,
    "audio diagnostics resume watermark sampling after an unconfirmed callback"
)
let shortAudioSession = audioDiagnostics.beginSession()
audioDiagnostics.recordQueueAccepted(samples: [1, 2, 3], for: shortAudioSession)
_ = audioDiagnostics.requestPlaybackWatermark(for: shortAudioSession)
audioDiagnostics.endSession(shortAudioSession)
check(
    audioDiagnostics.snapshot().playbackState == .notObserved,
    "audio diagnostics do not call a flushed short voice playback success"
)
let oldCallbackSession = audioDiagnostics.beginSession()
audioDiagnostics.recordQueueAccepted(samples: [1, 2, 3], for: oldCallbackSession)
let oldCallbackWatermark = audioDiagnostics.requestPlaybackWatermark(for: oldCallbackSession)!
let newCallbackSession = audioDiagnostics.beginSession()
audioDiagnostics.recordQueueAccepted(samples: [4, 5, 6], for: newCallbackSession)
let newCallbackWatermark = audioDiagnostics.requestPlaybackWatermark(for: newCallbackSession)!
audioDiagnostics.recordPlaybackWatermarkCompleted(oldCallbackWatermark)
let afterOldCallback = audioDiagnostics.snapshot()
audioDiagnostics.recordPlaybackWatermarkCompleted(newCallbackWatermark)
check(
    afterOldCallback.playbackState == .waiting &&
        afterOldCallback.completedWatermarkCount == 0 &&
        audioDiagnostics.snapshot().playbackState == .completed,
    "audio diagnostics ignore a late playback callback from an earlier voice session"
)

check(
    AudioDiagnosticsRefreshPolicy.activeRefreshInterval >= 0.08 &&
        AudioDiagnosticsRefreshPolicy.settlementDelay > 1.0,
    "audio diagnostics refresh is bounded to a low active rate and one post-session settlement"
)

final class FakeAudioDiagnosticsRefreshScheduler {
    var repeatingAction: (() -> Void)?
    var oneShotAction: (() -> Void)?
    private(set) var repeatingInterval: TimeInterval?
    private(set) var repeatingTolerance: TimeInterval?
    private(set) var oneShotDelay: TimeInterval?
    private(set) var repeatingScheduleCount = 0
    private(set) var repeatingCancelCount = 0
    private(set) var oneShotScheduleCount = 0
    private(set) var oneShotCancelCount = 0

    func scheduleRepeating(
        interval: TimeInterval,
        tolerance: TimeInterval,
        action: @escaping () -> Void
    ) -> () -> Void {
        repeatingScheduleCount += 1
        repeatingInterval = interval
        repeatingTolerance = tolerance
        repeatingAction = action
        return { [weak self] in
            self?.repeatingCancelCount += 1
            self?.repeatingAction = nil
        }
    }

    func scheduleOneShot(
        delay: TimeInterval,
        action: @escaping () -> Void
    ) -> () -> Void {
        oneShotScheduleCount += 1
        oneShotDelay = delay
        oneShotAction = { [weak self] in
            self?.oneShotAction = nil
            action()
        }
        return { [weak self] in
            self?.oneShotCancelCount += 1
            self?.oneShotAction = nil
        }
    }
}

var diagnosticsRefreshCount = 0
let fakeDiagnosticsScheduler = FakeAudioDiagnosticsRefreshScheduler()
let diagnosticsRefreshController = AudioDiagnosticsRefreshController(
    refresh: { diagnosticsRefreshCount += 1 },
    scheduleRepeating: fakeDiagnosticsScheduler.scheduleRepeating,
    scheduleOneShot: fakeDiagnosticsScheduler.scheduleOneShot
)
check(
    diagnosticsRefreshController.phase == .idle &&
        !diagnosticsRefreshController.hasRepeatingRefresh &&
        !diagnosticsRefreshController.hasPendingSettlement &&
        diagnosticsRefreshCount == 0,
    "audio diagnostics lifecycle starts idle with no scheduled work"
)

diagnosticsRefreshController.beginActiveSession()
check(
    diagnosticsRefreshController.phase == .active &&
        diagnosticsRefreshController.hasRepeatingRefresh &&
        !diagnosticsRefreshController.hasPendingSettlement &&
        fakeDiagnosticsScheduler.repeatingScheduleCount == 1 &&
        fakeDiagnosticsScheduler.repeatingInterval == AudioDiagnosticsRefreshPolicy.activeRefreshInterval &&
        fakeDiagnosticsScheduler.repeatingTolerance == AudioDiagnosticsRefreshPolicy.activeRefreshTolerance &&
        diagnosticsRefreshCount == 1,
    "audio diagnostics lifecycle schedules one repeating refresh only on active begin"
)
fakeDiagnosticsScheduler.repeatingAction?()
diagnosticsRefreshController.endActiveSession()
let firstSettlementAction = fakeDiagnosticsScheduler.oneShotAction
let refreshCountBeforeSettlement = diagnosticsRefreshCount
check(
    diagnosticsRefreshController.phase == .settling &&
        !diagnosticsRefreshController.hasRepeatingRefresh &&
        diagnosticsRefreshController.hasPendingSettlement &&
        fakeDiagnosticsScheduler.repeatingCancelCount == 1 &&
        fakeDiagnosticsScheduler.oneShotScheduleCount == 1 &&
        fakeDiagnosticsScheduler.oneShotDelay == AudioDiagnosticsRefreshPolicy.settlementDelay,
    "audio diagnostics lifecycle stops repeating immediately and schedules one settlement"
)
firstSettlementAction?()
firstSettlementAction?()
check(
    diagnosticsRefreshController.phase == .idle &&
        !diagnosticsRefreshController.hasPendingSettlement &&
        diagnosticsRefreshCount == refreshCountBeforeSettlement + 1,
    "audio diagnostics settlement returns to idle and publishes at most once"
)

diagnosticsRefreshController.beginActiveSession()
diagnosticsRefreshController.reset()
check(
    diagnosticsRefreshController.phase == .idle &&
        !diagnosticsRefreshController.hasRepeatingRefresh &&
        !diagnosticsRefreshController.hasPendingSettlement &&
        fakeDiagnosticsScheduler.repeatingCancelCount == 2,
    "audio diagnostics reset cancels an active repeating refresh"
)

diagnosticsRefreshController.beginActiveSession()
diagnosticsRefreshController.endActiveSession()
let oneShotScheduleCountBeforeDuplicateEnd = fakeDiagnosticsScheduler.oneShotScheduleCount
diagnosticsRefreshController.endActiveSession()
diagnosticsRefreshController.reset()
check(
    diagnosticsRefreshController.phase == .idle &&
        !diagnosticsRefreshController.hasRepeatingRefresh &&
        !diagnosticsRefreshController.hasPendingSettlement &&
        fakeDiagnosticsScheduler.oneShotScheduleCount == oneShotScheduleCountBeforeDuplicateEnd &&
        fakeDiagnosticsScheduler.oneShotCancelCount == 1,
    "audio diagnostics duplicate end is idempotent and reset cancels settlement"
)

diagnosticsRefreshController.beginActiveSession()
let repeatingSchedulesBeforeRestart = fakeDiagnosticsScheduler.repeatingScheduleCount
diagnosticsRefreshController.beginActiveSession()
check(
    diagnosticsRefreshController.phase == .active &&
        diagnosticsRefreshController.hasRepeatingRefresh &&
        fakeDiagnosticsScheduler.repeatingScheduleCount == repeatingSchedulesBeforeRestart + 1 &&
        fakeDiagnosticsScheduler.repeatingCancelCount == 4,
    "audio diagnostics repeated begin replaces the old timer instead of stacking"
)
diagnosticsRefreshController.reset()

diagnosticsRefreshController.beginActiveSession()
let staleRepeatingAction = fakeDiagnosticsScheduler.repeatingAction
diagnosticsRefreshController.reset()
diagnosticsRefreshController.beginActiveSession()
let refreshCountBeforeStaleRepeating = diagnosticsRefreshCount
staleRepeatingAction?()
check(
    diagnosticsRefreshController.phase == .active &&
        diagnosticsRefreshController.hasRepeatingRefresh &&
        diagnosticsRefreshCount == refreshCountBeforeStaleRepeating,
    "audio diagnostics rejects a cancelled repeating callback from an older generation"
)
diagnosticsRefreshController.endActiveSession()
let staleSettlementAction = fakeDiagnosticsScheduler.oneShotAction
diagnosticsRefreshController.reset()
diagnosticsRefreshController.beginActiveSession()
diagnosticsRefreshController.endActiveSession()
let currentSettlementAction = fakeDiagnosticsScheduler.oneShotAction
let refreshCountBeforeStaleSettlement = diagnosticsRefreshCount
staleSettlementAction?()
check(
    diagnosticsRefreshController.phase == .settling &&
        diagnosticsRefreshController.hasPendingSettlement &&
        diagnosticsRefreshCount == refreshCountBeforeStaleSettlement,
    "audio diagnostics rejects a cancelled settlement callback from an older generation"
)
currentSettlementAction?()
check(
    diagnosticsRefreshController.phase == .idle &&
        !diagnosticsRefreshController.hasPendingSettlement,
    "audio diagnostics current settlement still completes after stale callbacks are rejected"
)

let suiteName = "XiaomiRemoteBridgeMacSelfTest.\(UUID().uuidString)"
check(
    XiaomiRemoteVariant.detected(fromModelNumber: "ARN9") == .arn9 &&
        XiaomiRemoteVariant.detected(fromModelNumber: " arn9\n") == .arn9 &&
        XiaomiRemoteVariant.detected(fromModelNumber: "RC003") == .rc003Pro &&
        XiaomiRemoteVariant.detected(fromModelNumber: "UNKNOWN") == nil,
    "shared-name Xiaomi remotes select their variant from the Bluetooth model number"
)
check(
    XiaomiRemoteVariant.detected(fromModelNumber: "UNKNOWN") == nil &&
        XiaomiRemoteVariant.detected(fromModelNumber: "") == nil,
    "unknown or missing Xiaomi model numbers fail closed instead of reusing a persisted variant"
)
if let defaults = UserDefaults(suiteName: suiteName) {
    let saved = try JSONEncoder().encode([
        RemoteButton.back.rawValue: ButtonAction.disabled,
    ])
    defaults.set(saved, forKey: "buttonBindings")
    defaults.set(true, forKey: "exclusiveHID")
    let settings = AppSettings(defaults: defaults)
    check(
        settings.action(for: .back) == .disabled &&
            settings.action(for: .up) == .arrowUp &&
            settings.customMappingEnabled &&
            settings.selectedDeviceProfile == .xiaomiRC003 &&
            settings.xiaomiRemoteVariant == .rc003Pro &&
            settings.launchAtLoginEnabled,
        "saved bindings and legacy mapping toggle migrate"
    )
    settings.selectedDeviceProfile = .djiMic2
    settings.xiaomiRemoteVariant = .arn9
    settings.launchAtLoginEnabled = false
    let reloaded = AppSettings(defaults: defaults)
    check(
        reloaded.selectedDeviceProfile == .djiMic2 &&
            reloaded.xiaomiRemoteVariant == .arn9 &&
            !reloaded.xiaomiRemoteVariant.mappableButtons.contains(.tv) &&
            !reloaded.launchAtLoginEnabled &&
            MacDeviceProfile.allCases == [.xiaomiRC003, .djiMic2],
        "Mac device selector and login-start preference persist"
    )
    defaults.removePersistentDomain(forName: suiteName)
} else {
    check(false, "saved bindings merge with defaults")
}

let legacyLoginItem = LaunchAtLoginManager.legacyLaunchAgentPropertyList(
    bundleIdentifier: "com.example.OpenVoiceBridge"
)
check(
    legacyLoginItem["Label"] as? String == "com.example.OpenVoiceBridge.LaunchAtLogin" &&
        legacyLoginItem["LimitLoadToSessionType"] as? String == "Aqua" &&
        legacyLoginItem["RunAtLoad"] as? Bool == true &&
        legacyLoginItem["ProgramArguments"] as? [String] == [
            "/usr/bin/open",
            "-b",
            "com.example.OpenVoiceBridge",
        ] &&
        (try? PropertyListSerialization.data(
            fromPropertyList: legacyLoginItem,
            format: .xml,
            options: 0
        )) != nil,
    "macOS 11/12 login agent uses the bundle identity and an Aqua session"
)

check(
    LaunchAtLoginManager.isInstalledApplicationBundle(
        URL(fileURLWithPath: "/Applications/Open Voice Bridge.app"),
        homeDirectory: URL(fileURLWithPath: "/private/tmp/ovb-test-home")
    ) &&
        LaunchAtLoginManager.isInstalledApplicationBundle(
            URL(fileURLWithPath: "/private/tmp/ovb-test-home/Applications/Open Voice Bridge.app"),
            homeDirectory: URL(fileURLWithPath: "/private/tmp/ovb-test-home")
        ) &&
        !LaunchAtLoginManager.isInstalledApplicationBundle(
            URL(fileURLWithPath: "/tmp/dist/Open Voice Bridge.app"),
            homeDirectory: URL(fileURLWithPath: "/private/tmp/ovb-test-home")
        ),
    "login registration accepts installed app locations and rejects dist builds"
)

let symlinkTestRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("OVBLoginSymlink-\(UUID().uuidString)", isDirectory: true)
let symlinkHome = symlinkTestRoot.appendingPathComponent("home", isDirectory: true)
let externalDist = symlinkTestRoot.appendingPathComponent("dist", isDirectory: true)
let externalApp = externalDist.appendingPathComponent("Open Voice Bridge.app", isDirectory: true)
try? FileManager.default.createDirectory(at: symlinkHome, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: externalApp, withIntermediateDirectories: true)
try? FileManager.default.createSymbolicLink(
    at: symlinkHome.appendingPathComponent("Applications", isDirectory: true),
    withDestinationURL: externalDist
)
check(
    !LaunchAtLoginManager.isInstalledApplicationBundle(
        symlinkHome
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Open Voice Bridge.app", isDirectory: true),
        homeDirectory: symlinkHome
    ),
    "login registration rejects an Applications symlink that resolves to dist"
)
try? FileManager.default.removeItem(at: symlinkTestRoot)

let loginTestDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("OVBLoginSelfTest-\(UUID().uuidString)", isDirectory: true)
let loginTestPlist = loginTestDirectory.appendingPathComponent("login.plist")
let failingBootstrapBackend = LegacyLaunchAgentBackend(
    bundleIdentifier: "com.example.OpenVoiceBridge",
    propertyListURL: loginTestPlist,
    userID: 501,
    fileManager: .default,
    runLaunchctl: { arguments in arguments.first != "bootstrap" && arguments.first != "print" }
)
var bootstrapFailedClosed = false
do {
    try failingBootstrapBackend.enable()
} catch {
    bootstrapFailedClosed = !FileManager.default.fileExists(atPath: loginTestPlist.path)
}
check(bootstrapFailedClosed, "legacy login bootstrap failure removes the unusable plist")

try? FileManager.default.createDirectory(
    at: loginTestDirectory,
    withIntermediateDirectories: true
)
try? Data("stale".utf8).write(to: loginTestPlist)
let failingCleanupBackend = LegacyLaunchAgentBackend(
    bundleIdentifier: "com.example.OpenVoiceBridge",
    propertyListURL: loginTestPlist,
    userID: 501,
    fileManager: .default,
    runLaunchctl: { arguments in arguments.first == "print" }
)
var cleanupFailedClosed = false
do {
    try failingCleanupBackend.disable()
} catch {
    cleanupFailedClosed = FileManager.default.fileExists(atPath: loginTestPlist.path)
}
check(
    cleanupFailedClosed && failingCleanupBackend.status == .enabled,
    "legacy migration stops before modern registration when bootout fails"
)
try? FileManager.default.removeItem(at: loginTestDirectory)

let legacyConflictManager = LaunchAtLoginManager(
    bundleIdentifier: "com.example.OpenVoiceBridge",
    bundleURL: URL(fileURLWithPath: "/Applications/Open Voice Bridge.app"),
    fileManager: .default,
    userID: 501,
    launchctlRunner: { arguments in arguments.first == "print" }
)
check(
    !legacyConflictManager.isEffective &&
        legacyConflictManager.statusText.contains("旧登录项"),
    "modern status refresh cannot hide a loaded legacy login item"
)

// MARK: XRBM-016 real right-click action

check(
    ButtonAction.mouseRightClick.rawValue == "mouseRightClick" &&
        ButtonAction.mouseRightClick.displayName == "鼠标右键（当前位置）",
    "mouse right-click action has a stable raw value and a clear display name"
)
check(
    ButtonAction.allCases.contains(.mouseRightClick),
    "mouse right-click action appears in the mapping dropdown (allCases)"
)
check(
    ButtonAction.contextMenu.rawValue == "contextMenu" &&
        ButtonAction.contextMenu.displayName == "上下文菜单（Shift-F10）" &&
        ButtonAction.appSwitcher.rawValue == "appSwitcher" &&
        ButtonAction.appSwitcher.displayName == "切换应用（Command-Tab）",
    "context-menu and app-switcher keep their raw values while display names are clarified"
)
check(
    AppSettings.defaultBindings[.menu] == .contextMenu &&
        AppSettings.defaultBindings[.tv] == .appSwitcher,
    "menu default stays contextMenu (Shift-F10); TV stays appSwitcher (Command-Tab)"
)

// Legacy JSON with the unchanged contextMenu/appSwitcher raw values still decodes.
if let legacyDecoded = try? JSONDecoder().decode(
    [String: ButtonAction].self,
    from: Data(#"{"menu":"contextMenu","tv":"appSwitcher"}"#.utf8)
) {
    check(
        legacyDecoded["menu"] == .contextMenu && legacyDecoded["tv"] == .appSwitcher,
        "legacy contextMenu/appSwitcher JSON decodes to the same actions"
    )
} else {
    check(false, "legacy contextMenu/appSwitcher JSON decodes to the same actions")
}

// The new action round-trips through the real AppSettings persistence path.
let rightClickSuite = "XiaomiRemoteBridgeMacSelfTest.rightClick.\(UUID().uuidString)"
if let defaults = UserDefaults(suiteName: rightClickSuite) {
    let saved = try JSONEncoder().encode([
        RemoteButton.menu.rawValue: ButtonAction.mouseRightClick,
    ])
    defaults.set(saved, forKey: "buttonBindings")
    let settings = AppSettings(defaults: defaults)
    check(
        settings.action(for: .menu) == .mouseRightClick &&
            settings.action(for: .tv) == .appSwitcher,
        "a menu key mapped to mouse right-click persists and reloads via AppSettings"
    )
    defaults.removePersistentDomain(forName: rightClickSuite)
} else {
    check(false, "mouse right-click binding persists and reloads via AppSettings")
}

// MARK: Local Mac-keyboard Fn microphone arbitration

var localArbiter = LocalMicArbiter()
_ = localArbiter.handle(.setEnabled(true))
_ = localArbiter.handle(.setReady(true))
let localStart = localArbiter.handle(.physicalFnDown)
let localStartDuplicate = localArbiter.handle(.physicalFnDown)
let localStop = localArbiter.handle(.physicalFnUp)
let localStopDuplicate = localArbiter.handle(.physicalFnUp)
check(
    localStart == .startCapture &&
        localStartDuplicate == .none &&
        localStop == .stopCapture &&
        localStopDuplicate == .none &&
        !localArbiter.capturing,
    "local mic arbiter emits one start/stop per Fn press and ignores duplicate edges"
)

var preemptArbiter = LocalMicArbiter()
_ = preemptArbiter.handle(.setEnabled(true))
_ = preemptArbiter.handle(.setReady(true))
let preemptStart = preemptArbiter.handle(.physicalFnDown)
let preemptStop = preemptArbiter.handle(.remoteVoiceStart)
let residualRemoteStop = preemptArbiter.handle(.remoteVoiceStop)
let residualFnStillNoCapture = !preemptArbiter.capturing
let preemptFnUp = preemptArbiter.handle(.physicalFnUp)
check(
    preemptStart == .startCapture &&
        preemptStop == .stopCapture &&
        residualRemoteStop == .none &&
        residualFnStillNoCapture &&
        preemptFnUp == .none,
    "local mic arbiter: RC003 preempts and a residual Fn never restarts the local mic"
)

var remoteFirstArbiter = LocalMicArbiter()
_ = remoteFirstArbiter.handle(.setEnabled(true))
_ = remoteFirstArbiter.handle(.setReady(true))
_ = remoteFirstArbiter.handle(.remoteVoiceStart)
let downDuringRemote = remoteFirstArbiter.handle(.physicalFnDown)
let remoteEnded = remoteFirstArbiter.handle(.remoteVoiceStop)
let upDuringRemoteHold = remoteFirstArbiter.handle(.physicalFnUp)
let freshDownAfterRemote = remoteFirstArbiter.handle(.physicalFnDown)
check(
    downDuringRemote == .none &&
        remoteEnded == .none &&
        upDuringRemoteHold == .none &&
        freshDownAfterRemote == .startCapture,
    "local mic arbiter never captures while RC003 is active; a fresh Fn press afterwards works"
)

var midHoldArbiter = LocalMicArbiter()
let downBeforeReady = midHoldArbiter.handle(.physicalFnDown)
_ = midHoldArbiter.handle(.setEnabled(true))
_ = midHoldArbiter.handle(.setReady(true))
let noAutoStartMidHold = !midHoldArbiter.capturing
let releaseAfterReady = midHoldArbiter.handle(.physicalFnUp)
let freshPressStart = midHoldArbiter.handle(.physicalFnDown)
check(
    downBeforeReady == .none &&
        noAutoStartMidHold &&
        releaseAfterReady == .none &&
        freshPressStart == .startCapture,
    "local mic arbiter does not auto-start when it becomes ready mid-hold; a fresh press is required"
)

var disableArbiter = LocalMicArbiter()
_ = disableArbiter.handle(.setEnabled(true))
_ = disableArbiter.handle(.setReady(true))
_ = disableArbiter.handle(.physicalFnDown)
let disableStop = disableArbiter.handle(.setEnabled(false))
var revokeArbiter = LocalMicArbiter()
_ = revokeArbiter.handle(.setEnabled(true))
_ = revokeArbiter.handle(.setReady(true))
_ = revokeArbiter.handle(.physicalFnDown)
let revokeStop = revokeArbiter.handle(.setReady(false))
var teardownArbiter = LocalMicArbiter()
_ = teardownArbiter.handle(.setEnabled(true))
_ = teardownArbiter.handle(.setReady(true))
_ = teardownArbiter.handle(.physicalFnDown)
let teardownStop = teardownArbiter.handle(.teardown)
check(
    disableStop == .stopCapture &&
        revokeStop == .stopCapture &&
        teardownStop == .stopCapture &&
        !teardownArbiter.capturing &&
        !teardownArbiter.fnHeld &&
        !teardownArbiter.remoteActive,
    "local mic arbiter fails closed on disable, lost readiness, and teardown"
)

var lifecycleArbiter = LocalMicArbiter()
_ = lifecycleArbiter.handle(.setEnabled(true))
_ = lifecycleArbiter.handle(.setReady(true))
let lifecycleCommands: [LocalMicCommand] = [
    lifecycleArbiter.handle(.physicalFnDown),   // round 1: physical Fn talk -> start
    lifecycleArbiter.handle(.physicalFnUp),     // -> stop
    lifecycleArbiter.handle(.physicalFnDown),   // round 2: RC003 hardware Fn races ahead -> start
    lifecycleArbiter.handle(.remoteVoiceStart), // -> preempt stop
    lifecycleArbiter.handle(.remoteVoiceStop),  // -> none (no restart on residual Fn)
    lifecycleArbiter.handle(.physicalFnUp),     // -> none
    lifecycleArbiter.handle(.physicalFnDown),   // round 3: physical Fn talk -> start
    lifecycleArbiter.handle(.physicalFnUp),     // -> stop
]
check(
    lifecycleCommands == [
        .startCapture, .stopCapture,
        .startCapture, .stopCapture, .none, .none,
        .startCapture, .stopCapture,
    ] &&
        !lifecycleArbiter.capturing &&
        !lifecycleArbiter.fnHeld &&
        !lifecycleArbiter.remoteActive,
    "local mic arbiter keeps interleaved physical Fn and RC003 rounds mutually exclusive and ends clean"
)

var fnTracker = FunctionKeyFlagTracker()
let fnPress = fnTracker.update(functionFlagActive: true)
let fnPressDuplicate = fnTracker.update(functionFlagActive: true)
let fnRelease = fnTracker.update(functionFlagActive: false)
let fnReleaseDuplicate = fnTracker.update(functionFlagActive: false)
check(
    fnPress == .press &&
        fnPressDuplicate == nil &&
        fnRelease == .release &&
        fnReleaseDuplicate == nil &&
        !fnTracker.isDown,
    "function key flag tracker debounces duplicate flagsChanged samples"
)

check(
    AudioLoopGuard.rejection(resolvedInputUID: "BuiltInMic", outputUID: "BlackHole2ch") == nil &&
        AudioLoopGuard.rejection(resolvedInputUID: "BlackHole2ch", outputUID: "BlackHole2ch") == .sameDevice &&
        AudioLoopGuard.rejection(resolvedInputUID: nil, outputUID: "BlackHole2ch") == .noInput &&
        AudioLoopGuard.rejection(resolvedInputUID: "", outputUID: "BlackHole2ch") == .noInput &&
        AudioLoopGuard.rejection(resolvedInputUID: "BuiltInMic", outputUID: "") == .noOutput,
    "audio loop guard rejects same-device feedback and missing endpoints"
)

check(
    LocalMicGain.apply([], gainDB: 6) == [] &&
        LocalMicGain.apply([100, -100], gainDB: 0) == [100, -100] &&
        LocalMicGain.apply([20_000], gainDB: 24) == [Int16.max] &&
        LocalMicGain.apply([-20_000], gainDB: 24) == [Int16.min] &&
        LocalMicGain.apply([100], gainDB: .infinity) == [100],
    "local mic gain scales, clamps, and treats non-finite gain as unity"
)

// MARK: RC003 HID microphone-key pre-marker (P1)

var sourceGateArbiter = LocalMicArbiter()
_ = sourceGateArbiter.handle(.setEnabled(true))
_ = sourceGateArbiter.handle(.setReady(true))
// The RC003 F5 HID edge is observed before the remapped Fn edge arrives.
let sourceMarked = sourceGateArbiter.handle(.remoteSourceDown)
let fnDownAfterSource = sourceGateArbiter.handle(.physicalFnDown)
let sourceReleased = sourceGateArbiter.handle(.remoteSourceUp)
let fnUpAfterSource = sourceGateArbiter.handle(.physicalFnUp)
check(
    sourceMarked == .none &&
        fnDownAfterSource == .none &&
        sourceReleased == .none &&
        fnUpAfterSource == .none &&
        !sourceGateArbiter.capturing,
    "local mic arbiter: an RC003 F5 pre-marker makes the remote Fn edge never start the local mic"
)

var sourcePreemptArbiter = LocalMicArbiter()
_ = sourcePreemptArbiter.handle(.setEnabled(true))
_ = sourcePreemptArbiter.handle(.setReady(true))
let sourcePreemptStart = sourcePreemptArbiter.handle(.physicalFnDown)  // built-in Fn -> start
let sourcePreemptStop = sourcePreemptArbiter.handle(.remoteSourceDown) // RC003 key -> preempt
let sourcePreemptResidual = sourcePreemptArbiter.handle(.remoteSourceUp)
let sourcePreemptNoRestart = !sourcePreemptArbiter.capturing
let sourcePreemptFnUp = sourcePreemptArbiter.handle(.physicalFnUp)
check(
    sourcePreemptStart == .startCapture &&
        sourcePreemptStop == .stopCapture &&
        sourcePreemptResidual == .none &&
        sourcePreemptNoRestart &&
        sourcePreemptFnUp == .none,
    "local mic arbiter: a late RC003 F5 edge preempts the local mic and a residual Fn does not restart it"
)

// MARK: Fn-monitor disruption fails closed and requires a fresh cycle (P2)

var disruptArbiter = LocalMicArbiter()
_ = disruptArbiter.handle(.setEnabled(true))
_ = disruptArbiter.handle(.setReady(true))
let disruptStart = disruptArbiter.handle(.physicalFnDown)
let disruptStop = disruptArbiter.handle(.functionMonitorDisrupted)
let disruptFnHeldCleared = !disruptArbiter.fnHeld
let disruptStaleUp = disruptArbiter.handle(.physicalFnUp)      // stale release swallowed
let disruptFreshStart = disruptArbiter.handle(.physicalFnDown) // new full cycle works
check(
    disruptStart == .startCapture &&
        disruptStop == .stopCapture &&
        disruptFnHeldCleared &&
        disruptStaleUp == .none &&
        disruptFreshStart == .startCapture,
    "local mic arbiter: an Fn-monitor disruption stops capture, clears the held state, and requires a fresh press"
)

// MARK: Disable clears fnHeld so a re-enable is not swallowed (P2 fnHeld resync)

var resyncArbiter = LocalMicArbiter()
_ = resyncArbiter.handle(.setEnabled(true))
_ = resyncArbiter.handle(.setReady(true))
_ = resyncArbiter.handle(.physicalFnDown)            // capturing, fnHeld = true
let resyncDisable = resyncArbiter.handle(.setEnabled(false))
let resyncFnHeldCleared = !resyncArbiter.fnHeld
_ = resyncArbiter.handle(.setEnabled(true))
_ = resyncArbiter.handle(.setReady(true))
let resyncFreshStart = resyncArbiter.handle(.physicalFnDown) // first cycle after re-enable
check(
    resyncDisable == .stopCapture &&
        resyncFnHeldCleared &&
        resyncFreshStart == .startCapture,
    "local mic arbiter: disabling clears the held Fn so the first key cycle after re-enable is not swallowed"
)

// A stale RC003 source held at disable time must not block a later fresh press.
var sourceResyncArbiter = LocalMicArbiter()
_ = sourceResyncArbiter.handle(.setEnabled(true))
_ = sourceResyncArbiter.handle(.setReady(true))
_ = sourceResyncArbiter.handle(.remoteSourceDown)    // RC003 key still down
_ = sourceResyncArbiter.handle(.setEnabled(false))   // observer stops; up edge never comes
_ = sourceResyncArbiter.handle(.setEnabled(true))
_ = sourceResyncArbiter.handle(.setReady(true))
let sourceResyncStart = sourceResyncArbiter.handle(.physicalFnDown)
check(
    sourceResyncStart == .startCapture && !sourceResyncArbiter.remoteSourceActive,
    "local mic arbiter: disabling clears a stale RC003 source marker so it cannot block a later capture"
)

var voiceKeyTracker = RemoteVoiceKeyTracker()
let voiceKeyDown = voiceKeyTracker.update(usages: Set([0x28, RemoteVoiceFunctionMappingPolicy.remoteVoiceKeyUsage]))
let voiceKeyHeld = voiceKeyTracker.update(usages: Set([RemoteVoiceFunctionMappingPolicy.remoteVoiceKeyUsage]))
let voiceKeyUp = voiceKeyTracker.update(usages: Set([0x28]))
let voiceKeyIdle = voiceKeyTracker.update(usages: Set<UInt16>())
check(
    voiceKeyDown == .down &&
        voiceKeyHeld == nil &&
        voiceKeyUp == .up &&
        voiceKeyIdle == nil &&
        !voiceKeyTracker.isDown,
    "RC003 voice-key tracker debounces the F5 usage into one down/up edge"
)

// MARK: Session token drops stale local PCM after preempt/stop (P4)

var sampleRouter = LocalMicSampleRouter()
let firstSession = sampleRouter.begin()
let firstAccepted = sampleRouter.accepts(firstSession)
sampleRouter.invalidate()                 // preempt / stop
let staleAfterInvalidate = sampleRouter.accepts(firstSession)
let secondSession = sampleRouter.begin()  // new capture
let firstRejectedAfterRestart = sampleRouter.accepts(firstSession)
let secondAccepted = sampleRouter.accepts(secondSession)
check(
    firstAccepted &&
        !staleAfterInvalidate &&
        firstSession != secondSession &&
        !firstRejectedAfterRestart &&
        secondAccepted,
    "local mic sample router drops a preempted session's late samples and only accepts the active token"
)

// MARK: Unified readiness / liveness gate (P3)

check(
    LocalMicGate.block(
        enabled: true, micAuthorized: true, fnMonitorRunning: true,
        remoteSourceReaderReady: true,
        outputRunning: true, outputUID: "BlackHole2ch",
        resolvedInputUID: "BuiltInMic", captureEngineHealthy: true
    ) == nil &&
        LocalMicGate.block(
            enabled: false, micAuthorized: true, fnMonitorRunning: true,
            remoteSourceReaderReady: true,
            outputRunning: true, outputUID: "BlackHole2ch",
            resolvedInputUID: "BuiltInMic", captureEngineHealthy: true
        ) == .disabled &&
        LocalMicGate.block(
            enabled: true, micAuthorized: false, fnMonitorRunning: true,
            remoteSourceReaderReady: true,
            outputRunning: true, outputUID: "BlackHole2ch",
            resolvedInputUID: "BuiltInMic", captureEngineHealthy: true
        ) == .micPermission &&
        LocalMicGate.block(
            enabled: true, micAuthorized: true, fnMonitorRunning: false,
            remoteSourceReaderReady: true,
            outputRunning: true, outputUID: "BlackHole2ch",
            resolvedInputUID: "BuiltInMic", captureEngineHealthy: true
        ) == .fnMonitor &&
        LocalMicGate.block(
            enabled: true, micAuthorized: true, fnMonitorRunning: true,
            remoteSourceReaderReady: true,
            outputRunning: false, outputUID: "BlackHole2ch",
            resolvedInputUID: "BuiltInMic", captureEngineHealthy: true
        ) == .outputMissing &&
        LocalMicGate.block(
            enabled: true, micAuthorized: true, fnMonitorRunning: true,
            remoteSourceReaderReady: true,
            outputRunning: true, outputUID: "BlackHole2ch",
            resolvedInputUID: nil, captureEngineHealthy: true
        ) == .inputMissing &&
        LocalMicGate.block(
            enabled: true, micAuthorized: true, fnMonitorRunning: true,
            remoteSourceReaderReady: true,
            outputRunning: true, outputUID: "BlackHole2ch",
            resolvedInputUID: "BlackHole2ch", captureEngineHealthy: true
        ) == .sameDevice &&
        LocalMicGate.block(
            enabled: true, micAuthorized: true, fnMonitorRunning: true,
            remoteSourceReaderReady: true,
            outputRunning: true, outputUID: "BlackHole2ch",
            resolvedInputUID: "BuiltInMic", captureEngineHealthy: false
        ) == .captureEngine,
    "local mic gate blocks disabled, unpermitted, monitor-down, missing/looping devices, and a dead engine"
)

// MARK: No healthy RC003 F5 reader -> fail closed (round 3, blocking item 1)

check(
    LocalMicGate.block(
        enabled: true, micAuthorized: true, fnMonitorRunning: true,
        remoteSourceReaderReady: false,
        outputRunning: true, outputUID: "BlackHole2ch",
        resolvedInputUID: "BuiltInMic", captureEngineHealthy: true
    ) == .remoteReader,
    "local mic gate fails closed with no healthy RC003 F5 reader (physical Fn refused)"
)

// A missing reader is caught before output/input/engine, so it cannot be masked
// by a simultaneously-ready output — the remote-source guarantee comes first.
check(
    LocalMicGate.block(
        enabled: true, micAuthorized: true, fnMonitorRunning: true,
        remoteSourceReaderReady: false,
        outputRunning: true, outputUID: "BlackHole2ch",
        resolvedInputUID: "BlackHole2ch", captureEngineHealthy: false
    ) == .remoteReader,
    "local mic gate reports the missing reader ahead of same-device / dead-engine reasons"
)

// MARK: RC003 F5 reader selection by real HID health, not the mapping checkbox
// (round 3, blocking item 1)

// Feature off: no reader is selected regardless of HID health.
check(
    RemoteSourceReaderPolicy.targetReader(localFnMicEnabled: false, hidMonitorReading: false) == RemoteSourceReader.none &&
        RemoteSourceReaderPolicy.targetReader(localFnMicEnabled: false, hidMonitorReading: true) == RemoteSourceReader.none,
    "RC003 reader policy selects no reader while the compatibility feature is off"
)

// Custom mapping ON and HID monitor actually reading -> only the HID monitor.
check(
    RemoteSourceReaderPolicy.targetReader(localFnMicEnabled: true, hidMonitorReading: true) == .hidMonitor &&
        RemoteSourceReaderPolicy.readerReady(target: .hidMonitor, hidMonitorReading: true, standaloneHealthy: false),
    "RC003 reader policy uses only the HID monitor when it is actually reading"
)

// First install without Accessibility / runtime revocation / HID open failure:
// the HID monitor is not reading even though the user wants mapping, so the
// standalone non-seize observer is the fallback.
check(
    RemoteSourceReaderPolicy.targetReader(localFnMicEnabled: true, hidMonitorReading: false) == .standalone &&
        RemoteSourceReaderPolicy.readerReady(target: .standalone, hidMonitorReading: false, standaloneHealthy: true),
    "RC003 reader policy falls back to the standalone observer when the HID monitor is not reading"
)

// Neither reader healthy -> not ready -> the bridge must fail closed. A standalone
// target that is observing but unhealthy (match failure / revoke) is NOT ready.
check(
    !RemoteSourceReaderPolicy.readerReady(target: .standalone, hidMonitorReading: false, standaloneHealthy: false) &&
        !RemoteSourceReaderPolicy.readerReady(target: RemoteSourceReader.none, hidMonitorReading: false, standaloneHealthy: false),
    "RC003 reader policy reports not-ready (fail closed) when no reader is healthy"
)

// At most one actual reader: across the full (enabled, hidReading) matrix the
// HID monitor and the standalone observer are never both selected.
let readerMatrix: [RemoteSourceReader] = [
    RemoteSourceReaderPolicy.targetReader(localFnMicEnabled: false, hidMonitorReading: false),
    RemoteSourceReaderPolicy.targetReader(localFnMicEnabled: false, hidMonitorReading: true),
    RemoteSourceReaderPolicy.targetReader(localFnMicEnabled: true, hidMonitorReading: false),
    RemoteSourceReaderPolicy.targetReader(localFnMicEnabled: true, hidMonitorReading: true),
]
check(
    readerMatrix == [.none, RemoteSourceReader.none, .standalone, .hidMonitor],
    "RC003 reader policy selects at most one reader (HID and standalone are never both active)"
)

// MARK: Balanced F5 release on stop / switch / device removal (round 3, item 2)

// A held F5 that stops (reader stop, mapping switch, teardown) or whose device
// is removed must yield exactly one balancing .up, never leaving the source stuck.
var heldVoiceKey = RemoteVoiceKeyTracker()
_ = heldVoiceKey.update(usages: Set([RemoteVoiceFunctionMappingPolicy.remoteVoiceKeyUsage]))
let heldWasDown = heldVoiceKey.isDown
let balancedRelease = heldVoiceKey.release()
let releaseClearedState = !heldVoiceKey.isDown
let secondReleaseNoEdge = heldVoiceKey.release()
check(
    heldWasDown &&
        balancedRelease == .up &&
        releaseClearedState &&
        secondReleaseNoEdge == nil,
    "RC003 voice-key tracker emits one balancing .up on release and none when not held"
)

// End-to-end at the arbiter: a stuck-down remote source, once balanced by that
// .up, no longer suppresses a fresh physical Fn press.
var switchArbiter = LocalMicArbiter()
_ = switchArbiter.handle(.setEnabled(true))
_ = switchArbiter.handle(.setReady(true))
_ = switchArbiter.handle(.remoteSourceDown)          // RC003 F5 held on reader A
let suppressedWhileHeld = switchArbiter.handle(.physicalFnDown)
_ = switchArbiter.handle(.physicalFnUp)
_ = switchArbiter.handle(.remoteSourceUp)            // reader stop / removal emits balancing .up
let freshAfterBalancedRelease = switchArbiter.handle(.physicalFnDown)
check(
    suppressedWhileHeld == .none &&
        freshAfterBalancedRelease == .startCapture &&
        !switchArbiter.remoteSourceActive,
    "balanced .up clears remoteSourceActive so a later physical Fn is no longer suppressed"
)

// MARK: RC003 HID device lifecycle / presence / generation (round 4)
//
// The same `RemoteDeviceLifecycle` type drives both `HIDRemoteMonitor` and
// `RemoteVoiceKeyMonitor`, so these deterministic checks exercise the real
// runtime state machine, not hand-fed booleans.

// An open pipeline with no device present is a healthy watcher (Apple
// IOHIDManagerOpen semantics): reader is ready, but no device / generation yet.
var noDeviceLifecycle = RemoteDeviceLifecycle()
let readyBeforeOpen = noDeviceLifecycle.pipelineReady
noDeviceLifecycle.openPipeline()
check(
    !readyBeforeOpen &&
        noDeviceLifecycle.pipelineReady &&
        !noDeviceLifecycle.devicePresent &&
        noDeviceLifecycle.activeGeneration == nil,
    "device lifecycle: an open pipeline with no device present is a healthy watcher"
)

// A match that arrives while the pipeline is closed is ignored (stale callback).
var closedPipelineLifecycle = RemoteDeviceLifecycle()
check(
    closedPipelineLifecycle.matched(openSucceeded: true) == .ignored &&
        !closedPipelineLifecycle.devicePresent,
    "device lifecycle: a match while the pipeline is closed is ignored"
)

// A matched-but-unreadable device does not become present and does not disturb
// the (still open) watcher pipeline — the monitor fails the pipeline closed
// separately.
var matchFailureLifecycle = RemoteDeviceLifecycle()
matchFailureLifecycle.openPipeline()
let unreadableOutcome = matchFailureLifecycle.matched(openSucceeded: false)
check(
    unreadableOutcome == .unreadable &&
        !matchFailureLifecycle.devicePresent &&
        matchFailureLifecycle.pipelineReady,
    "device lifecycle: a match open-failure reports unreadable and never marks the device present"
)

// match -> present(gen1) -> report accepted -> remove invalidates gen1 first and
// yields the balancing release -> stale gen1 report ignored -> reconnect mints
// gen2, which is accepted while the superseded gen1 stays rejected.
var flowLifecycle = RemoteDeviceLifecycle()
flowLifecycle.openPipeline()
guard case let .present(generationOneDevice) = flowLifecycle.matched(openSucceeded: true) else {
    check(false, "device lifecycle: first successful match yields a generation")
    fatalError("unreachable")
}
let acceptedWhilePresent = flowLifecycle.accepts(generation: generationOneDevice)
let invalidatedGeneration = flowLifecycle.removed()
let staleRejectedAfterRemoval = !flowLifecycle.accepts(generation: generationOneDevice)
let notPresentAfterRemoval = !flowLifecycle.devicePresent
let secondRemovalNoGeneration = flowLifecycle.removed()
guard case let .present(generationTwoDevice) = flowLifecycle.matched(openSucceeded: true) else {
    check(false, "device lifecycle: reconnect yields a fresh generation")
    fatalError("unreachable")
}
check(
    acceptedWhilePresent &&
        invalidatedGeneration == generationOneDevice &&
        staleRejectedAfterRemoval &&
        notPresentAfterRemoval &&
        secondRemovalNoGeneration == nil &&
        generationTwoDevice != generationOneDevice &&
        flowLifecycle.accepts(generation: generationTwoDevice) &&
        !flowLifecycle.accepts(generation: generationOneDevice),
    "device lifecycle: removal invalidates the generation before the balancing release, drops stale reports, and a reconnect mints a new accepted generation"
)

// End-to-end with the F5 tracker: a down accepted while present, then a removal
// that invalidates the generation FIRST and balances the held key with one .up,
// after which the late (stale) report is dropped and can never re-emit a .down.
var lifecycleForTracker = RemoteDeviceLifecycle()
lifecycleForTracker.openPipeline()
guard case let .present(trackerGeneration) = lifecycleForTracker.matched(openSucceeded: true) else {
    check(false, "device lifecycle: tracker scenario match yields a generation")
    fatalError("unreachable")
}
var lifecycleTracker = RemoteVoiceKeyTracker()
let voiceKeyUsageSet = Set([RemoteVoiceFunctionMappingPolicy.remoteVoiceKeyUsage])
let downWhilePresent = lifecycleForTracker.accepts(generation: trackerGeneration)
    ? lifecycleTracker.update(usages: voiceKeyUsageSet)
    : nil
let removedGeneration = lifecycleForTracker.removed()     // invalidate FIRST
let balancedUpOnRemoval = lifecycleTracker.release()       // THEN balance the held key
let staleReportAfterRemoval = lifecycleForTracker.accepts(generation: trackerGeneration)
    ? lifecycleTracker.update(usages: voiceKeyUsageSet)    // would re-arm — must be blocked
    : nil
check(
    downWhilePresent == .down &&
        removedGeneration == trackerGeneration &&
        balancedUpOnRemoval == .up &&
        staleReportAfterRemoval == nil &&
        !lifecycleForTracker.devicePresent,
    "device lifecycle + F5 tracker: a removal invalidates the generation, balances the held key with one .up, and drops the stale post-removal report"
)

// A second match while a device is already present is ignored (no double-adopt).
var doubleMatchLifecycle = RemoteDeviceLifecycle()
doubleMatchLifecycle.openPipeline()
guard case let .present(firstAdopted) = doubleMatchLifecycle.matched(openSucceeded: true) else {
    check(false, "device lifecycle: initial adopt yields a generation")
    fatalError("unreachable")
}
let secondMatchWhilePresent = doubleMatchLifecycle.matched(openSucceeded: true)
check(
    secondMatchWhilePresent == .ignored &&
        doubleMatchLifecycle.accepts(generation: firstAdopted),
    "device lifecycle: a second match while a device is present is ignored"
)

// Closing the pipeline drops any present device and its generation (stop /
// mapping switch / revocation / open-failure fail-close).
var closingLifecycle = RemoteDeviceLifecycle()
closingLifecycle.openPipeline()
guard case let .present(beforeClose) = closingLifecycle.matched(openSucceeded: true) else {
    check(false, "device lifecycle: adopt before close yields a generation")
    fatalError("unreachable")
}
closingLifecycle.closePipeline()
check(
    !closingLifecycle.pipelineReady &&
        !closingLifecycle.devicePresent &&
        !closingLifecycle.accepts(generation: beforeClose),
    "device lifecycle: closing the pipeline drops the present device, its generation, and reader readiness"
)

// MARK: Standalone RC003 F5 reader health closed loop (round 5)
//
// `StandaloneReaderHealth` is the exact type `RemoteVoiceKeyMonitor` runs, so
// these deterministic checks exercise the real health state machine — separating
// "observing" (the watcher is open) from "healthy" (safe to trust as the F5
// pre-marker) — not hand-fed booleans. They pair with the reader policy above,
// which turns `isHealthy` into `readerReady`.

// No device: an open pipeline is an observing, healthy watcher (Apple
// IOHIDManagerOpen semantics) with no generation.
var healthNoDevice = StandaloneReaderHealth()
let healthyBeforeOpen = healthNoDevice.isHealthy
healthNoDevice.opened()
check(
    !healthyBeforeOpen &&
        healthNoDevice.isObserving &&
        healthNoDevice.isHealthy &&
        !healthNoDevice.devicePresent &&
        healthNoDevice.activeGeneration == nil,
    "standalone health: an open watcher with no device present is observing and healthy"
)

// Match failure -> observing stays TRUE (so the coordinator will NOT restart it
// in a loop) but healthy is FALSE, so the reader-policy readerReady is false and
// the local mic path fails closed.
var healthMatchFailure = StandaloneReaderHealth()
healthMatchFailure.opened()
let matchFailureOutcome = healthMatchFailure.matched(openSucceeded: false)
let policyReadyOnUnreadable = RemoteSourceReaderPolicy.readerReady(
    target: .standalone,
    hidMonitorReading: false,
    standaloneHealthy: healthMatchFailure.isHealthy
)
check(
    matchFailureOutcome == .unreadable &&
        healthMatchFailure.isObserving &&        // observing -> coordinator does not re-start
        !healthMatchFailure.isHealthy &&         // unhealthy -> readerReady false
        !healthMatchFailure.devicePresent &&
        !policyReadyOnUnreadable,
    "standalone health: a match failure stays observing but unhealthy, so the reader policy is not ready (no restart loop)"
)

// Failed-device removal recovers health: once the unreadable device leaves, the
// block clears and the watcher is healthy again.
var healthRemovalRecovery = StandaloneReaderHealth()
healthRemovalRecovery.opened()
_ = healthRemovalRecovery.matched(openSucceeded: false)   // unreadable, unhealthy
let unhealthyWhileStuck = !healthRemovalRecovery.isHealthy
healthRemovalRecovery.clearUnreadable()                    // that exact device removed
check(
    unhealthyWhileStuck &&
        healthRemovalRecovery.isObserving &&
        healthRemovalRecovery.isHealthy &&
        !healthRemovalRecovery.devicePresent,
    "standalone health: removing the unreadable device clears the block and recovers health"
)

// A later successful match supersedes a prior unreadable block (readable device
// wins) and mints a generation.
var healthSupersede = StandaloneReaderHealth()
healthSupersede.opened()
_ = healthSupersede.matched(openSucceeded: false)          // unreadable
guard case let .present(supersedeGen) = healthSupersede.matched(openSucceeded: true) else {
    check(false, "standalone health: a readable match should supersede the unreadable block")
    fatalError("unreachable")
}
check(
    healthSupersede.isHealthy &&
        healthSupersede.devicePresent &&
        healthSupersede.accepts(generation: supersedeGen),
    "standalone health: a readable match supersedes a prior unreadable block and becomes healthy"
)

// Permission revoke -> unhealthy (still observing). Restore REQUIRES a reopen:
// a bare permission flip is not exposed, so the only way back to healthy is
// opened() after closed(). A reopen whose open fails (closed without opened)
// stays unhealthy.
var healthRevoke = StandaloneReaderHealth()
healthRevoke.opened()
healthRevoke.revokePermission()
let unhealthyAfterRevoke = !healthRevoke.isHealthy && healthRevoke.isObserving
// Reopen that fails to open (permission flapped): close, no open -> stays false.
var healthReopenFail = healthRevoke
healthReopenFail.closed()
let stillUnhealthyOnFailedReopen = !healthReopenFail.isHealthy && !healthReopenFail.isObserving
// Reopen that succeeds: close then open -> healthy again.
var healthReopenOK = healthRevoke
healthReopenOK.closed()
healthReopenOK.opened()
check(
    unhealthyAfterRevoke &&
        stillUnhealthyOnFailedReopen &&
        healthReopenOK.isHealthy &&
        healthReopenOK.isObserving,
    "standalone health: a runtime revoke fails closed and recovery requires a successful reopen (a failed reopen stays unhealthy)"
)

// Unhealthy / stale reports are rejected at execution. A report gate of
// (isHealthy && accepts(generation)) must reject both a stale generation (after
// removal) and a report that arrives after a permission revoke while the device
// is still present — a permission-failed report can never emit a .down.
var healthReportGate = StandaloneReaderHealth()
healthReportGate.opened()
guard case let .present(gateGen) = healthReportGate.matched(openSucceeded: true) else {
    check(false, "standalone health: report-gate match should yield a generation")
    fatalError("unreachable")
}
let acceptedWhileHealthy = healthReportGate.isHealthy && healthReportGate.accepts(generation: gateGen)
// Permission revoked between snapshot and execution: device still present, but
// the report must be dropped.
var healthReportRevoked = healthReportGate
healthReportRevoked.revokePermission()
let rejectedAfterRevoke = !(healthReportRevoked.isHealthy && healthReportRevoked.accepts(generation: gateGen))
let stillPresentAfterRevoke = healthReportRevoked.devicePresent
// Device removed: the snapshotted generation is no longer accepted.
var healthReportRemoved = healthReportGate
_ = healthReportRemoved.removed()
let rejectedAfterRemoval = !(healthReportRemoved.isHealthy && healthReportRemoved.accepts(generation: gateGen))
check(
    acceptedWhileHealthy &&
        rejectedAfterRevoke &&
        stillPresentAfterRevoke &&
        rejectedAfterRemoval,
    "standalone health: the report gate accepts only while healthy and current, rejecting revoked and stale reports"
)

// Generation reuse from the embedded lifecycle: present -> remove -> reconnect
// mints a fresh accepted generation while the superseded one stays rejected
// (same guarantee the HID reader has, proven on the standalone health type).
var healthGeneration = StandaloneReaderHealth()
healthGeneration.opened()
guard case let .present(healthGen1) = healthGeneration.matched(openSucceeded: true) else {
    check(false, "standalone health: first match should yield a generation")
    fatalError("unreachable")
}
let healthRemovedGen = healthGeneration.removed()
let healthStaleRejected = !healthGeneration.accepts(generation: healthGen1)
guard case let .present(healthGen2) = healthGeneration.matched(openSucceeded: true) else {
    check(false, "standalone health: reconnect should yield a fresh generation")
    fatalError("unreachable")
}
check(
    healthRemovedGen == healthGen1 &&
        healthStaleRejected &&
        healthGen2 != healthGen1 &&
        healthGeneration.accepts(generation: healthGen2) &&
        !healthGeneration.accepts(generation: healthGen1),
    "standalone health: removal invalidates the generation and a reconnect mints a fresh accepted one"
)

// End-to-end with the F5 tracker: a key down while healthy+present, then a
// permission revoke that flips health false and balances the held key with one
// .up; a still-queued report is then dropped by the (isHealthy && accepts) gate
// and can never re-emit a .down while permission is gone.
var healthTrackerLifecycle = StandaloneReaderHealth()
healthTrackerLifecycle.opened()
guard case let .present(healthTrackerGen) = healthTrackerLifecycle.matched(openSucceeded: true) else {
    check(false, "standalone health: tracker scenario match should yield a generation")
    fatalError("unreachable")
}
var healthTracker = RemoteVoiceKeyTracker()
let healthVoiceUsage = Set([RemoteVoiceFunctionMappingPolicy.remoteVoiceKeyUsage])
let downWhileHealthy = (healthTrackerLifecycle.isHealthy && healthTrackerLifecycle.accepts(generation: healthTrackerGen))
    ? healthTracker.update(usages: healthVoiceUsage)
    : nil
healthTrackerLifecycle.revokePermission()          // runtime revoke
let balancedUpOnRevoke = healthTracker.release()   // balance the held key
let droppedReportAfterRevoke = (healthTrackerLifecycle.isHealthy && healthTrackerLifecycle.accepts(generation: healthTrackerGen))
    ? healthTracker.update(usages: healthVoiceUsage)   // would re-arm — must be blocked
    : nil
check(
    downWhileHealthy == .down &&
        balancedUpOnRevoke == .up &&
        droppedReportAfterRevoke == nil &&
        !healthTrackerLifecycle.isHealthy,
    "standalone health + F5 tracker: a runtime revoke fails closed, balances the held key with one .up, and drops the post-revoke report"
)

// MARK: - RC003 voice-key double-click bridge toggle (XRBM-017)

// Two complete short taps whose downs fall within the window toggle exactly once,
// then the detector returns to idle (a following lone tap does not toggle).
var dcTwoTaps = RemoteBridgeToggleGestureDetector()
let dcT1 = dcTwoTaps.handle(.down, nowMs: 0)     // first down
let dcT2 = dcTwoTaps.handle(.up, nowMs: 100)     // first short tap (100ms)
let dcT3 = dcTwoTaps.handle(.down, nowMs: 200)   // second down (200ms <= 350 window)
let dcT4 = dcTwoTaps.handle(.up, nowMs: 300)     // second short tap (100ms) -> toggle
check(
    !dcT1 && !dcT2 && !dcT3 && dcT4,
    "double-click: two valid short taps within the window toggle exactly once"
)
// A third quick tap right after the toggle does not toggle again on its own.
let dcT5 = dcTwoTaps.handle(.down, nowMs: 380)
let dcT6 = dcTwoTaps.handle(.up, nowMs: 440)
check(
    !dcT5 && !dcT6,
    "double-click: a third quick tap after a completed toggle does not toggle again"
)

// A long-press tap (hold-to-talk) never counts as a tap and never arms a pair.
var dcLongFirst = RemoteBridgeToggleGestureDetector()
let dcL1 = dcLongFirst.handle(.down, nowMs: 0)
let dcL2 = dcLongFirst.handle(.up, nowMs: 400)   // 400ms > 250 -> long press, not a tap
let dcL3 = dcLongFirst.handle(.down, nowMs: 450) // fresh first tap
let dcL4 = dcLongFirst.handle(.up, nowMs: 520)
check(
    !dcL1 && !dcL2 && !dcL3 && !dcL4,
    "double-click: a long-press tap never toggles and does not arm a following pair"
)

// A long second press does not toggle.
var dcLongSecond = RemoteBridgeToggleGestureDetector()
_ = dcLongSecond.handle(.down, nowMs: 0)
_ = dcLongSecond.handle(.up, nowMs: 100)
_ = dcLongSecond.handle(.down, nowMs: 200)
let dcLongSecondToggle = dcLongSecond.handle(.up, nowMs: 700) // 500ms hold -> no toggle
check(!dcLongSecondToggle, "double-click: a long second press does not toggle")

// A single short tap alone does not toggle.
var dcSingle = RemoteBridgeToggleGestureDetector()
let dcS1 = dcSingle.handle(.down, nowMs: 0)
let dcS2 = dcSingle.handle(.up, nowMs: 120)
check(!dcS1 && !dcS2, "double-click: a single short tap does not toggle")

// A slow second tap (second down past the window) becomes a fresh first tap.
var dcSlow = RemoteBridgeToggleGestureDetector()
_ = dcSlow.handle(.down, nowMs: 0)
_ = dcSlow.handle(.up, nowMs: 100)
let dcSlow1 = dcSlow.handle(.down, nowMs: 500)   // 500 > 350 window -> restart
let dcSlow2 = dcSlow.handle(.up, nowMs: 560)
check(
    !dcSlow1 && !dcSlow2,
    "double-click: a slow second tap past the window becomes a fresh first tap, no toggle"
)

// A repeated down with no intervening up does not toggle.
var dcRepeat = RemoteBridgeToggleGestureDetector()
_ = dcRepeat.handle(.down, nowMs: 0)
let dcRepeat1 = dcRepeat.handle(.down, nowMs: 50)  // repeated down -> restart first tap
let dcRepeat2 = dcRepeat.handle(.up, nowMs: 100)
check(
    !dcRepeat1 && !dcRepeat2,
    "double-click: a repeated down with no intervening up does not toggle"
)

// reset() drops the in-flight gesture so a late edge cannot finish an old toggle
// (reader unhealthy, device generation change, app stop, permission loss).
var dcReset = RemoteBridgeToggleGestureDetector()
_ = dcReset.handle(.down, nowMs: 0)
_ = dcReset.handle(.up, nowMs: 100)   // first short tap pending
dcReset.reset()
let dcReset1 = dcReset.handle(.down, nowMs: 200)   // would have been the second tap
let dcReset2 = dcReset.handle(.up, nowMs: 260)
check(
    !dcReset1 && !dcReset2,
    "double-click: reset drops the in-flight gesture so a late edge cannot complete an old toggle"
)

// After a disable the very same gesture toggles again to restore.
var dcRestore = RemoteBridgeToggleGestureDetector()
_ = dcRestore.handle(.down, nowMs: 0)
_ = dcRestore.handle(.up, nowMs: 80)
_ = dcRestore.handle(.down, nowMs: 150)
let dcRestoreDisable = dcRestore.handle(.up, nowMs: 220)      // toggle #1 (disable)
_ = dcRestore.handle(.down, nowMs: 1000)
_ = dcRestore.handle(.up, nowMs: 1080)
_ = dcRestore.handle(.down, nowMs: 1150)
let dcRestoreEnable = dcRestore.handle(.up, nowMs: 1220)      // toggle #2 (restore)
check(
    dcRestoreDisable && dcRestoreEnable,
    "double-click: the same gesture toggles again to restore after a disable"
)

// Boundaries: window == 350 and each tap == 250 still toggle (inclusive bounds).
var dcBoundary = RemoteBridgeToggleGestureDetector()
_ = dcBoundary.handle(.down, nowMs: 0)
_ = dcBoundary.handle(.up, nowMs: 250)    // tap exactly 250ms
_ = dcBoundary.handle(.down, nowMs: 350)  // second down exactly at the 350 window
let dcBoundaryToggle = dcBoundary.handle(.up, nowMs: 600) // tap exactly 250ms
check(dcBoundaryToggle, "double-click: inclusive boundaries (window==350, tap==250) still toggle")

// One millisecond past the window does not toggle.
var dcOver = RemoteBridgeToggleGestureDetector()
_ = dcOver.handle(.down, nowMs: 0)
_ = dcOver.handle(.up, nowMs: 100)
_ = dcOver.handle(.down, nowMs: 351)      // 351 > 350 window -> restart
let dcOverToggle = dcOver.handle(.up, nowMs: 400)
check(!dcOverToggle, "double-click: a second down one ms past the window does not toggle")

// The standalone F5 reader is needed whenever either consumer wants the edge (the
// local-Fn mic feature OR the double-click toggle); none when both are off.
check(
    RemoteSourceReaderPolicy.targetReader(
        localFnMicEnabled: false, doubleClickEnabled: true, hidMonitorReading: false
    ) == .standalone &&
        RemoteSourceReaderPolicy.targetReader(
            localFnMicEnabled: false, doubleClickEnabled: true, hidMonitorReading: true
        ) == .hidMonitor &&
        RemoteSourceReaderPolicy.targetReader(
            localFnMicEnabled: false, doubleClickEnabled: false, hidMonitorReading: true
        ) == RemoteSourceReader.none,
    "double-click reader: needed when either consumer wants the edge, none when both off"
)

// Full suppression of ordinary keys is only guaranteed with custom mapping ON and
// an exclusive (seized) read; otherwise the UI must warn native behaviour remains.
check(
    BridgeSuppressionScope.isFullSuppression(customMappingEnabled: true, exclusivelyReading: true) &&
        !BridgeSuppressionScope.isFullSuppression(customMappingEnabled: true, exclusivelyReading: false) &&
        !BridgeSuppressionScope.isFullSuppression(customMappingEnabled: false, exclusivelyReading: true) &&
        !BridgeSuppressionScope.isFullSuppression(customMappingEnabled: false, exclusivelyReading: false),
    "bridge suppression scope: full only with custom mapping ON and an exclusive read"
)

// The ATVV voice gate lets voice through only while bridging is enabled.
check(
    ATVVVoiceBridgeGate.allowsVoice(bridgingEnabled: true) &&
        !ATVVVoiceBridgeGate.allowsVoice(bridgingEnabled: false),
    "ATVV voice gate: allows the voice path only while bridging is enabled"
)

// MARK: - Forced-release ordering: a synthetic .up must not toggle (XRBM-017 RETRY)

// The forced-release contract always orders the gesture invalidation before any
// balancing .up, and only emits the .up when the key is actually held.
check(
    RemoteVoiceKeyForcedRelease.effects(keyHeld: true) == [.invalidateGesture, .balancingUp] &&
        RemoteVoiceKeyForcedRelease.effects(keyHeld: false) == [.invalidateGesture],
    "forced release: gesture invalidation is always ordered before any balancing .up"
)

// Baseline / no-suppression proof: a GENUINE report .up in secondDown still
// completes the double-click. This is exactly the edge the forced-release path
// must NOT let a synthetic .up reproduce.
var frGenuine = RemoteBridgeToggleGestureDetector()
_ = frGenuine.handle(.down, nowMs: 0)
_ = frGenuine.handle(.up, nowMs: 80)
_ = frGenuine.handle(.down, nowMs: 150) // secondDown, key held
check(
    frGenuine.handle(.up, nowMs: 210),
    "forced release: a genuine report .up in secondDown still toggles (genuine ups are not suppressed)"
)

// Helper: applies a reader's forced release exactly as BridgeAppModel wires it —
// onGestureInvalidate resets ONLY the detector; the balancing .up then reaches
// both the (now idle) detector and the local-mic arbiter. Returns whether the
// detector toggled (it must not for a forced release).
func applyForcedRelease(
    keyHeld: Bool,
    detector: inout RemoteBridgeToggleGestureDetector,
    arbiter: inout LocalMicArbiter,
    nowMs: UInt64
) -> Bool {
    var toggled = false
    for effect in RemoteVoiceKeyForcedRelease.effects(keyHeld: keyHeld) {
        switch effect {
        case .invalidateGesture:
            detector.reset()
        case .balancingUp:
            if detector.handle(.up, nowMs: nowMs) { toggled = true }
            _ = arbiter.handle(.remoteSourceUp)
        }
    }
    return toggled
}

// Helper: a detector driven into secondDown with the key currently held.
func detectorInSecondDown() -> RemoteBridgeToggleGestureDetector {
    var detector = RemoteBridgeToggleGestureDetector()
    _ = detector.handle(.down, nowMs: 0)
    _ = detector.handle(.up, nowMs: 80)
    _ = detector.handle(.down, nowMs: 150)
    return detector
}

// Device removal during secondDown (present-device removal does NOT flip reader
// health): the synthetic .up must not toggle, yet the arbiter's remote-source
// marker is still released.
var frRemovalDetector = detectorInSecondDown()
var frRemovalArbiter = LocalMicArbiter()
_ = frRemovalArbiter.handle(.remoteSourceDown) // remote source held
let frRemovalToggled = applyForcedRelease(
    keyHeld: true, detector: &frRemovalDetector, arbiter: &frRemovalArbiter, nowMs: 210
)
check(
    !frRemovalToggled && !frRemovalArbiter.remoteSourceActive,
    "forced release (device removal) during secondDown: no false toggle, local remote-source release still occurs"
)

// Permission revoke during secondDown.
var frRevokeDetector = detectorInSecondDown()
var frRevokeArbiter = LocalMicArbiter()
_ = frRevokeArbiter.handle(.remoteSourceDown)
let frRevokeToggled = applyForcedRelease(
    keyHeld: true, detector: &frRevokeDetector, arbiter: &frRevokeArbiter, nowMs: 210
)
check(
    !frRevokeToggled && !frRevokeArbiter.remoteSourceActive,
    "forced release (permission revoke) during secondDown: no false toggle, local remote-source release still occurs"
)

// Forced stop / fail-close during secondDown.
var frStopDetector = detectorInSecondDown()
var frStopArbiter = LocalMicArbiter()
_ = frStopArbiter.handle(.remoteSourceDown)
let frStopToggled = applyForcedRelease(
    keyHeld: true, detector: &frStopDetector, arbiter: &frStopArbiter, nowMs: 210
)
check(
    !frStopToggled && !frStopArbiter.remoteSourceActive,
    "forced release (stop / fail-close) during secondDown: no false toggle, local remote-source release still occurs"
)

// Generation change with UNCHANGED reader health while the key is held (secondDown):
// same guarantee — the synthetic .up cannot toggle.
var frGenHeldDetector = detectorInSecondDown()
var frGenHeldArbiter = LocalMicArbiter()
_ = frGenHeldArbiter.handle(.remoteSourceDown)
let frGenHeldToggled = applyForcedRelease(
    keyHeld: true, detector: &frGenHeldDetector, arbiter: &frGenHeldArbiter, nowMs: 210
)
check(
    !frGenHeldToggled && !frGenHeldArbiter.remoteSourceActive,
    "forced release (generation change, unchanged health) during secondDown: no false toggle, local release still occurs"
)

// Generation change with UNCHANGED health while the key is NOT held (detector in
// firstReleased): the invalidation alone (no balancing .up) drops the pending first
// tap, so a later in-window tap cannot complete an old double-click.
var frGenIdleDetector = RemoteBridgeToggleGestureDetector()
_ = frGenIdleDetector.handle(.down, nowMs: 0)
_ = frGenIdleDetector.handle(.up, nowMs: 80) // firstReleased, key not held
var frGenIdleArbiter = LocalMicArbiter()
let frGenIdleToggled = applyForcedRelease(
    keyHeld: false, detector: &frGenIdleDetector, arbiter: &frGenIdleArbiter, nowMs: 150
)
let frGenIdleAfterDown = frGenIdleDetector.handle(.down, nowMs: 200) // would-be second tap
let frGenIdleAfterUp = frGenIdleDetector.handle(.up, nowMs: 260)
check(
    !frGenIdleToggled && !frGenIdleAfterDown && !frGenIdleAfterUp,
    "generation change (unchanged health) while key not held drops the pending first tap; a later tap cannot complete an old double-click"
)

// MARK: - Disabled-bridge status tracks the reader's seize mode (XRBM-017 review)

// The disabled-bridge status carries the native-key degradation warning exactly
// when suppression is not full, so it depends on the reader's exclusive/monitored
// mode as well as custom mapping. Enabled and mapping-restore-failed cases are
// pinned too.
check(
    BridgeRuntimeStatusText.text(
        enabled: true, mappingRestoreFailed: false, customMappingEnabled: false, exclusivelyReading: false
    ) == BridgeRuntimeStatusText.enabled &&
        BridgeRuntimeStatusText.text(
            enabled: false, mappingRestoreFailed: true, customMappingEnabled: true, exclusivelyReading: true
        ) == BridgeRuntimeStatusText.mappingRestoreFailed &&
        BridgeRuntimeStatusText.text(
            enabled: false, mappingRestoreFailed: false, customMappingEnabled: true, exclusivelyReading: true
        ) == BridgeRuntimeStatusText.disabled &&
        BridgeRuntimeStatusText.text(
            enabled: false, mappingRestoreFailed: false, customMappingEnabled: true, exclusivelyReading: false
        ) == BridgeRuntimeStatusText.nativeKeysMayRemain &&
        BridgeRuntimeStatusText.text(
            enabled: false, mappingRestoreFailed: false, customMappingEnabled: false, exclusivelyReading: true
        ) == BridgeRuntimeStatusText.nativeKeysMayRemain,
    "bridge status: disabled native-key warning tracks seize mode (seized+mapping => full; monitored or mapping-off => warning)"
)

// The exact reconnect flip the coordinator must catch: with the bridge disabled and
// custom mapping ON, changing ONLY `exclusivelyReading` (a seize-mode change that
// does not flip reader health) changes the status text — proving a device
// match/removal must refresh it, not only a health flip.
check(
    BridgeRuntimeStatusText.text(
        enabled: false, mappingRestoreFailed: false, customMappingEnabled: true, exclusivelyReading: true
    ) != BridgeRuntimeStatusText.text(
        enabled: false, mappingRestoreFailed: false, customMappingEnabled: true, exclusivelyReading: false
    ),
    "bridge status: a seize-mode change alone (health unchanged) changes the disabled status, so match/removal must refresh it"
)

// MARK: - External microphone product identity

check(
    ExternalMicrophoneProfile.isDJIMic2(displayName: "DJI-MIC2-ABCDEF Hands-Free") &&
        ExternalMicrophoneProfile.isDJIMic2(displayName: "DJI Mic 2") &&
        ExternalMicrophoneProfile.isDJIMic2(displayName: "DJI Mic2 (Bluetooth)"),
    "DJI Mic 2 identity: accepts known CoreAudio display-name forms without depending on suffix"
)
check(
    !ExternalMicrophoneProfile.isDJIMic2(displayName: "DJI-MIC20") &&
        !ExternalMicrophoneProfile.isDJIMic2(displayName: "DJI Mic Mini") &&
        !ExternalMicrophoneProfile.isDJIMic2(displayName: "Built-in Microphone"),
    "DJI Mic 2 identity: rejects lookalikes and unrelated microphones"
)

print("RESULT passed=\(passed) failed=\(failed)")
if failed > 0 {
    exit(1)
}
