# Open Voice Bridge · 开放语音桥

Open Voice Bridge 是一个面向无线麦克风、语音遥控器和其他语音/按键外设的跨设备、跨传输、跨平台桥接框架。

它把问题拆成六层：设备身份与能力、传输、设备协议、音频图、动作映射和平台后端。一个设备可以组合 BLE GATT、Bluetooth HID、USB 数字音频或系统音频输入；macOS、Windows、Linux 分别实现自己的权限与 I/O 后端。

> 当前唯一已完成实现和真机验收的组合是：**Xiaomi Bluetooth Remote 2 Pro / RC003 + macOS**。Windows、Linux 和 DJI Mic 2 仍是 planned/research，不应理解为已经支持。

## 当前支持矩阵

| 设备 | macOS | Windows | Linux | 主要传输 |
| --- | --- | --- | --- | --- |
| Xiaomi RC003 | 已实现并真机验收 | 计划中 | 计划中 | BLE GATT（ATVV 语音）+ Bluetooth HID（按键） |
| DJI Mic 2 | 调研中 | 调研中 | 调研中 | 优先研究接收器 USB-C 数字音频；桌面蓝牙不作先验承诺 |
| 其他语音外设 | 通过 device profile 接入 | 通过 platform backend 接入 | 通过 platform backend 接入 | 以真实设备枚举和协议证据为准 |

DJI 官方说明 Mic 2 接收器可以通过 USB-C 连接电脑；其发射器直接蓝牙兼容列表主要包含指定 DJI 设备与手机。因此本项目不会因为设备“支持蓝牙”就把它假设为桌面通用蓝牙麦克风。相关资料见 [DJI Mic 2 Specs](https://www.dji.com/mic-2/specs) 和 [DJI Mic 2 FAQ](https://www.dji.com/mic-2/faq)。

## 框架入口

- [总体架构](docs/ARCHITECTURE.md)
- [添加新设备适配器](docs/ADDING_A_DEVICE.md)
- [设备 profile Schema](specs/device-profile.schema.json)
- [已实现的 Xiaomi RC003 profile](device-profiles/xiaomi-rc003.json)
- [DJI Mic 2 调研 profile](device-profiles/dji-mic-2.json)

Profile 只记录可核对的事实与状态，不是驱动。只有代码、自动验证和目标平台真机门都通过后，某个设备/平台组合才会标为 `implemented`。

## 第一个适配器：Xiaomi RC003 for macOS

现有 `XiaomiRemoteBridgeMac` target、应用显示名和 Bundle ID 暂时保留，避免总项目改名导致已安装用户重新授予蓝牙、输入监控和辅助功能权限。历史 [v0.2.0 测试版](https://github.com/nijez/xiaomi-remote-bridge-mac/releases/tag/v0.2.0) 继续代表这个设备专用适配器。

当前功能：

- 精确发现、连接和重连 RC003；
- Android TV Voice-over-BLE（ATVV）能力协商与 16 kHz IMA/DVI ADPCM 解码；
- 把语音写入用户选择的 CoreAudio 输出，配合 BlackHole 等回环设备作为虚拟麦克风；
- 仅对 RC003 把真实 F5 硬件按下/松开映射为 Mac Fn/🌐︎，退出时恢复原映射；
- IOHID 原始按键读取，以及方向、确定、返回、主页、菜单、TV、音量等动作映射；
- 保持原比例的 RC003 实物图与图形化映射设置。

### 系统要求

- macOS 11 Big Sur 或以上；
- Apple Silicon 或 Intel Mac；
- 已在系统蓝牙中配对 RC003；
- 语音作为虚拟麦克风使用时，安装 [BlackHole 2ch](https://existential.audio/blackhole/) 或等价 CoreAudio 回环设备。

应用不会自动安装音频驱动，也不会修改系统默认输入/输出设备。

### 构建与验证

```bash
./scripts/test.sh
./scripts/build-app.sh --universal
./scripts/verify-app.sh --universal
```

生成带应用、安装说明、许可证和对应源码的测试 DMG：

```bash
./scripts/build-dmg.sh
./scripts/verify-dmg.sh
```

当前 macOS 11 部署目标已完成双架构编译与打包校验，但尚未在真实 macOS 11 机器上运行验收。

### 权限与语音

首次启用当前 RC003 适配器时，按系统提示允许：

1. 蓝牙：发现与连接 RC003；
2. 输入监控：读取 RC003 原始 HID report；
3. 辅助功能：发送用户配置的 macOS 动作。

语音使用：

1. 在应用设置中选择 `BlackHole 2ch` 作为语音输出；
2. 在目标输入法或语音应用中选择同一个设备作为麦克风；
3. 按住遥控器麦克风键说话，松开时释放 Fn 并结束 ATVV 语音流。

### 默认按键

| 遥控器按键 | macOS 动作 |
| --- | --- |
| 方向 / 确定 | 方向键 / Return |
| 返回 | Delete（退格） |
| 主页 | 显示桌面（Fn-F11） |
| 菜单 | Shift-F10 |
| TV | Command-Tab |
| 电源 | Escape |
| 音量 + / - | 系统音量增减 |

## 安全与隐私

- 不上传语音，不保存语音文件；PCM 只在内存与用户选定的音频设备之间流动。
- 不自动修改系统默认输入/输出。
- 不保存真实蓝牙地址；日志不记录语音内容或外设 UUID。
- 权限不足、身份不匹配或协议不满足时失败关闭。
- 新设备和新平台必须分别通过自己的权限、断线、音频和真机验收。

## 来源与许可

第一个 Xiaomi RC003 适配器的 ATVV UUID、握手、HID usage 与 IMA/DVI ADPCM 行为参考 GPL-3.0 项目 [xxb26553663-star/remote-bridge-hub](https://github.com/xxb26553663-star/remote-bridge-hub)，参考 revision `8a93f321ac71a602300c6cd77f7256fa4b63068e`。

本项目代码统一按 `GPL-3.0-only` 发布。参考项目的品牌与商业资产不包含在本项目中；RC003 图片和 Xiaomi 商标也不因代码许可证获得额外授权。修改与归属说明见 `COPYRIGHT` 和 `THIRD_PARTY_NOTICES.md`。
