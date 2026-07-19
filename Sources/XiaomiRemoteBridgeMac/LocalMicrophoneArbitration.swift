import Foundation

// MARK: - Local microphone arbitration

/// Events that drive the local (Mac built-in) microphone compatibility path.
///
/// The arbiter is deliberately pure and side-effect free so that the priority
/// rules (RC003 always wins, idempotent edges, no restart on a residual Fn, and
/// fail-closed teardown) can be proven with synchronous tests instead of real
/// hardware.
enum LocalMicEvent: Equatable {
    /// The user toggled the "compatible Mac keyboard Fn" switch.
    case setEnabled(Bool)
    /// Runtime readiness recomputed: microphone permission granted, an output
    /// device is running, the Fn monitor is live, and input != output.
    case setReady(Bool)
    /// Physical Fn/Globe key edge on the Mac keyboard. This also fires for the
    /// RC003-mapped Fn, so it is NOT trusted on its own — see `remoteSource*`.
    case physicalFnDown
    case physicalFnUp
    /// RC003 microphone (F5) key edge read directly from the remote's HID
    /// report. This is the reliable "remote source" pre-marker: it is set from
    /// the same physical press that the system remaps into an Fn edge, so it
    /// gates and preempts the local mic without any timing guess.
    case remoteSourceDown
    case remoteSourceUp
    /// RC003 ATVV voice-stream boundaries. Kept as a second, independent preempt
    /// source (defence in depth) in case the HID edge is unavailable.
    case remoteVoiceStart
    case remoteVoiceStop
    /// The Fn event tap was disrupted (disabled/invalidated). Force-release the
    /// current cycle so a stuck Fn cannot keep the mic open.
    case functionMonitorDisrupted
    /// App stop / fail-closed reset.
    case teardown
}

/// The side effect the runtime must apply after handling an event.
enum LocalMicCommand: Equatable {
    case none
    case startCapture
    case stopCapture
}

/// Pure state machine that decides when the local microphone may be captured.
///
/// Invariants:
/// - Capture only *begins* on a fresh `physicalFnDown` edge while enabled,
///   ready, and neither RC003 source (HID F5 nor ATVV) is active. Nothing else
///   starts capture.
/// - Either RC003 signal (`remoteSourceDown` / `remoteVoiceStart`) always
///   preempts and stops the local mic.
/// - `remoteSourceUp` / `remoteVoiceStop` never restart the local mic, so a
///   physical Fn still held when the remote finishes cannot re-open the built-in
///   mic; the user must release and press Fn again.
/// - Disabling, losing readiness, an Fn-monitor disruption, or teardown all stop
///   capture (fail closed). Disabling and teardown also clear `fnHeld` so a
///   later re-enable is not left thinking Fn is still down (which would swallow
///   the next full key cycle).
struct LocalMicArbiter {
    private(set) var enabled = false
    private(set) var ready = false
    private(set) var fnHeld = false
    private(set) var remoteVoiceActive = false
    private(set) var remoteSourceActive = false
    private(set) var capturing = false

    /// Any active RC003 source (HID key still held or ATVV stream running).
    var remoteActive: Bool { remoteVoiceActive || remoteSourceActive }

    private var canStartOnFnDown: Bool { enabled && ready && !remoteActive }

