# File-by-file provenance

Every file under `apps/windows/rc003/` is either (a) new glue/wiring code
with no upstream counterpart, or (b) a clean-room reimplementation informed
by reading the GPL-3.0-only reference project
[`xxb26553663-star/remote-bridge-hub`](https://github.com/xxb26553663-star/remote-bridge-hub)
at reference revision `8a93f321ac71a602300c6cd77f7256fa4b63068e` (read-only,
consulted for interoperability facts - GATT UUIDs, control opcodes,
IMA/DVI ADPCM tables, HID usage IDs, VID/PID values - never copy-pasted).
No file in this directory was copied line-for-line from that repository.

See also this repository's root `COPYRIGHT` and `THIRD_PARTY_NOTICES.md`,
which record the project-wide adaptation statement covering both the macOS
and this Windows adapter.

## `src/ovb_rc003/`

| File | Upstream file(s) consulted | Notes |
| --- | --- | --- |
| `device_profile.py` | `source/bridges/xiaomi/hid_report_tap.py`, `hid_tap_runtime.py` (hardware token); kept consistent with this repo's own `Sources/XiaomiRemoteBridgeMac/VoiceBridgeDeviceProfile.swift` | RC003 name/VID/PID/HID usage-ID facts only |
| `atvv_protocol.py` | `source/bridges/xiaomi/atvv_record.py`, `atvv_live_bridge.py`; kept consistent with `Sources/XiaomiRemoteBridgeMac/ATVVProtocol.swift` | GATT UUIDs, capability parsing, IMA/DVI ADPCM tables and decode order, control opcodes - protocol facts, reimplemented in Python |
| `atvv_session.py` | Same as above (session/state-machine behavior: decoder reset on AUDIO_START, one-shot AUDIO_SYNC, late-audio guard window) | New transport-agnostic state machine; no upstream file has this exact shape |
| `identity.py` | `source/bridges/xiaomi/atvv_live_bridge.py` (`discover_xiaomi_2_pro_candidates`, `choose_xiaomi_2_pro_candidate`) | Deliberately hardened: upstream falls back to a remembered address or silently no-ops on ambiguity; this module always fails closed and never persists an address |
| `hid_identity.py` | `source/bridges/xiaomi/hid_report_tap.py` (report byte layout, usage table, snapshot-diff edge derivation); `source/bridges/raw_input_bridge.py` (`RAWHID` body layout: `dwSizeHid`/`dwCount`/report bytes) | New pure-logic reimplementation; also fails closed on multiple matching HID device paths (`select_single_device_path`) instead of "return the first match", per XRBM-014 review RETRY P1 #5. `normalize_device_path()` added per XRBM-018 so `raw_input_windows.py` can enforce the exact selected device path on every event, not just a VID/PID re-match |
| `connection_supervisor.py` | None (new connect/wait/cleanup/retry state machine) | New; no upstream file has this exact shape. Added per XRBM-014 review RETRY P1 #2. `request_reconnect()` made thread-safe (`call_soon_threadsafe`, not a direct `asyncio.Event.set()`) per XRBM-018, fixing XRBM-014 review round 2 P1 #5 |
| `hotkey.py` | `source/bridges/xiaomi/shortcut_capture.py` (concept only: representing a hotkey as modifiers + key) | New, much simpler serialization; does not reuse the low-level-keyboard-hook capture mechanism |
| `key_mapping.py` | the XRBM-014 task book's default mapping table; `source/bridges/xiaomi/xiaomi_config.py` (`DEFAULT_BUTTON_BINDINGS` concept) | Default table values come from the task book, not copied from upstream defaults |
| `voice_controller.py` | Concept informed by `atvv_live_bridge.py`'s voice-shortcut logging markers | New pure state machine; hold/toggle semantics designed for this project. Toggle-mode lifecycle changed per XRBM-018 (frozen there, superseding the XRBM-014 RETRY P1 #4 fix): taps again on the device's own `AUDIO_STOP`, not only on press, so Windows dictation doesn't stay on indefinitely |
| `audio_output.py` | `source/bridges/audio/audio_router.py` (`find_output_device`, fail-closed-on-missing-device pattern) | Reuses only the fail-closed idea; drops upstream's hardcoded VB-CABLE name and default-fallback host-API preference in favor of user-selected-by-name only. Disambiguates by (name, host API) after XRBM-014 review RETRY P2 #1 noted a bare name is not always unique across PortAudio host APIs. Per XRBM-031: gained `enumerate_input_endpoints()` (recording endpoints, for the diagnostics page's VB-CABLE check only - the voice path itself remains playback-only/unchanged) and `is_cable_input_endpoint()`/`is_cable_output_endpoint()` matchers that tolerate a host-API-decorated name without accepting an unrelated similarly-named device |
| `audio_playback.py` | `source/bridges/audio/audio_router.py` (use of `sounddevice`/PortAudio for output) | New, single-purpose sink; no mixer, no VB-CABLE constant; same (name, host API) disambiguation as `audio_output.py` |
| `config.py` | `source/bridges/xiaomi/xiaomi_config.py` (config file location/shape concept) | Deliberately excludes upstream's `address`/`device_match` persisted fields entirely; adds an enforced `FORBIDDEN_KEYS` guard with no upstream counterpart. `load_key_bindings()` gained `_normalize_mic_binding()` per XRBM-019 so a stale/non-voice `mic` entry on disk is always normalized back to the voice action in memory, matching what the runtime actually honors |
| `logging_setup.py` | `source/standalone/xiaomi_main.py` (log directory concept) | New; does not redirect stdout/stderr wholesale the way upstream's `configure_pythonw_logging` does |
| `frida_compat.py` | `source/bridges/xiaomi/hid_report_tap.py`, `hid_tap_injector.py`, `hid_tap_runtime.py` (why Frida is used for the back key; SHA-pinned local-asset-verification concept) | Deliberately does NOT reimplement upstream's remote-thread DLL injection; provides only the asset descriptor and an honest always-degrades contract |
| `win32_keys.py` | None (standard Win32 `winuser.h` VK constants) | New |
| `win32_input.py` | None (standard Win32 `SendInput` API) | New; batches a combo into one `SendInput` call with deterministic partial-failure rollback, per XRBM-014 review RETRY P1 #4. `INPUT`'s ctypes union corrected to the real `MOUSEINPUT \| KEYBDINPUT \| HARDWAREINPUT` shape (`sizeof(INPUT) == 40` on x64) per XRBM-018, fixing XRBM-014 review round 2 P1 #1/#8 - the previous union declared only `KEYBDINPUT`, understating `cbSize` |
| `raw_input_windows.py` | `source/bridges/raw_input_bridge.py` (Raw Input API usage: `RAWINPUTDEVICE`/`RIDEV_INPUTSINK` registration, `WM_INPUT`/`GetRawInputData` two-pass pattern, device-path filtering via `GetRawInputDeviceInfoW`) | New Windows adapter; **replaces** the earlier `hid_input_windows.py` (hidapi-based direct HID-collection open), removed after XRBM-014 review RETRY P1 #5/#9 found that architecture didn't match how the cited upstream project actually reads ordinary buttons on Windows. Which Raw Input event shape (`RIM_TYPEKEYBOARD` vs `RIM_TYPEHID`) the RC003 actually produces is disclosed as unverified in the module's own docstring, not claimed as proven. Per XRBM-018 (fixing XRBM-014 review round 2 P1 #3/#4/#8): `stop()` now posts `WM_CLOSE` (never `WM_QUIT`, which Microsoft documents as invalid to `PostMessage`) and relies on `WM_CLOSE`→`DestroyWindow`→`WM_DESTROY`→`PostQuitMessage`; `start()` fails closed and tears down on a readiness timeout instead of assuming success; every event is checked against the exact normalized selected device path, not just a VID/PID re-match; and several Win32 calls (`GetModuleHandleW`, `CreateWindowExW`, `DefWindowProcW`, the window-procedure callback itself) gained explicit pointer-sized argtypes/restype. Per XRBM-019 (fixing XRBM-018's independent review round 2 finding #1): `PostMessageW` - the one remaining untyped window-handle call - now goes through a shared, fully-prototyped `_post_close_message()` helper reused by both `stop()` and `_abandon_failed_start()`, and a failed post or an unjoined thread both leave `is_running`/the owner state reporting the truth instead of being cleared |
| `ble_transport_winrt.py` | `source/bridges/xiaomi/atvv_live_bridge.py` (WinRT BLE connect/subscribe/write flow, GATT service/characteristic discovery order) | New Windows adapter wiring. Rewritten after XRBM-014 review RETRY P1 #1 to match the locked `winrt-Windows.*==3.2.1` projection's actual signatures (`uuid.UUID` arguments, `GattWriteResult.status`, event-registration tokens, CCCD/service/device cleanup, connection-status subscription) and reviewed via an in-memory fake of that projection in `tests/test_ble_transport_contract.py` - still unverified against a live runtime/real hardware. Discovery rewritten again per XRBM-018 (fixing XRBM-014 review round 2 P1 #2) to use `BluetoothLEDevice.get_device_selector_from_pairing_state(True)` + `DeviceInformation.find_all_async_aqs_filter()` instead of `GattDeviceService.get_device_selector_from_uuid()`, which enumerates a different (GATT service-instance) WinRT ID domain than `BluetoothLEDevice.from_id_async()` requires; `send_mic_open_threadsafe()` gained a generation/closing gate and error observation (P1 #6 area). Per XRBM-019 (fixing XRBM-018's independent review round 2 finding #2): `close()` now treats an ATVV worker-thread join timeout as a real close() failure - raised only after every other independent GATT cleanup step has still been attempted, with `self._worker_thread` deliberately left set - instead of merely reporting it via `on_error` while returning normally |
| `resources.py` | None | New. Gained a `sys._MEIPASS`-aware lookup per XRBM-018 (round 2 finding #4); the module docstring's wording was corrected per XRBM-019 (round 2 product-contract follow-up) to stop claiming `_MEIPASS` equals the frozen executable's own directory - true for older PyInstaller onedir layouts, not guaranteed for PyInstaller 6's default `_internal`-subdirectory layout - without changing the already-correct `sys._MEIPASS/Resources` lookup logic itself |
| `settings_ui.py` | Concept informed by `Sources/XiaomiRemoteBridgeMac/SettingsView.swift` (what a settings screen should expose) and `source/bridges/xiaomi/xiaomi_settings.py` (same concept, upstream's Tk/UI is not reused) | Validation/save logic extracted into Qt-free functions (`build_save_model`, `_display_to_action`, etc.) after XRBM-014 review RETRY P1 #7 found the default "mic" mapping could not round-trip through save. Per XRBM-019 (folded in from a XRBM-018 review round 2 product-contract finding): `build_save_model()` unconditionally forces the saved "mic" action to voice regardless of what (if anything) the display map contains, since the runtime never consults a stored "mic" binding. Per XRBM-030: the Tk `SettingsWindow` view class was removed entirely (replaced by `qt_settings_app.py`/`qml/`, see those rows); this file now holds only the pure functions, unchanged in behavior |
| `remote_layout.py` | RC003 product-photo hotspot coordinates copied byte-for-byte from this repository's own already-accepted `Sources/XiaomiRemoteBridgeMac/SettingsView.swift`/`RemoteButtons.swift` (King-verified against the real photo); no upstream (`remote-bridge-hub`) file has any equivalent | New (XRBM-030); pure data/logic, no Tk/Qt dependency |
| `shell_targets.py` | None (standard, Microsoft-documented `ms-settings:` URI scheme opened via `os.startfile`) | New (XRBM-030); mirrors `logging_setup.py`'s injectable-opener pattern. Per XRBM-031: gained `SOUND_SETTINGS_URI` (`ms-settings:sound`) and `APPS_SETTINGS_URI` (`ms-settings:appsfeatures`), both used by the "检查与修复" page |
| `qt_settings_app.py` | Concept informed by `Sources/XiaomiRemoteBridgeMac/SettingsView.swift` (three-page structure, hotspot/mapping-list bidirectional selection); no upstream (`remote-bridge-hub`) Windows file has any Qt/QML equivalent | New (XRBM-030); PySide6-Essentials + Qt Quick/QML view replacing the previous Tk `SettingsWindow`. Bridges `settings_ui.py`'s unchanged pure functions to `qml/` via a `QAbstractListModel` (`ButtonMappingModel`) and a `QObject` (`SettingsController`), both exposed to QML as singletons (not root-context properties - see the module's own docstring for the exact Qt Quick Controls internal-property-name collision this works around). Per XRBM-031: gained a second `QObject`, `DiagnosticsController`, which runs `windows_diagnostics.run_diagnostics()` on a background `threading.Thread` and delivers the result via a cross-thread Qt signal, plus thin slots for selecting the detected `CABLE Input` endpoint and launching the bundled VB-CABLE vendor setup (`vb_cable_bundle.py`) - registered as a third QML singleton the same way |
| `qml/*.qml` | Concept/coordinates informed by `Sources/XiaomiRemoteBridgeMac/SettingsView.swift` (same three-page structure and hotspot layout); visual language is this project's own Fluent-inspired token system (`Tokens.qml`), not a copy of macOS's chrome (no traffic-light window controls). `DiagnosticsPage.qml` (XRBM-031, the fourth page) has no macOS counterpart at all - new UI/UX designed for this candidate | New (XRBM-030); `DiagnosticsPage.qml` added in XRBM-031 |
| `windows_diagnostics.py` | None (new Qt-free diagnostics module) | New (XRBM-031); pure-Python checks (OS version/64-bit, BLE candidate count, Raw Input device count, VB-CABLE endpoint presence, output-endpoint resolution, Windows dictation - always `MANUAL`) exercised via injectable probes/discover/enumerate callables, no upstream counterpart |
| `vb_cable_bundle.py` | None (new hash-gated bundle/extract/launch helper; VB-CABLE itself is a third-party VB-Audio product, not sourced from `remote-bridge-hub`) | New (XRBM-031); locates/verifies/safely-extracts the official, unmodified VB-CABLE Basic ZIP and launches its own `VBCABLE_Setup_x64.exe` via Windows' `runas`/UAC verb - the sole disclosed elevation exception in this source tree (see `tests/test_privacy_contract.py`) |
| `app.py`, `__main__.py` | Concept informed by `source/standalone/xiaomi_main.py` (role/entry-point wiring shape) | New; does not reuse upstream's multi-process/subprocess-per-role architecture. `app.py` rewritten to drive `connection_supervisor.py`'s reconnect loop and to resolve/open the audio endpoint *before* sending the voice hotkey/`MIC_OPEN` (XRBM-014 review RETRY P1 #2/#3). Per XRBM-018 (fixing XRBM-014 review round 2 P1 #6): MIC_OPEN is now only sent if the hotkey itself fully delivered, and a playback write failure now fails closed (discards the sink) and requests a reconnect instead of logging indefinitely. Per XRBM-019 (fixing XRBM-018's independent review round 2 finding #2): `_cleanup_once()` now only clears `self._hid_listener`/`self._ble_session` to `None` on a successful `stop()`/`close()` - a step whose resource reports it is still alive leaves the owner reference in place - and raises a new `CleanupIncompleteError` once every step has still been attempted, which ends `ConnectionSupervisor.run_forever()`'s retry loop entirely instead of reconnecting over possibly-still-live resources. `__main__.py` gained a `--dry-run`/`--help` mode for CI/build smoke checks (P2 #3) |
| `__init__.py` | None | New |

## `tests/`

All new. Test *names and intent* for the ATVV/config/privacy areas were
chosen after reading what upstream's own `tests/test_xiaomi_config.py` and
`tests/test_core_behavior.py` check (see
XRBM-014 for the research summary), so this
project's behavioral guarantees are at least as strict, but no test code was
copied - the fixtures, assertions, and helper functions here are new.

`tests/fakes/fake_winrt.py` is a new, from-scratch in-memory fake of the
`winrt-Windows.*==3.2.1` projection surface (not derived from any upstream
or third-party test double), added per XRBM-014 review RETRY P2 #2 so
`tests/test_ble_transport_contract.py` can assert the exact WinRT call shape
(method names, `uuid.UUID` argument types, event-token plumbing) without a
live Windows/WinRT runtime. Updated per XRBM-018 to model the paired-BLE-
device selector domain and to reject a GATT service-instance-domain ID
passed to `from_id_async`, matching the round-2-review-driven production fix.

`tests/test_win32_input_abi.py` (new, XRBM-018) asserts the real x64 Win32
`INPUT` struct shape - `sizeof(INPUT) == 40` and the union's member layout -
using only `ctypes.sizeof()`/plain `ctypes.Structure` classes, so it runs
cross-platform without needing `ctypes.windll`/Windows at all.

`tests/test_app_wiring.py` (new, XRBM-018) exercises `app.py`'s `RC003App`
wiring decisions (host-hotkey-failure suppresses MIC_OPEN, playback-write-
failure fails closed and requests a reconnect, both proven safe when called
from a real background OS thread) by constructing a real `RC003App` and
substituting lightweight recorder objects for its BLE-session/playback
collaborators - no Windows API involved, since `RC003App.__init__` and
these code paths are pure Python off the real Win32/WinRT calls. Gained a
`CleanupOwnershipTests` class per XRBM-019 proving `_cleanup_once()`
retains a still-alive HID/BLE owner rather than clearing it, aggregates and
raises once every step has been attempted, and that this failure
propagates through a real `ConnectionSupervisor.run_forever()` without a
second `connect()` ever running.

`tests/test_win32_ctypes_argtypes.py` (new during the first XRBM-018
retry, extended per XRBM-019) is a from-scratch, cross-platform ctypes
regression suite - no third-party test double, no upstream counterpart.
The `SendInput`/`GetRawInputDeviceList` classes reproduce the
`ctypes.byref(array)`-vs-`POINTER(Struct)` `ArgumentError` the round-1
independent review found using `ctypes.CFUNCTYPE` stubs built from this
project's own real production structs/argtypes. The XRBM-019
`PostMessageWArgtypeTests` class reproduces the *silent-truncation* bug
class (an unprototyped foreign-function call passing a bare Python int as
the platform default 32-bit C `int`) using a real, already-loaded C
library function (`libc`'s `labs`) - a technique with no upstream or
third-party origin, chosen because it needed a real foreign function call
outside this project's own code to demonstrate ctypes' own default
argument-marshaling behavior, not something either project's source
provided.

`tests/test_connection_supervisor.py` gained a `CleanupFailureFailsClosedTests`
class per XRBM-019 - new, no upstream counterpart - proving (without any
change to `connection_supervisor.py` itself) that a raising `cleanup()`
already ends `run_forever()`'s retry loop entirely via ordinary Python
`try/finally` semantics, which is what makes `app.py`'s new
`CleanupIncompleteError` raise actually fail the supervisor closed.

`tests/test_windows_diagnostics.py` and `tests/test_vb_cable_bundle.py` (new,
XRBM-031, no upstream counterpart) cover every diagnostic check's PASS/FAIL/
MANUAL/UNSUPPORTED branch via injected probes/discover/enumerate callables,
and the bundle helper's hash verification, safe-extraction (hash mismatch,
absolute path, `..` traversal, symlink, missing setup member - via
synthetic, locally-constructed ZIP fixtures, never the real vendor binary),
and UAC-cancellation handling, respectively. `tests/test_qt_settings_app.py`
gained `DiagnosticsControllerTests` (real cross-thread signal delivery via
`QGuiApplication.processEvents()` polling, the overlapping-refresh-click
guard proven with a deterministically-blocked fake check, and the
select-CABLE-Input/launch-vendor-setup slots via injected fakes) and its
`_QML_LOAD_PROBE_SCRIPT`/`_DIRECT_SAVE_PROBE_SCRIPT`/`_CONTRAST_PROBE_SCRIPT`
subprocess scripts were updated to also construct and register
`DiagnosticsController`, since `main.qml` now unconditionally imports it.

## `build/`, `installer/`, `.github/workflows/windows-rc003-ci.yml`

| File | Upstream file(s) consulted | Notes |
| --- | --- | --- |
| `build/OpenVoiceBridgeRC003.spec` | `source/XiaomiRemoteBridge.spec` (one-dir COLLECT shape, hiddenimports/excludes categories) | New; excludes are adjusted for this tree (T1/Hanvon/licensing don't exist here but are excluded defensively); no Frida binary in `datas` (never bundled, see `frida_compat.py`). Per XRBM-031: the verified, unmodified VB-CABLE ZIP `build/fetch-vb-cable.ps1` produces IS bundled as opaque `datas` (collected under `vb_cable_bundle/`) if present, so the frozen build works fully offline |
| `build/fetch-frida-gadget.ps1` | `scripts/fetch-third-party.ps1` (`Get-VerifiedAsset` SHA-pinning pattern) | Reuses only the generic download-then-verify-then-move pattern; the VB-CABLE fetch call is not ported at all |
| `build/fetch-vb-cable.ps1` | `build/fetch-frida-gadget.ps1` (same `Get-VerifiedAsset` download-then-verify-then-move pattern, within this project itself - not upstream); VB-CABLE itself is a third-party VB-Audio product, not sourced from `remote-bridge-hub` | New (XRBM-031); unlike the Frida script, this one IS wired as a required step into `build-candidate.ps1`/`windows-rc003-ci.yml`, since a real Windows build needs the verified ZIP bundled |
| `build/check-public-boundary.ps1` | `scripts/check-public-boundary.ps1` (category list and regex-scan structure) | New regex set tailored to this project's forbidden terms/paths |
| `build/build-candidate.ps1` | `delivery/build-standalone-packages.ps1` (venv + install + test + build orchestration shape) | New, much shorter (single product, no packaging-content diffing) |
| `installer/OpenVoiceBridgeRC003Setup.iss` | `delivery/standalone/setup/XiaomiRemoteBridgeSetup.iss`, `StandaloneBridgeSetup.common.iss` (the non-Xiaomi/native-audio `#else` branch template, since it already has no VB-CABLE footprint) | `PrivilegesRequired=lowest` kept; startup-task/icon omitted; no audio-driver `[Run]`/`[UninstallRun]` steps at all (stricter than even the non-Xiaomi upstream template, which still swaps default mic) |
| `installer/stop-app.ps1` | `delivery/standalone/setup/stop-product.ps1` | Nearly the same generic pattern (find-by-executable-path, force-stop); upstream's version is already product-agnostic |
| `installer/readme-rc003.txt` | `delivery/standalone/setup/readme-xiaomi.txt` (section shape) | New wording; the installer/application itself still never installs a driver or requests elevation. Per XRBM-031: documents the optional, in-app "检查与修复" page as an alternative to the pre-existing manual VB-CABLE download instructions - that page's own UAC prompt is the vendor's, not this installer's |
| `.github/workflows/windows-rc003-ci.yml` | `.github/workflows/ci.yml` (job/step shape: checkout, setup-python, boundary scan, install, compileall, test) | Adds a path filter scoping it to this subtree, and an unsigned PyInstaller build + `--dry-run` smoke check + artifact upload step not present upstream. Per XRBM-018, the Inno Setup compile step was promoted from best-effort/`continue-on-error` to a required gate like every other step - it still only compiles the installer SOURCE and never runs/installs it |
