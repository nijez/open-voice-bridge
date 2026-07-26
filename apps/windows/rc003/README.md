# Open Voice Bridge — Windows client (RC003 build candidate + DJI Mic 2 input UI)

> **Status: source/build candidate with a real Windows CI run, still not
> real-device verified.** This directory builds and its pure-Python/
> contract tests pass on macOS/Linux too. Its Windows-only code paths
> (WinRT BLE, Raw Input, SendInput, PortAudio) are covered by contract
> tests against fakes/dependency injection for their exact call shapes,
> AND additionally run for real on a real `windows-latest` GitHub Actions
> runner (see `.github/workflows/windows-rc003-ci.yml`): fixed baseline
> run
> [29645685087](https://github.com/nijez/open-voice-bridge/actions/runs/29645685087)
> passed 443 tests (skipped=3, each a documented off-Windows-only gate),
> including a real WinRT BLE candidate enumeration call, a real Raw Input
> device-path enumeration call, a real Raw Input hidden message-window
> listener reaching ready, stopping, joining, and restarting across two
> full cycles plus a real fail-closed-when-already-running check, a real
> SendInput key delivery, and a real PortAudio output-endpoint enumeration
> call - each proving the call actually succeeds against the real
> OS/WinRT runtime, with no RC003 hardware attached anywhere in that job.
> The same run also produced a real PyInstaller build, a frozen
> `--dry-run` smoke check, a real Inno Setup compile, and a real,
> hash-verified, deterministic three-file (installer + portable ZIP +
> `SHA256SUMS.txt`) package. A later CI run may report a different test
> count as the suite grows; the counts above are pinned to this specific
> baseline run number, not to whichever run happens to be most recent.
>
> That is real evidence this code runs on a real Windows machine - it is
> NOT the same as pairing with, or receiving input/voice from, a real
> Xiaomi Bluetooth Remote 2 Pro / RC003, which has not happened anywhere
> in this repository, its tests, or that CI run. This repository and its
> CI have compiled the installer but have not executed it, and have not
> validated install or uninstall; the shipped assets are unsigned; no
> audio driver is bundled; and the "back" button stays unmapped (see
> below). Do not treat this as "Windows: implemented" — see "Known gaps"
> below for the full list of what remains to be verified on real
> hardware, including two real, disclosed architectural uncertainties.

This is a Windows counterpart to this repository's macOS RC003 adapter
(`Sources/XiaomiRemoteBridgeMac`), covering the same device: button mapping
and ATVV (Android TV Voice-over-BLE) voice bridging for the Xiaomi Bluetooth
Remote 2 Pro / RC003. See the repository root `README.md` and
`docs/ARCHITECTURE.md` for how this fits into the overall project.

The settings window now has an explicit device selector. Selecting **Xiaomi
RC003** keeps the existing bridge, virtual-output and 13-button mapping UI.
Selecting **DJI Mic 2 (Pocket 3 kit transmitter)** switches to a separate
system-recording-input page and never starts the RC003 BLE/HID/ATVV bridge.
This does not claim that DJI transmitter controls are Windows buttons: the
record, link and power controls remain read-only hardware descriptions until a
real Windows input capture proves an independently mappable event.

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

首选来源是本仓库的 Releases 列表页——这是列表页本身，不是指向某个具体
tag 的链接，因此始终是获取最新预发行版的稳定入口，请直接使用这个地址：

  https://github.com/nijez/open-voice-bridge/releases

在列表中找到本 RC003 Windows 候选对应的预发行版（预发行版会明确标记为
prerelease，发布说明会写清楚它基于哪一次真实 Windows CI 运行）。

预发行版的仓库级 tag（例如 `v0.3.0-windows-rc003-candidate.1`）只是发布
编号，和资产文件名里的内部构建版本号是两回事：当前内部构建版本号固定为
`0.1.0-candidate`（来自安装器脚本
`installer/OpenVoiceBridgeRC003Setup.iss` 的 `AppVersion`）。不要因为
文件名里的版本号和 tag 不一致就怀疑下载错了文件，具体对应关系以该
预发行版自己的发布说明为准。

每个 RC003 Windows 候选预发行版恰好包含以下三个文件，文件名精确匹配这个模式（下面的
`<版本号>` 就是上面说的内部构建版本号，不是 tag）：

- `OpenVoiceBridgeRC003Setup-<版本号>-unsigned.exe`——安装器；
- `OpenVoiceBridgeRC003-<版本号>-portable-unsigned.zip`——便携版（解压后
  得到一个已带版本号的顶层文件夹，里面除程序本体外还包含
  LICENSE.txt/COPYRIGHT.txt/THIRD_PARTY_NOTICES.md/ATTRIBUTION.md/
  README.txt，和安装器携带的说明与授权文件相同）；
- `SHA256SUMS.txt`——覆盖以上两个文件的哈希清单，来自同一次构建，用于
  上一节"系统要求"所说的哈希核对。

只需要下载安装器**或**便携版其中一个，不需要两个都下载；两者内容等价，
都来自同一次真实 Windows CI 运行——安装器会安装到当前用户目录，便携版
解压即用、不需要安装。

也可以使用以下备选来源：

- `.github/workflows/windows-rc003-ci.yml` 在真实 Windows GitHub Actions
  runner 上产出的、结构相同的未签名便携版 ZIP、安装器 `.exe` 与
  `SHA256SUMS.txt`（作为该次 CI 运行的构建产物而不是正式发布，需要登录
  GitHub 账号后在对应 Actions 运行页面下载）——下载后同样请自行核对哈希
  再使用；
- 或在一台 Windows 机器上自行运行 `.\build\build-candidate.ps1` 从源码
  构建（见下方"Building an unsigned candidate"一节）。

### 安装

安装器和便携版是两种不同的使用方式，步骤不完全一样，分别说明如下；
后面"首次使用、停止/重启、卸载"一节也会按这两种方式分别给出步骤。

**方式一：安装器（提供 Start Menu 入口）**

运行安装器：只安装到当前用户目录，不请求管理员权限，不设置开机自动启动，
不安装任何驱动。安装完成后可以选择打开"设置"，但不会自动以无参数方式启动
桥接——桥接模式需要在 Start Menu 中显式点击"启动"，或在"设置"窗口里点击
"保存并启动桥接"（见下方"首次使用"一节）。安装器的 Start Menu
分组固定提供"设置""启动""停止""卸载"四个独立入口；主快捷方式与桌面快捷方式
默认都打开"设置"，不会直接进入桥接模式。

**方式二：便携版 ZIP（解压即用，没有 Start Menu 入口）**

把便携版 ZIP 解压到你自己选择的目录：不请求管理员权限，不安装任何驱动，
不写入 Start Menu 或桌面快捷方式，不设置开机自动启动。便携版**没有**
安装器提供的"设置""启动""停止""卸载"四个 Start Menu 入口，也没有打包
停止脚本或卸载程序——启动、设置、停止、卸载都需要在解压出的文件夹里
用命令或任务管理器手动完成，具体步骤见下一节"便携版 ZIP 用户"。

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

**一键随包安装（XRBM-031，可选）**：打开"设置 → 检查与修复"页，"可选：
VB-CABLE 虚拟音频驱动"卡片会显示 CABLE Input/CABLE Output 两个端点当前是
否已存在。如果还没安装，点击"安装/修复 VB-CABLE…"会先弹出一个说明对话框
（VB-CABLE by VB-Audio，独立 Donationware，非 GPL 项目代码，可自愿捐赠/
购买授权，仅随包提供基础版、不含付费的 A+B/C+D，安装会改变系统状态并需要
重启），确认后才会解压随安装包携带的官方 `VBCABLE_Driver_Pack45.zip`（构建
时已用固定的 SHA-256 校验过，未被本项目修改），并以 Windows 用户账户控制
(UAC) 提示启动官方原始的 `VBCABLE_Setup_x64.exe`——本程序自身全程不以管理员
身份运行，UAC 提示可以随时取消，取消不会安装任何内容。安装完成后需要重启
电脑，重启后点击"重新检测"确认两个端点已出现，再点击同一页的"选择检测到
的 CABLE Input 作为输出"即可把它设为语音输出端点（仍需要按方向手动把
听写/识别软件的麦克风输入设为 `CABLE Output`）。这个入口只是把上面的手动
下载步骤换成随包、离线、显式确认的流程，效果完全一致；仍然可以选择直接从
<https://vb-audio.com/Cable/> 手动下载安装。

### 首次使用、停止/重启、卸载

打开设置后，先在顶部“当前设备”选择实际连接的设备：

- 选择“小米蓝牙语音遥控器 2 Pro（RC003）”时，继续使用桥接、CABLE
  输出、语音热键和 13 键映射；
- 选择“DJI Mic 2（Pocket 3 套装无线麦）”时，程序只检查 Windows
  当前是否存在可用录音输入，并提供“打开 Windows 声音输入设置”。它不需要
  VB-CABLE，也不会启动 RC003 桥。DJI 发射器的录音、连接和电源键目前只显示
  官方硬件功能，不提供虚构的 Windows 自定义映射。

设备选择会保存；原有配置没有该字段时默认保持 RC003，避免升级后改变旧用户
行为。

"打开设置并选择语音输出端点""确认按键映射""手动确认已配置的语音组合键"这几步在
两种安装方式下目标一样，但具体怎么打开设置、怎么启动/停止/卸载不同
——安装器用户走 Start Menu，便携版用户在解压出的文件夹里用命令和任务
管理器，分别在下面两个小节说明。

**安装器用户**

1. 打开"设置"（Start Menu 中的"Open Voice Bridge · RC003"或
   "Open Voice Bridge · RC003 设置"），在"语音输出设备"下拉框中选择
   上一节配置好的端点；
2. 启动桥接有两种等价方式：在设置窗口底部"桥接控制"区域点击"保存并
   启动桥接"（会先用和"保存并应用"完全相同的校验保存设置，校验通过后
   才启动，无参数桥接进程），或者关闭设置窗口后从 Start Menu 选择"启动
   Open Voice Bridge · RC003"。"桥接控制"区域会显示以下四种状态之一：
   未启动、已启动/运行中、已经在运行（检测到重复启动）、启动异常或
   快速退出（附带真实退出码）——"运行中"只说明桥接进程本身存活，
   **不代表已经与 RC003 建立连接**，实际连接、按键和语音状态仍以下一步
   的日志为准；
3. 按一下普通按键（例如方向键、确定键）确认按键映射生效；
4. 在测试遥控器麦克风键之前，先在“按键映射”页确认麦克风键的组合键。新安装默认为较少冲突的 `Ctrl+Shift+U`；这个值必须与你的输入法语音快捷键相同。如果使用 Windows 系统语音键入，则改为 `Win+H`。然后先手动确认该组合键本身能正常工作：
   打开记事本（或任意可编辑文本框），把光标点进文本区域，按一次键盘上的
   按下刚才配置的组合键，确认目标输入法的语音功能出现、说话后有文字被输入。这需要同时满足：
   光标确实停留在一个可编辑的文本输入框中（听写没有可输入目标时不会
   生效）；Windows 已启用"联机语音识别"（Windows 11：设置 → 隐私和安全性 → 语音；Windows 10：设置 → 隐私 → 语音，听写依赖联网的语音识别服务）；
   系统当前的麦克风输入设备选择的是
   `CABLE Output`（如果按上一节配置了 VB-CABLE）。手动测试通过后，光标
   保持在同一个可编辑文本框中，按住遥控器麦克风键说话，检查是否有文字
   被输入——同样要求语音输出/系统麦克风输入的方向配置与手动测试时一致，
   否则语音会静默失败（按键仍然可用）；如果手动组合键都无法工作，请先
   解决那个问题，本程序不能让本来就不工作的系统听写变得可用；
5. 需要时从 Start Menu 选择"停止 Open Voice Bridge · RC003"结束桥接，
   或从"设置 → 应用"/Start Menu 的"卸载"条目卸载（卸载会先自动停止
   正在运行的进程，再删除安装时写入的程序文件）。遇到按键/语音/启动
   问题时，可以在设置窗口点击"打开日志目录"直接定位到
   `%LOCALAPPDATA%\OpenVoiceBridge\RC003\logs`；如果这台电脑上程序还
   从未运行过，日志目录本身也不存在，该按钮会如实提示，而不是伪造一份
   日志。**卸载不会自动删除设置和日志**：`config.json`、`key_bindings.json` 和 `logs\app.log`
   会一直保留在 `%LOCALAPPDATA%\OpenVoiceBridge\RC003` 下，因为
   安装脚本没有为这些运行期生成的文件配置卸载删除规则。如果这台
   电脑上不会再安装任何 RC003 版本（安装器或便携版）、也不需要
   保留这些设置和日志，可以在卸载完成后手动删除整个
   `%LOCALAPPDATA%\OpenVoiceBridge\RC003` 文件夹；如果还会用到
   同一台电脑上的另一个 RC003 安装，请不要删除这个共享目录。

**便携版 ZIP 用户**

便携版没有打包 Start Menu 入口、没有停止脚本，也没有卸载程序；
下面每一步都在解压出的文件夹里手动执行：

1. 打开 PowerShell，`cd` 到解压出的文件夹，运行
   `.\OpenVoiceBridgeRC003.exe --settings` 打开设置窗口，
   在"语音输出设备"下拉框中选择上一节配置好的端点；
2. 启动桥接有两种等价方式：在设置窗口底部"桥接控制"区域点击"保存并
   启动桥接"（先保存、校验通过后才启动）；或者关闭设置窗口，在同一个
   文件夹里运行不带任何参数的 `.\OpenVoiceBridgeRC003.exe` 启动桥接
   （这会直接启动桥接进程本身，不会再打开设置窗口）。"桥接控制"区域会
   显示未启动、已启动/运行中、已经在运行、启动异常或快速退出四种状态之
   一，"运行中"只说明进程本身存活，**不代表已经与 RC003 建立连接**；
3. 按一下普通按键（例如方向键、确定键）确认按键映射生效；
4. 手动确认已配置语音组合键的步骤和上面"安装器用户"一节完全相同（打开
   记事本、光标点进可编辑文本框、按下已配置的组合键、确认语音识别已启用、
   确认系统麦克风输入选择的是 `CABLE Output`），这里不重复；
5. **停止**：便携版没有停止脚本，也没有 Start Menu 条目——需要打开
   任务管理器（`Ctrl+Shift+Esc`），在"详细信息"标签页找到
   `OpenVoiceBridgeRC003.exe` 对应的进程，选择"结束任务"；
   **卸载/移除**：便携版没有安装程序，不写注册表；删除整个解压出来
   的文件夹即可移除程序本体。但便携版运行时同样会把 `config.json`、
   `key_bindings.json` 和 `logs\app.log` 写到
   `%LOCALAPPDATA%\OpenVoiceBridge\RC003`（和安装器用的是同一个
   目录）——删除解压文件夹**不会**清除这些设置和日志文件。如果这台
   电脑上不会再用到任何 RC003 安装（便携版或安装器）、也不需要保留
   这些设置和日志，可以额外手动删除整个
   `%LOCALAPPDATA%\OpenVoiceBridge\RC003` 文件夹；如果还会用到
   同一台电脑上的另一个 RC003 安装，请不要删除这个共享目录。

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
真实行为、ATVV 语音延迟与音量、用户配置的语音组合键实际效果均待真机核验。

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
- Synthesizes the configured voice hotkey (default `Ctrl+Shift+U` for a new
  installation; set it to `Win+H` for Windows Voice Typing) in response to
  the device's own mic-button press/release: in toggle mode, a key **tap**
  on mic-button-press (starting Windows' own Win+H dictation toggle) and
  another tap on the device's own `AUDIO_STOP` (turning that same toggle
  back off) - it never holds the key down across the stream, but also never
  leaves Windows dictation running after the device stops; or a real hold
  (key-down on press, key-up on `AUDIO_STOP`) in hold mode. Cleanup/reset
  always closes out whichever action is still owed.
- Ships a PySide6-Essentials + Qt Quick/QML settings window (XRBM-030,
  replacing the earlier Tk candidate) with a four-page structure: the first
  three pages - "连接"/"按键"/"权限" - match the macOS client's
  `SettingsView.swift` structure and content system (corner radii, spacing,
  semantic light/dark colors) - see below for a fourth "检查与修复" page
  added in XRBM-031, which has no macOS counterpart. It shares
  the same macOS-verified RC003 product-photo hotspot coordinates, while
  keeping Windows' own title bar and a Qt Quick Controls "FluentWinUI3"
  style for Windows 11 Fluent-language chrome (never the macOS red/yellow/
  green traffic lights). The "按键" page's photo hotspots and its mapping
  list are two views over the same row data (`ButtonMappingModel`, a
  `QAbstractListModel`): clicking either one selects/highlights both. The
  mic hotspot/row stays fixed and read-only - there is still no dedicated
  physical mute key (see "Default button mapping" below). The "连接" page's
  "保存并启动桥接" ("Save and start the bridge") button (XRBM-029) runs the
  same validation as the plain save button, and only launches the
  no-argument bridge process if that save succeeded; a "打开日志目录" ("Open
  log directory") button (present on both the "连接" and "权限" pages) opens
  the canonical `%LOCALAPPDATA%\OpenVoiceBridge\RC003\logs` directory,
  honestly reporting when it does not exist yet rather than fabricating a
  log. The "权限" page only ever offers to open the relevant Windows Settings
  page (Bluetooth / microphone privacy / speech recognition) - it never
  renders a fabricated "已授权" state, since Windows exposes no single API
  this app can query for that the way macOS's TCC database does.
  `bridge_launcher.py` builds the correct launch command for whichever
  process shape is currently running (the frozen `.exe` itself with no
  arguments, or the current Python interpreter with `-m ovb_rc003` from
  source) and watches the child for a short grace period to distinguish
  four states shown in the window: not started, started/still running,
  already running (a duplicate launch the single-instance guard in
  `single_instance.py` rejected, via its exact
  `DUPLICATE_INSTANCE_EXIT_CODE`), and an abnormal/quick exit (any other
  exit code, or the process never being created at all - both preserve the
  real exit code/error text rather than swallowing it). The "started"
  state is deliberately never described as "RC003 已连接"/"RC003
  connected" - a live process is not evidence of an actual BLE/HID/audio
  connection, which is only observable from `app.log`. Every piece of
  validation/save/launch/log-status logic lives in plain, Qt-free functions
  in `settings_ui.py` (unchanged by the Tk-to-Qt swap); `qt_settings_app.py`
  only bridges them to QML via `SettingsController` (a `QObject`) and
  `ButtonMappingModel`, both exposed to QML as singletons (see that
  module's docstring for why not as root-context properties). Running
  `python -m ovb_rc003 --settings` from source without PySide6-Essentials
  installed raises a clear, actionable error instead of failing to import
  or silently doing nothing; the packaged `.exe` always bundles its own Qt
  runtime (see "Building an unsigned candidate" below), so end users of a
  release build never need to separately install Python or Qt.
- Adds a fourth "检查与修复" (check-and-repair) settings page (XRBM-031):
  `windows_diagnostics.py` (Qt-free, no PySide6 import) runs a stable set of
  checks - Windows version/64-bit architecture, exactly one paired RC003 BLE
  candidate, exactly one matching Raw Input device (reported only as a
  count, never a device path), whether VB-CABLE's `CABLE Input`/`CABLE
  Output` endpoints exist, whether the saved output endpoint still resolves
  and whether it is `CABLE Input`, and Windows dictation (Win+H), which is
  always reported as `待手动验证` with concrete manual-test instructions,
  never a fabricated pass - grouped into ordinary-button, RC003-voice-
  bridge, dictation, and optional-driver sections so a live bridge process
  or a paired device is never presented as proof that buttons or speech
  actually work. `qt_settings_app.DiagnosticsController` runs every check on
  a background Python thread (never the Qt GUI thread) and delivers the
  result back via a cross-thread Qt signal; repeated "重新检测" clicks while
  a check is already running are ignored rather than starting a second,
  overlapping worker. The same page can select the uniquely detected `CABLE
  Input` as the app's output (persisted only after that explicit click) and
  can launch VB-CABLE's own official setup UI - see "VB-CABLE driver helper
  (optional, XRBM-031)" below for that flow's own dedicated hash-gated
  extraction/UAC-elevation contract.

## What this deliberately does NOT do

- Does not silently install, enable, or uninstall VB-CABLE or any other
  audio driver - see "VB-CABLE driver helper (optional, XRBM-031)" below for
  the one, explicit-user-click, UAC-gated exception this candidate does
  implement, and exactly how narrow it is.
- Does not change the Windows default input or output device, ever - not
  even while installing/repairing VB-CABLE.
- Does not persist or log a real Bluetooth address, HID device interface
  path/GUID, or device token (enforced in code - see `config.py`'s
  `FORBIDDEN_KEYS` guard, which is checked **recursively** through nested
  dicts/lists, and `tests/test_privacy_contract.py`); `windows_diagnostics.py`
  reports the Raw Input/BLE checks as a count/status only, never a path or
  name, for the same reason.
- Does not request administrator elevation for its own application process,
  anywhere, ever - `src/ovb_rc003/vb_cable_bundle.py` is the sole, disclosed
  exception in this source tree (see `tests/test_privacy_contract.py`'s
  `test_elevation_exception_is_scoped_to_the_vendor_vb_cable_launch_only`),
  and it only ever requests UAC to launch the THIRD-PARTY vendor's own setup
  UI, never to elevate this project's own process.
- Does not enable start-on-login.
- Does not use `pnputil`, silent/unattended install flags, scripted UI
  click-automation, a UAC bypass, or a direct driver-store mutation anywhere
  - VB-CABLE setup is always the vendor's own, unmodified, interactive
    installer UI.
- Does not remove or silently modify an already-installed VB-CABLE during
  this application's own install/uninstall - the application installer never
  touches it at all; only the diagnostics page's own explicit action can
  reopen the vendor's setup UI for a vendor-controlled repair/removal.
- Does not bundle any third-party EXECUTABLE binary directly in source
  control. The optional Frida Gadget fetch script
  (`build/fetch-frida-gadget.ps1`) only ever pulls the official release
  asset over HTTPS and verifies a pinned SHA-256 before use - and even then,
  the actual injection step is intentionally unimplemented in this candidate
  (see "Known gaps"). `build/fetch-vb-cable.ps1` (XRBM-031) similarly fetches
  and hash-verifies VB-Audio's own official VB-CABLE Basic package before a
  real Windows build bundles it as opaque application data (see "VB-CABLE
  driver helper" below) - never committed to Git either.

## VB-CABLE driver helper (optional, XRBM-031)

The "检查与修复" settings page can optionally help install VB-Audio's
official [VB-CABLE](https://vb-audio.com/Cable/) Basic package
(<https://www.vb-cable.com>, licensing terms at
<https://vb-audio.com/Services/licensing.htm>) - an independent Donationware
product, not GPL-3.0 project code - so a recognizer/listening app has a
virtual microphone to read RC003 voice from. This is entirely optional:
ordinary button mapping never needs it, and not installing it changes
nothing else about this candidate.

- **Build time**: `build/fetch-vb-cable.ps1` downloads the official
  `VBCABLE_Driver_Pack45.zip` over HTTPS and verifies its SHA-256 against a
  pin recorded in `src/ovb_rc003/vb_cable_bundle.py` - both
  `build/build-candidate.ps1` and `.github/workflows/windows-rc003-ci.yml`
  run this as a required step before PyInstaller, so a download failure or
  hash mismatch fails the whole build closed. The verified, **unmodified**
  ZIP is then bundled into the frozen build as opaque application data -
  never committed to Git (`build/third_party/` is gitignored) - so the
  installed/portable candidate can offer this option fully offline.
- **Run time**: nothing happens automatically. Only when a user clicks
  "安装/修复 VB-CABLE…" on the diagnostics page, confirms a second, explicit
  in-app dialog (which states the Donationware/independent-license facts,
  that only the Basic package is bundled - never the paid A+B/C+D - and that
  installing changes the system and needs a reboot), does
  `src/ovb_rc003/vb_cable_bundle.py` locate the bundled ZIP, **re-verify**
  its SHA-256 (independently of the build-time check above), and reject the
  extraction outright on a hash mismatch, a missing `VBCABLE_Setup_x64.exe`
  member, or any unsafe ZIP member (an absolute path, a `..` traversal
  segment, or a symlink) - the entire, unmodified archive is then extracted
  into a freshly created, isolated temporary directory, and only the
  official, unmodified `VBCABLE_Setup_x64.exe` is launched, with that
  temporary directory as its working directory, via Windows' own `runas`/UAC
  verb (`os.startfile(path, "runas", cwd=...)`) - a real elevation prompt the
  user can cancel (reported honestly as a cancellation, not an error) at any
  point. No silent-install flag, scripted click-through, UAC bypass,
  `pnputil` call, PowerShell execution-policy bypass, or direct driver-store
  write is ever used - this is exactly the vendor's own interactive
  installer, the same one a user would get by manually downloading and
  running it from VB-Audio's site.
- **Never a fabricated success.** Launching the setup UI is never reported
  as "installed" - only that the vendor UI was launched. VB-CABLE's own
  installer requires a reboot; the only way this candidate confirms the
  driver is actually present is the diagnostics page's own
  `windows_diagnostics.check_vb_cable_endpoints()` recheck (via "重新检测")
  finding both `CABLE Input`/`CABLE Output` endpoints afterward.
- **Endpoint selection stays explicit.** The diagnostics page's "选择检测到
  的 CABLE Input 作为输出" button re-enumerates real playback endpoints at
  click time and persists the choice only if exactly one `CABLE Input`-named
  endpoint currently exists (matching `CABLE Input` or a
  `CABLE Input (<host API>)`-decorated name, never an unrelated
  similarly-named device) - never auto-selected, and never on page load.
- **The application's own installer/uninstaller are unaffected.** The main
  Inno Setup installer stays `PrivilegesRequired=lowest`, never runs the
  driver helper during install or uninstall, and never removes an
  already-installed VB-CABLE when this application is uninstalled - only the
  diagnostics page's own explicit action can reopen the vendor's setup UI
  for a vendor-controlled repair/removal.
- **Not yet exercised against a real Windows machine or a real VB-CABLE
  install** (see "Known gaps"): the ZIP-safety logic is covered by tests
  using synthetic, locally-constructed ZIP fixtures (never the real vendor
  binary, which this macOS development environment cannot fetch/verify at
  all - see the implementation report's validation section for exactly what
  was and was not run here), and the `os.startfile(..., "runas", ...)` call
  itself is Windows-only and has not been invoked for real anywhere in this
  repository or its CI.

## Default button mapping

| RC003 button | Windows action |
| --- | --- |
| Mic | Voice lifecycle action; host chord defaults to `Ctrl+Shift+U` and is directly editable in this row |
| Power | Escape |
| Up / Down / Left / Right | Arrow keys |
| OK | Enter |
| Back | *(unmapped in this candidate — see "Known gaps")* |
| Volume + / − | System volume + / − |
| Home | Win+D |
| Menu | Shift+F10 |
| TV | Alt+Esc |

Every ordinary mapping row is user-editable in the settings window
(`python -m ovb_rc003 --settings`) and persisted to
`%LOCALAPPDATA%\OpenVoiceBridge\RC003\key_bindings.json`. The Mic row keeps
the physical button's action fixed as voice, while directly editing the host
chord stored in `config.json`. `build_save_model()`/`config.load_key_bindings()`
both force the button action back to voice regardless of what a saved file
contains (XRBM-019, folded in from a XRBM-018 review round 2 product-
contract finding): the physical mic button is always driven directly by
the ATVV voice lifecycle - the runtime never consults a stored `mic`
binding at all, so it must not be presented (or ever saved) as an ordinary,
freely-editable key mapping. The voice hotkey text and toggle/hold trigger
mode remain fully configurable in the same window. Existing installations
retain their previously saved chord; only a config with no saved value receives
the new `Ctrl+Shift+U` default.

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
- **Settings UI screenshot is an offscreen macOS render, not a real Windows
  capture.** XRBM-030 replaced the earlier Tk text-list mapping view with a
  Qt Quick/QML settings window that DOES now have clickable photo hotspots
  at the same coordinates as the macOS app (see "What this does" above).
  The screenshot referenced in this task's own (internal, not publicly
  shipped) implementation report was produced via `QT_QPA_PLATFORM=offscreen`
  on macOS (this project's actual development machine), using the real QML
  files and a real rendered frame
  - not a mockup - but it is still not the same as a screenshot taken from
  a real Windows build with the "FluentWinUI3" Qt Quick Controls style
  running natively; the repository root `README.md`'s clickable-photo
  mapping screenshot (`docs/images/rc003-mapping-settings.jpg`) remains the
  **macOS** app's own settings UI, unrelated to this one.
- **The "检查与修复" page and VB-CABLE driver helper (XRBM-031) are not yet
  verified on a real Windows machine or against the real vendor package.**
  Every diagnostic check's PASS/FAIL/UNSUPPORTED branching, the ZIP-safety
  logic (hash mismatch, traversal, symlink, missing setup member), and the
  UAC-cancellation handling are covered by tests using synthetic fixtures and
  injected fakes; `build/fetch-vb-cable.ps1` and the real `os.startfile(...,
  "runas", ...)` call have not been exercised for real anywhere in this
  repository or its CI (this development machine is macOS and cannot run
  either). Real Windows CI, a real frozen build actually bundling the
  fetched ZIP, and a real RC003 + VB-CABLE hardware retest all remain
  outstanding next steps - see this candidate's own implementation report
  for the exact commands run and their results.

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

`--settings` requires PySide6-Essentials (in `requirements.txt` above,
XRBM-030) to actually open the Qt Quick/QML window; `--dry-run` and every
other module import in this package never require it (see
`qt_settings_app.py`'s module docstring). Running `--settings` from source
without it installed raises a clear `QtUnavailableError` telling you to
install `requirements.txt`, rather than crashing on an unrelated import
error or silently doing nothing.

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
settings-save model (no Tk/Qt window constructed, including that a non-voice
`mic` value can never be saved even if somehow supplied), the RC003 photo
hotspot layout table and physical-button display strings (pure data, no Qt
- `tests/test_remote_layout.py`), the external-Settings-page/log-directory
open adapter used by the "权限" page (`tests/test_shell_targets.py`, no real
OS shell call ever made), the `ButtonMappingModel`/`SettingsController` Qt
adapters and an offscreen QML load of the real `main.qml` (skips with an
explicit reason if PySide6-Essentials is not installed -
`tests/test_qt_settings_app.py`), a static contract on the PyInstaller spec
declaring the required Qt hiddenimports/qml `datas` collection
(`tests/test_build_artifacts.py`), the connection
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
timing-based sleep), the bridge-launch command construction and outcome
detection (frozen-exe-no-args vs. source-`-m ovb_rc003`, and all four
started/already-running/quick-exit/launch-failed outcomes, via an injected
fake `Popen`/`sleep` so no real process is ever spawned and no real time is
ever slept - XRBM-029), the canonical log-location helpers (directory/file
present-or-missing detection never creates anything, and the "open log
directory" call is exercised via an injected fake so no real OS file browser
ever opens - XRBM-029), the PowerShell boundary-scan replay, and
build-artifact/privacy-contract checks (including that the CI workflow's
Inno Setup step is a required gate, not best-effort), the "检查与修复"
diagnostics checks (`tests/test_windows_diagnostics.py`, XRBM-031: every
PASS/FAIL/MANUAL/UNSUPPORTED branch via injected fakes, never a real
WinRT/PortAudio call in this test file itself), and the VB-CABLE driver
helper's hash verification, safe-extraction (hash mismatch, absolute path,
`..` traversal, symlink, missing setup member - via synthetic ZIP fixtures,
never the real vendor binary), and UAC-cancellation handling
(`tests/test_vb_cable_bundle.py`). The Windows-only
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
the public-boundary scan, **fetches and hash-verifies the official VB-CABLE
Basic package** (`build/fetch-vb-cable.ps1` - XRBM-031, a required step that
fails the whole build closed on a download failure or hash mismatch), runs
the test suite, invokes PyInstaller against
`build/OpenVoiceBridgeRC003.spec`, then smoke-checks the built executable
with `--dry-run` (imports every module, touches no GUI/BLE/HID/audio, exits
0) - producing an **unsigned** one-dir build under
`dist/OpenVoiceBridgeRC003/`. See `installer/OpenVoiceBridgeRC003Setup.iss`
for the Inno Setup source (also unsigned; `PrivilegesRequired=lowest`, no
autostart task, no driver install steps - the driver helper is only ever
reached from inside the running application's own diagnostics page, never
from the installer).

The frozen build bundles its own Qt runtime (PySide6-Essentials' Qt
libraries/plugins, collected automatically by PyInstaller's own PySide6
hooks), this package's own `qml/` sources (collected explicitly by
`build/OpenVoiceBridgeRC003.spec` under `ovb_rc003_qml/` - see the spec's
comments), and the verified, unmodified VB-CABLE ZIP under
`vb_cable_bundle/` (present only if `fetch-vb-cable.ps1` already ran) - end
users of a built candidate never need to separately install Python, PySide6,
Qt, or (should they choose to use the driver helper) even network access to
fetch VB-CABLE themselves.

`.github/workflows/windows-rc003-ci.yml` runs the same boundary scan, test
suite, PyInstaller build, `--dry-run` smoke check, and Inno Setup compile
(never runs/installs the result) on a real Windows GitHub Actions runner
whenever this subtree changes - every one of those is a required gate
(XRBM-018: the Inno Setup compile step was promoted from best-effort to
required), so a failure anywhere fails the whole job. CI has no RC003
hardware attached, so it cannot and does not exercise real-device behavior.
Fixed baseline run
[29645685087](https://github.com/nijez/open-voice-bridge/actions/runs/29645685087)
passed all 443 tests (skipped=3) and produced a hash-verified,
deterministic three-file package (installer + portable ZIP +
`SHA256SUMS.txt`) - a later run may report a different test count as the
suite grows; see the "中文安装与使用说明" section's "获取构建产物" above
for how to obtain a published prerelease built the same way.

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