    mutating func handle(_ event: LocalMicEvent) -> LocalMicCommand {
        switch event {
        case .setEnabled(let value):
            enabled = value
            guard !value else { return .none }
            // Disabling stops the Fn tap and the RC003 HID observer, so their
            // pending release edges will never arrive — clear that transient
            // state now to stay in sync with the freshly reset monitors. The
            // ATVV `remoteVoiceActive` flag is kept live by the bridge, so it is
            // left untouched here.
            fnHeld = false
            remoteSourceActive = false
            return stopIfCapturing()
        case .setReady(let value):
            ready = value
            return value ? .none : stopIfCapturing()
        case .physicalFnDown:
            guard !fnHeld else { return .none }
            fnHeld = true
            guard canStartOnFnDown, !capturing else { return .none }
            capturing = true
            return .startCapture
        case .physicalFnUp:
            guard fnHeld else { return .none }
            fnHeld = false
            return stopIfCapturing()
        case .remoteSourceDown:
            remoteSourceActive = true
            return stopIfCapturing()
        case .remoteSourceUp:
            remoteSourceActive = false
            return .none
        case .remoteVoiceStart:
            remoteVoiceActive = true
            return stopIfCapturing()
        case .remoteVoiceStop:
            remoteVoiceActive = false
            return .none
        case .functionMonitorDisrupted:
            fnHeld = false
            return stopIfCapturing()
        case .teardown:
            fnHeld = false
            remoteVoiceActive = false
            remoteSourceActive = false
            return stopIfCapturing()
        }
    }

    private mutating func stopIfCapturing() -> LocalMicCommand {
        guard capturing else { return .none }
        capturing = false
        return .stopCapture
    }
}

// MARK: - RC003 microphone (F5) key edge detection

/// Converts successive RC003 HID usage sets into microphone-key press/release
/// edges. Repeated reports with the same held/not-held state are idempotent.
struct RemoteVoiceKeyTracker {
    private(set) var isDown = false

    mutating func update(usages: Set<UInt16>) -> RemoteEventEdge? {
        let present = usages.contains(RemoteVoiceFunctionMappingPolicy.remoteVoiceKeyUsage)
        if present {
            guard !isDown else { return nil }
            isDown = true
            return .down
        }
        guard isDown else { return nil }
        isDown = false
        return .up
    }

    /// Returns a balancing `.up` edge (and clears the held state) when the key is
    /// currently down, so a reader `stop()`, a device removal, or a reader switch
    /// mid-press can never strand the arbiter with `remoteSourceActive` stuck
    /// true. Returns `nil` when the key is not held.
    mutating func release() -> RemoteEventEdge? {
        guard isDown else { return nil }
        isDown = false
        return .up
    }

    mutating func reset() {
        isDown = false
    }
}

// MARK: - RC003 HID device lifecycle / presence / generation

/// The outcome of an IOHID device-matched callback, so the impure monitor knows
/// whether to adopt the device, fail the pipeline, or ignore a stale match.
enum RemoteDeviceMatchOutcome: Equatable {
    /// The match arrived while the pipeline was closed, or a device is already
    /// owned under a live generation — ignore it.
    case ignored
    /// The device matched but could not be opened/read. The present target device
    /// is not readable, so the monitor must NOT keep claiming to be a healthy F5
    /// reader: the caller fails the pipeline closed (which flips reader health and
    /// lets the coordinator fall back to the other reader or fail closed).
    case unreadable
    /// The device is now present and readable under a fresh generation. Only input
    /// reports tagged with this generation are trusted.
    case present(generation: UInt64)
}

/// Pure lifecycle model shared by `HIDRemoteMonitor` and `RemoteVoiceKeyMonitor`.
///
/// It separates two facts that earlier rounds conflated:
/// - `pipelineReady`: the IOHIDManager is open. Per Apple's `IOHIDManagerOpen`
///   semantics an open manager watches the current AND all future matching
///   devices, so an open pipeline with *no device present* is still a healthy
///   watcher — a missing RC003 must NOT disable the physical-Fn path. Reader
///   health therefore tracks pipeline open/close (and a match open-failure, which
///   the impure monitor turns into a pipeline close), never mere device presence.
/// - `devicePresent` / `activeGeneration`: a matched device that opened
///   successfully is present and its input reports are trusted under a monotonic
///   generation. Removal invalidates the generation *before* any balancing
///   release, so a late report tagged with the old generation is dropped and can
///   never re-open the key after the balanced `.up`. A reconnect mints a new
///   generation, and reports tagged with a superseded generation stay rejected.
///
/// The type is deliberately pure and side-effect free so the presence/generation
/// rules can be proven with synchronous tests exercising the *same* type both
/// monitors run, rather than hand-fed booleans.
struct RemoteDeviceLifecycle {
    private(set) var pipelineOpen = false
    private(set) var activeGeneration: UInt64?
    private var counter: UInt64 = 0

