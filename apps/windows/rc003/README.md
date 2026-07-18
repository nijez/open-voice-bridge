# Open Voice Bridge · RC003 — Windows client (source/build candidate)

> **Status: source/build candidate, not yet real-device verified.** This
> directory builds and its pure-Python/contract tests pass on macOS/Linux.
> Its Windows-only code paths (WinRT BLE, Raw Input, SendInput, PortAudio)
> are covered by contract tests against fakes/dependency injection that
> match the documented API shapes as closely as this project can verify
> without a live Windows/WinRT runtime - that is NOT the same as having run
> against a real Windows machine or a real Xiaomi Bluetooth Remote 2 Pro /
> RC003, which has not happened anywhere in this repository or its tests.
> Do not treat this as "Windows: implemented" — see "Known gaps" below for
> the full list of what remains to be verified on real hardware, including
> two real, disclosed architectural uncertainties.

This is a Windows counterpart to this repository's macOS RC003 adapter
(`Sources/XiaomiRemoteBridgeMac`), covering the same device: button mapping
and ATVV (Android TV Voice-over-BLE) voice bridging for the Xiaomi Bluetooth
Remote 2 Pro / RC003. See the repository root `README.md` and
`docs/ARCHITECTURE.md` for how this fits into the overall project.

## 中文安装与使用说明（源码/构建候选）

> 本节面向想要试用这个候选版本的用户；下面各英文小节（"What this does"
> 及之后）是面向开发者的技术说明。适用范围和限制与上方状态说明一致：本
> 候选**尚未完成 Windows 真机验收**。

### 系统要求

- Windows 10 1809（内部版本 17763）或以上，64 位；
- 未签名安装包/可执行文件：首次运行时 Windows SmartScreen 可能提示
  "Windows 已保护你的电脑"——这是预期行为，不是错误，本项目目前没有代码
  签名证书。

  在点击"仍要运行"之前，建议先核对文件的 SHA-256 校验值是否与同一次构建
  产出的 `SHA256SUMS.txt` 一致。以 PowerShell 为例：

  ```powershell
  Get-FileHash -Algorithm SHA256 .\OpenVoiceBridgeRC003Setup-<版本号>-unsigned.exe
  ```

  把输出的 `Hash` 值（不区分大小写）与 `SHA256SUMS.txt` 中同一个文件名那
  一行的哈希值逐字比较；只要有一个字符不一致就不要运行，重新下载或联系
  发布者核实。核对一致后，再点击 SmartScreen 提示中的"更多信息"，然后点击
  "仍要运行"。

### 获取构建产物

本候选目前没有对外发布的正式 Release。可选来源：

- `.github/workflows/windows-rc003-ci.yml` 在真实 Windows GitHub Actions
  runner 上产出的未签名便携版 ZIP、安装器 `.exe` 与
  `SHA256SUMS.txt`——下载后请自行核对哈希再使用；
- 或在一台 Windows 机器上自行运行 `.\build\build-candidate.ps1` 从源码
  构建（见下方"Building an unsigned candidate"一节）。

### 安装

运行安装器（或直接使用便携版 ZIP 解压后的可执行文件）：只安装/解压到当前
用户目录，不请求管理员权限，不设置开机自动启动，不安装任何驱动。安装完成
后可以选择打开"设置"，但不会自动以无参数方式启动桥接——桥接模式需要在
Start Menu 中显式点击"启动"。安装器的 Start Menu 分组固定提供"设置"
"启动""停止""卸载"四个独立入口；主快捷方式与桌面快捷方式默认都打开
"设置"，不会直接进入桥接模式。

### 配对 RC003

1. 同时长按遥控器的【主页键】+【菜单键】，直到遥控器进入配对广播状态；
2. 打开 Windows"设置 → 蓝牙和其他设备"，等待遥控器出现后完成配对；
3. 程序按蓝牙名称自动查找已配对设备，不需要手动输入地址；找到 0 个或
   超过 1 个匹配设备时会拒绝猜测并报错退出，而不是随意连接一个。