    /// A matched device is currently present and readable.
    var devicePresent: Bool { activeGeneration != nil }

    /// The pipeline is open, i.e. a healthy watcher for the current and all future
    /// matching devices. True even with no device present (Apple watcher
    /// semantics); false only when the manager is closed (mapping off, permission
    /// gate, open failure, or revocation).
    var pipelineReady: Bool { pipelineOpen }

    /// The IOHIDManager opened successfully: begin watching. Clears any stale
    /// device generation from a prior session.
    mutating func openPipeline() {
        pipelineOpen = true
        activeGeneration = nil
    }

    /// The IOHIDManager was closed (stop, mapping switch, revocation, or a match
    /// open-failure fail-close): no watcher and no present device.
    mutating func closePipeline() {
        pipelineOpen = false
        activeGeneration = nil
    }

    /// A device-matched callback fired. `openSucceeded` is whether the device
    /// could actually be opened/read. Adopts a fresh generation on success;
    /// reports `.unreadable` on failure (state unchanged — the caller fails the
    /// pipeline); ignores a stale match after close or while a device is owned.
    mutating func matched(openSucceeded: Bool) -> RemoteDeviceMatchOutcome {
        guard pipelineOpen, activeGeneration == nil else { return .ignored }
        guard openSucceeded else { return .unreadable }
        counter &+= 1
        activeGeneration = counter
        return .present(generation: counter)
    }

    /// A device-removal callback fired for the present device. Invalidates the
    /// generation *first* (returns it so the caller can drop per-device state and
    /// then emit a balancing release); returns `nil` when no device was present.
    mutating func removed() -> UInt64? {
        guard let generation = activeGeneration else { return nil }
        activeGeneration = nil
        return generation
    }

    /// Whether an input report captured under `generation` is still from the
    /// present device. Reports from a removed or superseded generation are dropped
    /// so a late report can never re-open the key after a balancing release.
    func accepts(generation: UInt64) -> Bool {
        activeGeneration == generation
    }
}

// MARK: - Standalone RC003 F5 reader health

/// Pure health/lifecycle model for the *standalone* RC003 microphone-key (F5)
/// observer (`RemoteVoiceKeyMonitor`). It separates two facts round 4 conflated:
///
/// - `isObserving`: the IOHIDManager is open and watching (a healthy *watcher*
///   for the current and all future RC003 devices, per Apple `IOHIDManagerOpen`
///   semantics). Observing alone does NOT mean the reader is safe to trust as an
///   F5 pre-marker: a matched device may be unreadable, or Input Monitoring may
///   have been revoked at runtime.
/// - `isHealthy`: the reader is currently safe — it is observing AND Input
///   Monitoring is still granted AND no matched device is stuck unreadable. Only
///   while this is true may the coordinator report `readerReady` for the
///   standalone target; the local mic path fails closed otherwise.
///
/// The presence/generation facts come from an embedded `RemoteDeviceLifecycle`
/// (the same type `HIDRemoteMonitor` runs), so a removed/superseded report is
/// dropped exactly as in the HID path. The type is deliberately pure and
/// side-effect free so the health rules can be proven with synchronous tests
/// exercising the *same* type the real monitor runs, not hand-fed booleans.
///
/// Recovery is intentionally structural, not a bare flag flip:
/// - Permission health can become true ONLY via `opened()` (a genuine reopen).
///   After `revokePermission()` there is no path back to healthy that skips
///   reopening/verifying the manager — a stale manager is never re-blessed.
/// - A matched-but-unreadable device blocks health until its removal clears it
///   (`clearUnreadable()`), so recovery waits for the device to leave/return
///   rather than spinning on re-open attempts. A later successful match also
///   clears the block (a readable device supersedes the unreadable one).
struct StandaloneReaderHealth {
    private var lifecycle = RemoteDeviceLifecycle()
    private(set) var permissionHealthy = false
    /// A matched device failed to open and is still present, blocking health.
    private(set) var deviceUnreadable = false

    /// The manager is open and watching (regardless of whether it is currently
    /// safe). The coordinator restarts the observer only when this is false, so a
    /// match-failure/revoke unhealthy state cannot make it restart in a loop.
    var isObserving: Bool { lifecycle.pipelineReady }

    /// The reader is currently safe to trust as the F5 pre-marker source.
    var isHealthy: Bool { isObserving && permissionHealthy && !deviceUnreadable }

    /// The present-device generation, or `nil` when no device is present.
    var activeGeneration: UInt64? { lifecycle.activeGeneration }

    /// A matched, readable device is present.
    var devicePresent: Bool { lifecycle.devicePresent }

    /// The IOHIDManager opened with Input Monitoring granted: begin observing,
    /// healthy, and clear any stale unreadable block. This is the ONLY way the
    /// reader becomes permission-healthy again after a revoke — the caller must
    /// genuinely reopen/verify the pipeline, never flip the flag on a stale
    /// manager.
    mutating func opened() {
        lifecycle.openPipeline()
        permissionHealthy = true
        deviceUnreadable = false
    }

    /// The IOHIDManager was closed (stop, feature off, or a reopen's first half):
    /// no watcher, not permission-healthy, no present device, no unreadable block.
    mutating func closed() {
        lifecycle.closePipeline()
        permissionHealthy = false
        deviceUnreadable = false
    }

    /// Input Monitoring was observed revoked at runtime by the liveness tick. The
    /// reader is no longer healthy; recovery requires `opened()` (a reopen), never
    /// a direct flip back to healthy.
    mutating func revokePermission() {
        permissionHealthy = false
    }

    /// A device-matched callback fired. On `.unreadable` the device is present but
    /// could not be opened, so the reader is blocked (health false) while the
    /// watcher stays open; on `.present` a readable device supersedes any prior
    /// unreadable block and mints a fresh generation.
    mutating func matched(openSucceeded: Bool) -> RemoteDeviceMatchOutcome {
        let outcome = lifecycle.matched(openSucceeded: openSucceeded)
        switch outcome {
        case .unreadable:
            deviceUnreadable = true
        case .present:
            deviceUnreadable = false
        case .ignored:
            break
        }
        return outcome
    }

    /// The matched-but-unreadable device was removed: clear the block so health
    /// can recover (a watcher with no present device is healthy again). Only the
    /// caller — which holds the device identity — should call this, and only for
    /// that exact device, so an unrelated removal cannot clear the failure.
    mutating func clearUnreadable() {
        deviceUnreadable = false
    }

    /// The present device was removed: invalidate the generation first (returns it
    /// so the caller can drop per-device state before emitting a balancing
    /// release); returns `nil` when no device was present.
    mutating func removed() -> UInt64? {
        lifecycle.removed()
    }

    /// Whether an input report captured under `generation` is still from the
    /// present device (dropped after a removal or supersession).
    func accepts(generation: UInt64) -> Bool {
        lifecycle.accepts(generation: generation)
    }
}

// MARK: - RC003 voice-key double-click bridge toggle

/// Centralised, frozen timing constants for the RC003 voice-key double-click
/// that toggles the bridge runtime on/off. Kept in one place so the state machine
/// and any UI copy stay in sync, and so tests pin the exact frozen values.
enum RemoteBridgeToggleGesture {
    /// A double-click only counts when the two presses *start* within this window
    /// (second key-down minus first key-down), matching the standard
    /// down-to-down double-click interval. A slower pair is treated as two
    /// independent taps and never toggles.
    static let doubleClickWindowMs: UInt64 = 350
    /// Each tap's own press duration (up minus down) must not exceed this, so a
    /// hold-to-talk long press is never mistaken for a tap.
    static let singleTapMaxMs: UInt64 = 250
}