### （可选）安装 VB-CABLE 作为虚拟麦克风

本程序不会自动下载、安装、启用或卸载任何虚拟音频驱动，也不会修改
Windows 默认输入/输出设备。如果要让语音识别/听写软件把 RC003 的语音当作
一个"麦克风"使用，需要自行从 VB-Audio 官方网站下载并安装官方
[VB-CABLE](https://vb-audio.com/Cable/)，然后按下面的方向手动配置——
方向不能弄反：

- Open Voice Bridge 的"语音输出设备"设置项 → 选择 `CABLE Input`
  （VB-CABLE 虚拟"扬声器"一侧）；
- 语音识别/听写软件的麦克风输入设置 → 选择 `CABLE Output`
  （VB-CABLE 虚拟"麦克风"一侧）。

两边选成同一个名字，或方向选反，都会让语音功能静默失败，但普通按键映射
仍然正常工作。

### 首次使用、停止/重启、卸载

1. 打开"设置"，在"语音输出设备"下拉框中选择上一节配置好的端点并保存；
2. 从 Start Menu 选择"启动 Open Voice Bridge · RC003"启动桥接；
3. 按一下普通按键（例如方向键、确定键）确认按键映射生效；
4. 在测试遥控器麦克风键之前，先手动确认 Win+H 语音听写本身能正常工作：
   打开记事本（或任意可编辑文本框），把光标点进文本区域，按一次键盘上的
   Win+H，确认 Windows 听写栏出现、说话后有文字被输入。这需要同时满足：
   光标确实停留在一个可编辑的文本输入框中（听写没有可输入目标时不会
   生效）；Windows 已启用"联机语音识别"（Windows 11：设置 → 隐私和安全性 → 语音；Windows 10：设置 → 隐私 → 语音，听写依赖联网的语音识别服务）；
   系统当前的麦克风输入设备选择的是
   `CABLE Output`（如果按上一节配置了 VB-CABLE）。手动测试通过后，光标
   保持在同一个可编辑文本框中，按住遥控器麦克风键说话，检查是否有文字
   被输入——同样要求语音输出/系统麦克风输入的方向配置与手动测试时一致，
   否则语音会静默失败（按键仍然可用）；如果手动 Win+H 都无法工作，请先
   解决那个问题，本程序不能让本来就不工作的系统听写变得可用；
5. 需要时从 Start Menu 选择"停止 Open Voice Bridge · RC003"结束桥接，
   或从"设置 → 应用"/Start Menu 的"卸载"条目卸载（卸载会先自动停止正在
   运行的进程）。

### 默认按键映射与固定行为

见下方英文"Default button mapping"表（同一份数据，英文技术文档保留原
表述）。要点：RC003 共 **13 个物理按键**（12 个普通按键 + 1 个固定的
麦克风按键）；遥控器**没有独立的物理静音键**（"系统静音"只是可选的手动
绑定，不是任何按键的默认映射）；"返回"键在本候选中未映射，见下方
"Known gaps"。

### 隐私与来源、真机验证事项

见下方"Privacy and provenance"与"Known gaps"两节（同一份内容，此处不重
复）：不持久化保存真实蓝牙地址/HID 路径/设备令牌；本候选是对同一
GPL-3.0 参考项目的只读、洁净室重新实现；设备配对/自动发现/重连、逐键
真实行为、ATVV 语音延迟与音量、Win+H 实际效果均待真机核验。

## What this does

- Discovers a single paired RC003 via
  `BluetoothLEDevice.get_device_selector_from_pairing_state(True)`, matched
  by exact Bluetooth name; fails closed (refuses to guess) if zero or more
  than one candidate is found. After opening the selected `BluetoothLEDevice`
  by its `DeviceInformation.id`, `connect()` verifies the ATVV GATT service
  is actually present before proceeding, rather than assuming any paired
  device is compatible. `connection_supervisor.py` retries this on a delay
  and reconnects automatically after a BLE disconnect or protocol error -
  from any thread, not only the event-loop thread, since WinRT/worker
  callbacks invoke it - always running full cleanup first (voice hotkey
  released, Raw Input listener stopped, BLE session closed) - see
  "Architecture notes" below.
- Reads the RC003's ordinary HID buttons via the Windows Raw Input API. At
  startup, exactly one Raw-Input-visible device path must match the RC003's
  VID/PID (fails closed otherwise); every individual `WM_INPUT` event
  afterward is then checked against that *exact* selected path, not just a
  VID/PID re-match, so a second matching device appearing later cannot be
  silently accepted. The "back" button is a documented exception - see
  "Known gaps" below.
- Connects to the ATVV BLE GATT service, negotiates capabilities, decodes
  16 kHz IMA/DVI ADPCM voice frames on a dedicated worker thread (never on
  the thread WinRT invokes a notification callback on), and writes the
  decoded PCM only to a Windows audio output endpoint the user has
  explicitly picked (by name **and** host API, to disambiguate a name that
  exists under more than one host API) in the settings window - never a
  "default" device, and never anything auto-picked. The endpoint is
  resolved and opened *before* the voice hotkey is sent, and `MIC_OPEN` is
  only sent if the hotkey itself fully delivered - if either step fails,
  voice fails fully closed and ordinary buttons keep working. A playback
  write failure also fails closed: the sink is discarded and a reconnect is
  requested, rather than logging indefinitely while the device keeps
  streaming into a broken sink.
- Synthesizes the configured voice hotkey (default `Win+H`) in response to
  the device's own mic-button press/release: in toggle mode, a key **tap**
  on mic-button-press (starting Windows' own Win+H dictation toggle) and
  another tap on the device's own `AUDIO_STOP` (turning that same toggle
  back off) - it never holds the key down across the stream, but also never
  leaves Windows dictation running after the device stops; or a real hold
  (key-down on press, key-up on `AUDIO_STOP`) in hold mode. Cleanup/reset
  always closes out whichever action is still owed.
- Ships a Tk settings window for button mapping, the voice hotkey/trigger
  mode, and output-endpoint selection.

## What this deliberately does NOT do

- Does not auto-download, install, enable, or uninstall VB-CABLE or any
  other audio driver.
- Does not change the Windows default input or output device, ever.
- Does not persist or log a real Bluetooth address, HID device interface
  path/GUID, or device token (enforced in code - see `config.py`'s
  `FORBIDDEN_KEYS` guard, which is checked **recursively** through nested
  dicts/lists, and `tests/test_privacy_contract.py`).
- Does not request administrator elevation anywhere.
- Does not enable start-on-login.
- Does not bundle any third-party binary. The optional Frida Gadget fetch
  script (`build/fetch-frida-gadget.ps1`) only ever pulls the official
  release asset over HTTPS and verifies a pinned SHA-256 before use - and
  even then, the actual injection step is intentionally unimplemented in
  this candidate (see "Known gaps").

## Default button mapping

| RC003 button | Windows action |
| --- | --- |
| Mic | Voice hotkey (default `Win+H`), tap (toggle) or hold edge per settings - **fixed, not editable** (see below) |
| Power | Escape |
| Up / Down / Left / Right | Arrow keys |
| OK | Enter |
| Back | *(unmapped in this candidate — see "Known gaps")* |
| Volume + / − | System volume + / − |
| Home | Win+D |
| Menu | Shift+F10 |
| TV | Alt+Esc |

Every row except Mic is user-editable in the settings window
(`python -m ovb_rc003 --settings`) and persisted to
`%LOCALAPPDATA%\OpenVoiceBridge\RC003\key_bindings.json`. The Mic row is
rendered read-only there, and `build_save_model()`/`config.load_key_bindings()`
both force it back to the voice action regardless of what a saved file
contains (XRBM-019, folded in from a XRBM-018 review round 2 product-
contract finding): the physical mic button is always driven directly by
the ATVV voice lifecycle - the runtime never consults a stored `mic`
binding at all, so it must not be presented (or ever saved) as an ordinary,
freely-editable key mapping. The voice hotkey text and toggle/hold trigger
mode remain fully configurable in the same window, just not through the
per-button mapping list.

## Architecture notes

- **Reconnect/cleanup.** `connection_supervisor.ConnectionSupervisor` drives
  a connect → wait → cleanup → retry loop. A BLE disconnect notification, an
  ATVV protocol error, or a playback write failure all call
  `request_reconnect()`, which ends the current wait and guarantees cleanup
  runs before the next attempt. `request_reconnect()` is safe to call from
  any thread (it hops onto the owning event loop via
  `call_soon_threadsafe()`, since `asyncio.Event` itself is not thread-safe)
  - which matters because every one of those three callers actually fires on
  a WinRT or ATVV-worker thread, never the event-loop thread. Every cleanup
  step (voice hotkey release, Raw Input listener stop, BLE session close,
  audio playback close) is independently attempted so one step's failure
  never skips the rest - but a step whose resource reports it is still
  alive (the Raw Input listener thread, or the BLE session's ATVV worker
  thread, didn't stop within its join timeout) leaves that owner reference
  in place rather than clearing it, and once every step has been attempted,
  `_cleanup_once()` raises an aggregated failure (XRBM-019). That exception
  propagates out of the supervisor's `finally` block and ends the whole
  connect/retry loop - the app fails closed instead of starting a fresh
  `connect()` generation (a second BLE session or Raw Input listener) over
  resources that might still be live.
- **Audio threading.** BLE notification callbacks only push raw bytes onto
  a small bounded, drop-oldest-on-full queue and return immediately - they
  never decode or block. A single dedicated worker thread (tagged with a
  per-connection generation counter, so events from a torn-down session can
  never be processed after a reconnect) pulls from that queue, runs the
  ATVV decode, and forwards PCM/control events onward. The MIC_OPEN write
  triggered by a mic-button press is scheduled onto the event loop the same
  way, gated by that same generation counter plus a "session is closing"
  flag, so a write scheduled just before a reconnect/close can never land on
  the wrong (already-torn-down or already-superseded) session; any write
  failure that does make it through is reported via the same error callback
  that drives reconnection, not silently dropped.
- **Key injection.** A multi-key combo is submitted to `SendInput` as one
  batched call, using the real x64 `INPUT` union (`MOUSEINPUT | KEYBDINPUT |
  HARDWAREINPUT`, `sizeof(INPUT) == 40`) - Microsoft documents that
  `SendInput` rejects a `cbSize` that doesn't match the real struct size. If
  Windows reports it queued fewer events than requested, exactly the keys
  that did go down are released before the failure is raised (or, on the
  cleanup path, retried and swallowed) - never left stuck.
- **HID buttons.** Uses the Win32 Raw Input API (`RegisterRawInputDevices`/
  `WM_INPUT`) via a real hidden message-only window and background message
  loop, not a direct hidapi HID-collection open (see "Known gaps" for why,
  and what remains genuinely uncertain about this). `stop()` posts the
  ordinary, window-associated `WM_CLOSE` (never `WM_QUIT`, which Microsoft
  documents as not associated with any window and invalid to `PostMessage`)
  through a fully-prototyped `PostMessageW(HWND, UINT, WPARAM, LPARAM) ->
  BOOL` call shared by every stop()/failed-start path (XRBM-019: this was
  the one remaining Win32 window-handle call left undeclared, which could
  silently truncate a real x64 handle to 32 bits under ctypes' documented
  unprototyped-argument default) and relies on the window procedure's own
  `WM_CLOSE` → `DestroyWindow` → synchronous `WM_DESTROY` → `PostQuitMessage`
  chain to end the loop, then joins the background thread -
  `start()`/`stop()` are repeatable, `start()` fails closed (raises, and
  tears down whatever was half-created) if the listener doesn't become
  ready within its timeout instead of silently treating a stall as success,
  and a failed `WM_CLOSE` post or an unjoined thread both leave
  `is_running` reporting the truth rather than being cleared to look
  stopped.

## Known gaps (disclosed, not hidden)

- **Which Raw Input event shape the RC003 actually produces is unverified.**
  Windows delivers Raw Input events either already-translated
  (`RIM_TYPEKEYBOARD`, a VK code) or as raw untranslated report bytes
  (`RIM_TYPEHID`), depending on internal driver behavior this project cannot
  observe without real hardware. `raw_input_windows.py` handles both shapes,
  but `KEYBOARD_VK_TO_BUTTON` only covers the RC003 button usages that have
  a well-documented standard Windows VK translation (arrows, Enter, Home,
  the Application/Menu key, and the three keyboard-page volume usages) -
  ten of the twelve ordinary buttons. The "power" and "tv" buttons use HID
  usage IDs without a well-documented standard translation and may simply
  produce no event via this path on real hardware; that would be a safe/
  inert failure (the button does nothing), not a crash, but it is a real,
  open question this candidate cannot resolve without a real device.
- **Back key.** Research into the upstream reference project found that
  Windows' BLE HID stack does not translate the RC003's "back" button usage
  into an ordinary keyboard/Raw Input event at all; upstream works around
  this with a Frida-based GATT-read tap. This candidate provides the
  SHA-pinned fetch script and an honest availability/degradation contract
  (`ovb_rc003.frida_compat.BackKeyCompatLayer`), but does **not** implement
  the actual process-injection step, since that would require code that
  writes into another process's memory - out of scope for a
  pre-real-device-verification candidate. `start()` always returns `False`;
  the back key stays unmapped until a future task implements and
  real-hardware-verifies this.
- **WinRT BLE call surface is contract-tested, not real-hardware-tested.**
  `ble_transport_winrt.py`'s call shape (paired-device selector
  construction, `uuid.UUID` argument types, `GattWriteResult.status`
  access, event-token plumbing, CCCD/service/device cleanup,
  connection-status subscription) is exercised against an in-memory fake of
  the locked `winrt-Windows.*==3.2.1` projection in
  `tests/test_ble_transport_contract.py`, which asserts the exact method
  names and argument types this module uses - including a dedicated test
  proving the fake rejects a GATT service-instance-domain ID if ever passed
  to `BluetoothLEDevice.from_id_async()` (the two are distinct WinRT ID
  domains; an earlier draft mixed them up). That proves internal
  consistency with the documented signatures; it has never been run against
  the actual WinRT runtime or a real RC003, so exact behavior on first
  real-hardware use remains 待核验.
- **Settings UI has no clickable photo hotspots.** The repository's RC003
  product photo is shown for reference, but mapping is done via a text list,
  not clickable regions on the image (see `settings_ui.py` docstring for
  why).

## Running from source

Requires Python 3.10+. On Windows:

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt

$env:PYTHONPATH = "src"
python -m ovb_rc003              # run the bridge
python -m ovb_rc003 --settings   # open the settings window
python -m ovb_rc003 --dry-run    # import everything and exit 0; no GUI/BLE/HID/audio touched
```

Pair the RC003 in Windows Bluetooth settings before first use. No manual
address entry is supported or needed - the app finds the paired device by
name automatically, and fails closed if it finds none or more than one.

## Testing

```bash
./scripts/test.sh
```

This runs every pure-Python/contract test on whatever OS you're on:
protocol/session, identity (BLE name + HID device-path fail-closed
selection, plus exact-path normalization), key-mapping/hotkey/
voice-controller (including the toggle-taps-again-on-AUDIO_STOP and
hold-releases-on-AUDIO_STOP lifecycle), audio-endpoint selection (including
name+host-API disambiguation), config privacy (including nested dict/list
guards) plus a stale-non-voice-`mic`-binding normalization check, the
settings-save model (no Tk window constructed, including that a non-voice
`mic` value can never be saved even if somehow supplied), the connection
supervisor's reconnect/cleanup contract (including a real cross-thread
`request_reconnect()` call from an actual OS thread, and that a cleanup()
failure ends `run_forever()` without a second `connect()`), app-level
wiring (host-hotkey-failure suppresses MIC_OPEN, playback-write-failure
fails closed and reconnects, both proven safe from a real worker thread;
`_cleanup_once()` retains a still-alive HID/BLE owner instead of clearing
it and raises once every step has been attempted), SendInput
batching/rollback (via an injected fake sender) plus a cross-platform
assertion that the real x64 `INPUT` struct is exactly 40 bytes, a
cross-platform ctypes-argtype regression suite covering both the earlier
`byref(array)`-vs-`POINTER(Struct)` bug class and the `PostMessageW`
unprototyped-argument truncation bug class (using a real, already-loaded C
library function to reproduce the exact silent-truncation failure mode
without needing `ctypes.windll`), the Raw Input adapter's body-parsing
logic (via synthetic buffers, no ctypes touched) plus a deterministic,
injection-based startup-timeout test, the BLE transport's WinRT call-shape
contract (via an in-memory fake projection, including the wrong-ID-domain
rejection test and that an already-in-flight MIC_OPEN write is cancelled
before GATT teardown, using a controllable blocking write rather than a
timing-based sleep), the PowerShell boundary-scan replay, and
build-artifact/privacy-contract checks (including that the CI workflow's
Inno Setup step is a required gate, not best-effort). The Windows-only
tests under `tests/windows/` self-skip outside a real Windows environment
with the optional runtime dependencies installed, and print an explicit
skip reason rather than silently passing - what's left there is the
genuinely irreducible "does the real Win32/WinRT/PortAudio syscall succeed
at all" surface, including a real hidden Raw Input listener reaching
ready, stopping, joining, and restarting across two full cycles, fail-closed
behavior when already running, and a real `SendInput` call reporting full
delivery.

## Building an unsigned candidate (Windows only)

```powershell
.\build\build-candidate.ps1
```

This creates a virtual environment, installs `requirements-dev.txt`, runs
the public-boundary scan and test suite, invokes PyInstaller against
`build/OpenVoiceBridgeRC003.spec`, then smoke-checks the built executable
with `--dry-run` (imports every module, touches no GUI/BLE/HID/audio, exits
0) - producing an **unsigned** one-dir build under
`dist/OpenVoiceBridgeRC003/`. See `installer/OpenVoiceBridgeRC003Setup.iss`
for the Inno Setup source (also unsigned; `PrivilegesRequired=lowest`, no
autostart task, no driver install steps).

`.github/workflows/windows-rc003-ci.yml` runs the same boundary scan, test
suite, PyInstaller build, `--dry-run` smoke check, and Inno Setup compile
(never runs/installs the result) on a real Windows GitHub Actions runner
whenever this subtree changes - every one of those is a required gate
(XRBM-018: the Inno Setup compile step was promoted from best-effort to
required), so a failure anywhere fails the whole job. CI has no RC003
hardware attached, so it cannot and does not exercise real-device behavior.

## Privacy and provenance

- `ATTRIBUTION.md` in this directory records, file by file, which upstream
  GPL-3.0-only reference files were consulted (read-only) and what changed.
- See the repository root `COPYRIGHT` and `THIRD_PARTY_NOTICES.md` for the
  project-wide adaptation statement.
- `tests/test_privacy_contract.py` and `build/check-public-boundary.ps1`
  enforce (in Python and PowerShell respectively) that no real MAC address,
  personal path, credential, forbidden branding term, elevation marker, or
  autostart marker ships in this subtree;
  `tests/test_boundary_scan_replay.py` replays the PowerShell scanner's
  exact scoping/allowlist logic in Python so it's covered cross-platform too.