/// Pure state machine that recognises exactly one bridge-toggle gesture: two
/// complete short taps (`down -> up`, each within `singleTapMaxMs`) whose two
/// key-downs fall within `doubleClickWindowMs`. It only *observes* the existing
/// single RC003 voice-key edge stream and returns `true` on the second tap's
/// release; it never delays or consumes an edge, so the existing hold-to-talk
/// voice path keeps its original latency.
///
/// Invariants (proved by synchronous tests):
/// - Two valid short taps in the window toggle exactly once, then reset to idle.
/// - A long press (tap longer than `singleTapMaxMs`), a lone tap, a repeated
///   `down` with no intervening `up`, or a second tap that starts after the
///   window all fail to toggle.
/// - A third quick tap after a completed toggle does not toggle again on its own
///   (it starts a fresh first tap).
/// - Time is compared with a caller-supplied monotonic millisecond stamp;
///   `reset()` drops any in-flight gesture so a stale edge (reader unhealthy,
///   device generation change, app stop, permission loss) can never complete an
///   old double-click.
struct RemoteBridgeToggleGestureDetector {
    let doubleClickWindowMs: UInt64
    let singleTapMaxMs: UInt64

    private enum Phase: Equatable {
        case idle
        /// First key is down; `downMs` starts the double-click window.
        case firstDown(downMs: UInt64)
        /// First short tap completed; awaiting a second key-down within the window.
        case firstReleased(firstDownMs: UInt64)
        /// Second key is down after a valid first tap and an in-window second down.
        case secondDown(secondDownMs: UInt64)
    }

    private var phase: Phase = .idle

    init(
        doubleClickWindowMs: UInt64 = RemoteBridgeToggleGesture.doubleClickWindowMs,
        singleTapMaxMs: UInt64 = RemoteBridgeToggleGesture.singleTapMaxMs
    ) {
        self.doubleClickWindowMs = doubleClickWindowMs
        self.singleTapMaxMs = singleTapMaxMs
    }

    /// Feeds one voice-key edge with its monotonic timestamp. Returns `true` when
    /// a valid double-click just completed (the caller toggles the bridge once).
    mutating func handle(_ edge: RemoteEventEdge, nowMs: UInt64) -> Bool {
        switch edge {
        case .down:
            switch phase {
            case .firstReleased(let firstDownMs)
                where Self.elapsed(from: firstDownMs, to: nowMs) <= doubleClickWindowMs:
                phase = .secondDown(secondDownMs: nowMs)
            default:
                // Idle, an out-of-window second down, or a repeated down with no
                // intervening up: (re)start a fresh first tap. None of these can
                // toggle on their own.
                phase = .firstDown(downMs: nowMs)
            }
            return false
        case .up:
            switch phase {
            case .firstDown(let downMs):
                if Self.elapsed(from: downMs, to: nowMs) <= singleTapMaxMs {
                    phase = .firstReleased(firstDownMs: downMs)
                } else {
                    // Long press (hold-to-talk), not a tap.
                    phase = .idle
                }
                return false
            case .secondDown(let secondDownMs):
                phase = .idle
                // The window was already checked at the second down; a valid short
                // second tap completes the double-click.
                return Self.elapsed(from: secondDownMs, to: nowMs) <= singleTapMaxMs
            case .idle, .firstReleased:
                // An up with no matching pending down: ignore.
                return false
            }
        }
    }

    /// Drops any in-flight gesture. Called when the reader becomes unhealthy, the
    /// device generation changes, the app stops, or permission is lost, so a late
    /// edge cannot finish an old double-click.
    mutating func reset() {
        phase = .idle
    }

    /// Saturating elapsed time so a non-monotonic sample can never underflow.
    private static func elapsed(from start: UInt64, to now: UInt64) -> UInt64 {
        now >= start ? now - start : 0
    }
}

// MARK: - Forced voice-key release ordering

/// One ordered effect a reader emits when it *force*-releases the RC003 voice key
/// — i.e. not from a genuine input report but from a stop, device removal,
/// permission revoke, fail-close, or an adopted-device generation change.
enum RemoteVoiceKeyReleaseEffect: Equatable {
    /// Reset the double-click gesture detector. Emitted FIRST and unconditionally,
    /// so a synthetic balancing `.up` (or an imminent generation change) can never
    /// complete an in-flight double-click and falsely toggle the bridge.
    case invalidateGesture
    /// Emit a balancing `.up` edge — only when the key is currently held — so the
    /// local-mic arbiter's remote-source marker is cleared. It also reaches the
    /// detector, but the detector is already idle from `invalidateGesture`, so it
    /// cannot toggle.
    case balancingUp
}

/// Pure ordering contract for a reader's forced voice-key release. The gesture
/// invalidation ALWAYS precedes any balancing `.up`. This is the fix for the
/// double-click false-toggle race: a forced/synthetic `.up` arriving while the
/// detector is mid-gesture (e.g. in `secondDown`) must not toggle, yet the local
/// remote-source release must still happen. Both `HIDRemoteMonitor` and
/// `RemoteVoiceKeyMonitor` drive their forced release through this exact order, so
/// the invariant is provable with synchronous tests over the same list they run.
///
/// Note this is only for *forced* releases: a genuine key-up parsed from an input
/// report is never routed through here, so a real second tap still toggles.
enum RemoteVoiceKeyForcedRelease {
    static func effects(keyHeld: Bool) -> [RemoteVoiceKeyReleaseEffect] {
        keyHeld ? [.invalidateGesture, .balancingUp] : [.invalidateGesture]
    }
}

// MARK: - Bridge runtime suppression scope

/// Pure decision for how completely the disabled bridge can suppress ordinary
/// RC003 keys. Full suppression is only guaranteed when custom mapping is on AND
/// the target HID is being read exclusively (seized): only then does the app own
/// every RC003 key and can drop them all. When custom mapping is off, or the
/// system did not allow an exclusive open, the remote's ordinary keys reach
/// macOS natively and the UI must say so honestly instead of claiming a complete
/// block. (The voice key is always fully handled — its F5→Fn mapping is restored
/// and ATVV is gated regardless of this scope.)
enum BridgeSuppressionScope {
    static func isFullSuppression(
        customMappingEnabled: Bool,
        exclusivelyReading: Bool
    ) -> Bool {
        customMappingEnabled && exclusivelyReading
    }
}

/// Pure computation of the runtime-bridge status text. Extracted so the
/// dependency on the reader's exclusive/monitored (`exclusivelyReading`) mode is
/// explicit and testable: the disabled-state text carries the native-key
/// degradation warning ONLY when suppression is not full, and that flips with the
/// reader's seize state on reconnect — a change that does NOT flip reader health.
/// The coordinator must therefore recompute this whenever the reader's exclusive
/// state can have changed (a successful device match or a removal), not only on a
/// reader-health flip, or a disabled bridge can keep a stale status that falsely
/// omits the warning.
enum BridgeRuntimeStatusText {
    static let enabled = "桥接已启用"
    static let disabled = "桥接已停用"
    static let mappingRestoreFailed = "桥接已停用（F5→Fn 映射恢复失败，请再次切换或重启应用）"
    static let nativeKeysMayRemain = "桥接已停用（应用桥接已关闭，但 macOS 原生按键行为可能仍存在）"

    static func text(
        enabled: Bool,
        mappingRestoreFailed: Bool,
        customMappingEnabled: Bool,
        exclusivelyReading: Bool
    ) -> String {
        if enabled { return Self.enabled }
        if mappingRestoreFailed { return Self.mappingRestoreFailed }
        if !BridgeSuppressionScope.isFullSuppression(
            customMappingEnabled: customMappingEnabled,
            exclusivelyReading: exclusivelyReading
        ) {
            return Self.nativeKeysMayRemain
        }
        return Self.disabled
    }
}

// MARK: - ATVV voice bridging gate

/// Pure gate for the RC003 ATVV voice path while the bridge runtime is toggled
/// off. The BLE link and its state observation stay live (so a later re-enable is
/// instant), but the remote must not open the microphone, start/continue a voice
/// stream, or push audio. Kept pure so the "disabled rejects MIC_OPEN / stream /
/// audio" rule is provable without a real peripheral.
enum ATVVVoiceBridgeGate {
    static func allowsVoice(bridgingEnabled: Bool) -> Bool {
        bridgingEnabled
    }
}

// MARK: - RC003 source-reader selection policy

/// Which reader supplies the RC003 microphone (F5) pre-marker edge.
///
/// Exactly one of these is ever selected, so the standalone observer and
/// `HIDRemoteMonitor` can never both hold the device (no double-open, no seize
/// contention).
enum RemoteSourceReader: Equatable {
    /// No reader: the compatibility feature is off, so no pre-marker is needed.
    case none
    /// `HIDRemoteMonitor` is already open and reading the RC003 device (custom
    /// mapping ON with permissions granted); it supplies the edge.
    case hidMonitor
    /// The standalone non-seize observer reads the edge (custom mapping OFF, or
    /// custom mapping ON but the HID monitor is not actually reading — first
    /// install without Accessibility, runtime revocation, or an HID open
    /// failure).
    case standalone
}

/// Pure policy that picks the single RC003 F5 reader from *actual* HID reader
/// health — never from the `customMappingEnabled` checkbox. The checkbox only
/// says whether the user wants key mapping; it does not prove `HIDRemoteMonitor`
/// successfully opened and is reading. This policy therefore gates on
/// `hidMonitorReading` (the monitor's real open state) so the standalone
/// fallback fills every window where the HID monitor is not actually reading.
enum RemoteSourceReaderPolicy {
    /// The reader that should be active given the feature switches and the HID
    /// monitor's real reading state. The standalone F5 reader is needed whenever
    /// *either* consumer wants the edge: the local-Fn microphone compatibility
    /// feature, or the RC003 voice-key double-click bridge toggle. Exactly one
    /// reader is ever selected, so the two never run at once (no double-open, no
    /// seize contention).
    static func targetReader(
        localFnMicEnabled: Bool,
        doubleClickEnabled: Bool = false,
        hidMonitorReading: Bool
    ) -> RemoteSourceReader {
        guard localFnMicEnabled || doubleClickEnabled else { return .none }
        return hidMonitorReading ? .hidMonitor : .standalone
    }

    /// Whether the selected reader is *actually healthy* — i.e. really able to
    /// deliver the F5 pre-marker. For the standalone target this is its shared
    /// health (observing AND permission granted AND no unreadable device), NOT a
    /// bare "manager is open" bool. When this is false with the feature enabled
    /// the local-mic path must fail closed: without a pre-marker source we cannot
    /// guarantee RC003 preemption, so a physical Fn must not open the built-in
    /// microphone.
    static func readerReady(
        target: RemoteSourceReader,
        hidMonitorReading: Bool,
        standaloneHealthy: Bool
    ) -> Bool {
        switch target {
        case .none:
            return false
        case .hidMonitor:
            return hidMonitorReading
        case .standalone:
            return standaloneHealthy
        }
    }
}

// MARK: - Local capture session routing

/// Hands out a monotonic token per capture session so late audio-thread
/// callbacks from a torn-down or preempted session are dropped instead of
/// re-entering the shared output. `begin` opens a new session; `invalidate`
/// closes the current one; `accepts` is checked on the ordered (main) domain
/// before any sample is enqueued.
struct LocalMicSampleRouter {
    private var counter: UInt64 = 0
    private(set) var activeSession: UInt64?

    mutating func begin() -> UInt64 {
        counter &+= 1
        activeSession = counter
        return counter
    }

    mutating func invalidate() {
        activeSession = nil
    }

    func accepts(_ session: UInt64) -> Bool {
        activeSession == session
    }
}

// MARK: - Physical Fn edge detection

/// Converts a stream of "function modifier present?" samples (taken from
/// `flagsChanged` events) into debounced press/release edges. Repeated samples
/// of the same state are ignored so duplicate `flagsChanged` events stay
/// idempotent.
struct FunctionKeyFlagTracker {
    private(set) var isDown = false

    mutating func update(functionFlagActive: Bool) -> VoiceFunctionKeyTransition? {
        if functionFlagActive {
            guard !isDown else { return nil }
            isDown = true
            return .press
        }
        guard isDown else { return nil }
        isDown = false
        return .release
    }

    mutating func reset() {
        isDown = false
    }
}

// MARK: - Feedback-loop guard

/// Why the local microphone bridge must refuse to open.
enum LocalMicRejection: Equatable {
    case noOutput
    case noInput
    case sameDevice
}

/// Pure guard that refuses to bridge the microphone whenever it would create an
/// input/output feedback loop or when either endpoint is missing. `resolvedInputUID`
/// is the concrete device that will actually be captured (after resolving the
/// "system default input" choice), never the placeholder empty string.
enum AudioLoopGuard {
    static func rejection(resolvedInputUID: String?, outputUID: String) -> LocalMicRejection? {
        guard !outputUID.isEmpty else { return .noOutput }
        guard let resolvedInputUID, !resolvedInputUID.isEmpty else { return .noInput }
        if resolvedInputUID == outputUID { return .sameDevice }
        return nil
    }
}

// MARK: - Readiness / liveness gate

/// Why the local microphone path is blocked, ordered from most to least
/// fundamental. Used for both start-time readiness and while-capturing liveness,
/// so the same rules that admit a capture also tear it down the moment any of
/// them stops holding.
enum LocalMicBlock: Equatable {
    case disabled
    case micPermission
    case fnMonitor
    /// No healthy RC003 F5 reader is available (neither `HIDRemoteMonitor` nor
    /// the standalone observer is reading), so RC003 preemption cannot be
    /// guaranteed and the local mic path fails closed.
    case remoteReader
    case outputMissing
    case inputMissing
    case sameDevice
    case captureEngine
}

/// Pure gate shared by readiness checks and the runtime liveness timer. Returns
/// `nil` when the local mic may run, or the first blocking reason otherwise.
/// Pass `captureEngineHealthy: true` for a not-yet-started readiness check;
/// pass the live engine state while capturing so a dead engine fails closed.
enum LocalMicGate {
    static func block(
        enabled: Bool,
        micAuthorized: Bool,
        fnMonitorRunning: Bool,
        remoteSourceReaderReady: Bool,
        outputRunning: Bool,
        outputUID: String,
        resolvedInputUID: String?,
        captureEngineHealthy: Bool
    ) -> LocalMicBlock? {
        guard enabled else { return .disabled }
        guard micAuthorized else { return .micPermission }
        guard fnMonitorRunning else { return .fnMonitor }
        guard remoteSourceReaderReady else { return .remoteReader }
        guard outputRunning else { return .outputMissing }
        switch AudioLoopGuard.rejection(resolvedInputUID: resolvedInputUID, outputUID: outputUID) {
        case .some(.noOutput): return .outputMissing
        case .some(.noInput): return .inputMissing
        case .some(.sameDevice): return .sameDevice
        case .none: break
        }
        guard captureEngineHealthy else { return .captureEngine }
        return nil
    }
}

// MARK: - Gain

/// Applies the shared voice gain to captured microphone samples. Unlike the
/// RC003 ADPCM post-processor this does not low-pass the signal — the mic PCM is
/// already clean — it only scales and clamps, matching the ±24 dB slider range.
enum LocalMicGain {
    static func apply(_ input: [Int16], gainDB: Double) -> [Int16] {
        guard !input.isEmpty else { return [] }
        let finiteGainDB = gainDB.isFinite ? gainDB : 0
        let safeGainDB = min(24.0, max(-24.0, finiteGainDB))
        guard safeGainDB != 0 else { return input }
        let gain = pow(10.0, safeGainDB / 20.0)
        return input.map { value in
            let scaled = Int((Double(value) * gain).rounded())
            return Int16(min(32_767, max(-32_768, scaled)))
        }
    }
}
