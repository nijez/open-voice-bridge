import AppKit
import SwiftUI

/// Loads each bundled remote photo once for the process lifetime. SwiftUI may
/// evaluate a view body many times during AppKit layout; doing synchronous
/// ImageIO work from that body can turn an otherwise idle settings window into
/// a continuous layout/render loop.
private enum RemoteImageCatalog {
    private static let rc003Pro = load(.rc003Pro)
    private static let arn9 = load(.arn9)

    static func image(for variant: XiaomiRemoteVariant) -> NSImage? {
        switch variant {
        case .rc003Pro: return rc003Pro
        case .arn9: return arn9
        }
    }

    /// Forces the two tiny bundled images to decode before SwiftUI evaluates a
    /// view body. This keeps even the one-time ImageIO cost out of layout.
    static func prewarm() {
        _ = rc003Pro
        _ = arn9
    }

    private static func load(_ variant: XiaomiRemoteVariant) -> NSImage? {
        guard let url = Bundle.main.url(
            forResource: variant.imageResourceName,
            withExtension: "png"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }
}

private enum DeviceWorkspaceSelection: String, CaseIterable, Identifiable {
    case xiaomiRC003Pro
    case xiaomiARN9
    case djiMic2

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .xiaomiRC003Pro: return "2 Pro"
        case .xiaomiARN9: return "普通款"
        case .djiMic2: return "DJI Mic 2"
        }
    }
}

private struct ShortcutRecordingTarget: Identifiable {
    let button: RemoteButton
    let slot: ButtonGestureSlot

    var id: String { "\(button.rawValue)-\(slot.rawValue)" }
}

struct SettingsView: View {
    @ObservedObject var model: BridgeAppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    @ObservedObject var updateController: AppUpdateController
    @State private var selectedRemoteButton: RemoteButton = .ok
    @State private var recordingTarget: ShortcutRecordingTarget?
    @State private var expandedMultiActionButton: RemoteButton?
    @State private var doubleClickTimingText: String
    @State private var longPressTimingText: String
    @State private var bridgeHelpPresented = false
    @State private var audioDiagnosticsExpanded = false
    @State private var localFnHelpExpanded = false

    // These two cards sit in the same row. Keep their collapsed presentation
    // aligned with a stable floor, rather than measuring a child and writing
    // that measurement back into this view's state. The latter creates a
    // layout → state update → layout feedback path in AppKit.
    private static let bottomSettingsCardCollapsedMinHeight: CGFloat = 176

    init(model: BridgeAppModel, updateController: AppUpdateController) {
        RemoteImageCatalog.prewarm()
        self.model = model
        settings = model.settings
        launchAtLogin = model.launchAtLoginManager
        self.updateController = updateController
        _doubleClickTimingText = State(initialValue: String(model.settings.multiActionDoubleClickMs))
        _longPressTimingText = State(initialValue: String(model.settings.multiActionLongPressMs))
    }

    var body: some View {
        VStack(spacing: 0) {
            deviceSelector

            Divider()

            TabView {
                generalTab
                    .tabItem { Label("连接", systemImage: "antenna.radiowaves.left.and.right") }
                mappingTab
                    .tabItem {
                        Label(
                            settings.selectedDeviceProfile == .xiaomiRC003 ? "按键" : "设备控制",
                            systemImage: settings.selectedDeviceProfile == .xiaomiRC003 ? "keyboard" : "slider.horizontal.3"
                        )
                    }
                permissionsTab
                    .tabItem { Label("权限", systemImage: "lock.shield") }
                supportedDevicesTab
                    .tabItem { Label("支持设备", systemImage: "list.bullet.rectangle") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: 760,
            idealWidth: 860,
            maxWidth: .infinity,
            minHeight: 600,
            idealHeight: 680,
            maxHeight: .infinity
        )
        .padding()
    }

    private var deviceSelector: some View {
        HStack(spacing: 12) {
            deviceVisual

            VStack(alignment: .leading, spacing: 3) {
                Text(activeDeviceDisplayName)
                    .font(.headline.weight(.semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(activeDeviceTint)
                        .frame(width: 7, height: 7)
                    Text(activeDeviceSummary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if availableWorkspaceSelections.count > 1 {
                Picker("当前设备", selection: Binding(
                    get: { activeWorkspaceSelection },
                    set: { selectWorkspace($0) }
                )) {
                    ForEach(availableWorkspaceSelections) { selection in
                        Text(selection.shortName).tag(selection)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.accentColor.opacity(0.14), lineWidth: 1)
        )
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var deviceVisual: some View {
        if settings.selectedDeviceProfile == .xiaomiRC003,
           let thumbnail = RemoteImageCatalog.image(for: settings.xiaomiRemoteVariant)
        {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 68)
                .padding(4)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
                Image(systemName: "mic.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.accentColor)
            }
            .frame(width: 56, height: 68)
        }
    }

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if settings.selectedDeviceProfile == .xiaomiRC003 {
                    rc003ConnectionSections
                    HStack(alignment: .top, spacing: 12) {
                        localFnCard
                        applicationCard
                    }
                } else {
                    djiConnectionSections
                    applicationCard
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
        .onAppear {
            model.refreshLaunchAtLoginStatus()
            model.refreshAudioDevices()
            model.refreshMicrophonePermission()
        }
    }

    @ViewBuilder
    private var rc003ConnectionSections: some View {
        settingsCard(
            "连接概览",
            systemImage: "antenna.radiowaves.left.and.right",
            headerAccessory: AnyView(connectionOverviewActions)
        ) {
            HStack(spacing: 10) {
                statusMetric(
                    title: "蓝牙",
                    value: compactConnectionStatus,
                    systemImage: "dot.radiowaves.left.and.right",
                    tint: rc003Connected ? .green : .orange
                )
                audioStatusMetric(
                    title: "语音",
                    value: model.isStreaming ? "正在输入" : "等待按键",
                    systemImage: model.isStreaming ? "mic.fill" : "mic",
                    tint: model.isStreaming ? .green : .accentColor,
                    level: model.audioPathSnapshot.queued.meterValue
                )
                statusMetric(
                    title: "按键桥接",
                    value: compactHIDStatus,
                    systemImage: "keyboard",
                    tint: hidIsReady ? .green : .orange
                )
            }
        }

        settingsCard(
            "语音键与桥接",
            systemImage: model.bridgeEnabled ? "switch.2" : "pause.circle",
            headerAccessory: AnyView(bridgeHeaderActions)
        ) {
            HStack(spacing: 8) {
                Toggle("双击语音键切换启用/停用", isOn: Binding(
                    get: { settings.doubleClickToggleEnabled },
                    set: { model.setDoubleClickToggleEnabled($0) }
                ))
                Spacer(minLength: 8)
                Button {
                    bridgeHelpPresented.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 15, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("查看双击规则与降级说明")
                .accessibilityLabel(Text("查看双击规则与降级说明"))
                .popover(isPresented: $bridgeHelpPresented, arrowEdge: .bottom) {
                    bridgeHelpPopover
                }
            }
        }

        settingsCard("语音输出", systemImage: "waveform") {
            Picker("语音输出", selection: Binding(
                get: { settings.selectedAudioDeviceUID },
                set: { value in
                    settings.selectedAudioDeviceUID = value
                    model.applyAudioSettings()
                }
            )) {
                Text("不输出语音").tag("")
                ForEach(model.audioDevices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            HStack {
                Text("增益")
                Slider(value: Binding(
                    get: { settings.gainDB },
                    set: { settings.gainDB = $0 }
                ), in: 0...24, step: 1)
                Text("\(Int(settings.gainDB)) dB")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 52, alignment: .trailing)
            }
            statusRow("音频状态", value: model.audioStatus)
            HStack {
                Button("刷新音频设备") { model.refreshAudioDevices() }
                Link("获取 BlackHole", destination: URL(string: "https://existential.audio/blackhole/")!)
                Spacer()
                Button("发送 1 秒测试音") { model.sendTestTone() }
                    .disabled(!model.canSendTestTone)
            }
            Text(model.testToneStatus)
                .font(.footnote)
                .foregroundColor(.secondary)
            Text("应用只把 RC003 语音写到所选设备，不修改系统默认输入或输出；测试音在内存生成、低音量、固定频率且不落盘，RC003 语音进行中时不可用。")
                .font(.footnote)
                .foregroundColor(.secondary)

            Divider()
            DisclosureGroup("语音链路诊断", isExpanded: $audioDiagnosticsExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    audioSignalRow(
                        title: "遥控器 PCM（已解码）",
                        detail: "只证明遥控器音频已在本应用解码为 PCM；电平跳动不代表语音一定可懂。",
                        level: model.audioPathSnapshot.decoded,
                        status: model.audioPathSnapshot.decodedStatusText
                    )
                    audioSignalRow(
                        title: "应用 → 所选音频设备（已排队）",
                        detail: "只证明本应用已向所选输出设备提交音频；不等于虚拟声卡输入端或输入法已经收到。",
                        level: model.audioPathSnapshot.queued,
                        status: model.audioPathSnapshot.queuedStatusText
                    )
                    statusRow("播放节点", value: model.audioPathSnapshot.playbackState.displayText)
                    Text("“已完成到输出节点”只代表本应用播放器完成回执；回执超时不会被伪装成成功。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    statusRow("第三方输入法", value: "状态未知（系统未提供读取/提交回执）")
                }
                .padding(.top, 8)
            }
        }

    }

    private var localFnCard: some View {
        settingsCard(
            "Mac 键盘 Fn",
            systemImage: "keyboard",
            minHeight: Self.bottomSettingsCardCollapsedMinHeight
        ) {
            Toggle("按住物理 Fn 时使用本机麦克风", isOn: Binding(
                get: { settings.localFnMicEnabled },
                set: { model.setLocalFnMicEnabled($0) }
            ))
            if settings.localFnMicEnabled {
                Picker("本机输入源", selection: Binding(
                    get: { settings.localMicInputUID },
                    set: { model.setLocalMicInput($0) }
                )) {
                    Text("系统默认输入").tag("")
                    ForEach(model.audioInputDevices) { device in
                        Text(
                            ExternalMicrophoneProfile.isDJIMic2(displayName: device.name)
                                ? "DJI Mic 2（已识别）"
                                : device.name
                        ).tag(device.uid)
                    }
                }
                statusRow("兼容状态", value: model.localMicStatus)
                statusRow("麦克风权限", value: model.microphonePermission.statusText)
                if model.microphonePermission != .authorized {
                    Button("请求麦克风权限") {
                        model.requestMicrophonePermission()
                    }
                }
            }
            DisclosureGroup("工作方式与音频优先级", isExpanded: $localFnHelpExpanded) {
                Text(
                    "新安装默认开启。只有系统已授权、按住 Mac 内置键盘的物理 Fn、且 RC003 未在说话时，" +
                    "才会把本机麦克风转发到上面所选的语音输出（如 BlackHole）。松开 Fn 立即停止；" +
                    "RC003 语音始终优先。不录音、不上传，不修改系统默认音频。"
                )
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    private var applicationCard: some View {
        settingsCard(
            "应用",
            systemImage: "app.badge",
            minHeight: Self.bottomSettingsCardCollapsedMinHeight
        ) {
            Toggle("登录时自动启动", isOn: Binding(
                get: { settings.launchAtLoginEnabled },
                set: { model.setLaunchAtLoginEnabled($0) }
            ))
            statusRow("启动状态", value: launchAtLogin.statusText)
            if launchAtLogin.requiresApproval {
                Button("打开系统登录项设置") {
                    launchAtLogin.openLoginItemsSettings()
                }
            }
            Text("关闭只影响下次登录，不会退出当前应用。")
                .font(.footnote)
                .foregroundColor(.secondary)
            Divider()
            statusRow("当前版本", value: updateController.currentVersionText)
            Toggle("自动检查更新", isOn: Binding(
                get: { updateController.automaticallyChecksForUpdates },
                set: { updateController.setAutomaticallyChecksForUpdates($0) }
            ))
            Button("检查更新…") {
                updateController.checkForUpdates()
            }
            .disabled(!updateController.canCheckForUpdates)
            Text("每天最多检查一次。发现新版本后由你确认安装，不会静默更新，也不发送系统画像或使用数据。")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var djiConnectionSections: some View {
        settingsCard("DJI Mic 2 系统麦克风", systemImage: "mic") {
            statusRow("连接状态", value: model.djiMic2Status)
            if model.djiMic2InputDevices.isEmpty {
                Text("当前没有 CoreAudio 可用的 DJI Mic 2 输入。仅在蓝牙列表中已配对，不等于已经向 macOS 提供麦克风端点。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ForEach(model.djiMic2InputDevices) { device in
                    statusRow("已识别输入", value: device.name)
                }
            }
            HStack {
                Button("刷新设备") { model.reconnect() }
                Button("打开系统声音输入设置") { model.openSoundInputSettings() }
            }
            Text("DJI Mic 2 在此模式下作为 macOS 系统麦克风使用。请在系统声音设置或目标输入法中选择它；本应用不修改默认输入，也不经过 BlackHole。")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var mappingTab: some View {
        if settings.selectedDeviceProfile == .xiaomiRC003 {
            rc003MappingTab
        } else {
            djiControlsTab
        }
    }

    private var rc003MappingTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("启用 \(settings.xiaomiRemoteVariant.shortName) 自定义按键映射", isOn: Binding(
                        get: { settings.customMappingEnabled },
                        set: { enabled in
                            settings.customMappingEnabled = enabled
                            model.applyHIDSettings()
                        }
                    ))
                        statusRow("按键状态", value: model.hidStatus)
                        Text("优先独占 RC003；兼容模式在遥控器设备层屏蔽非语音键的原生输入，再执行配置动作，其他键盘不受影响。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("动作映射")
                                    .font(.headline)
                                Text("点击左侧按键定位；修改后自动保存。")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("恢复默认") {
                                if model.resetButtonBindings() {
                                    selectedRemoteButton = .ok
                                }
                            }
                        }

                        HStack(alignment: .top, spacing: 16) {
                            RemoteControlDiagram(
                                selectedButton: $selectedRemoteButton,
                                voiceActive: model.isStreaming,
                                variant: settings.xiaomiRemoteVariant,
                                diagramWidth: 190,
                                diagramHeight: 385
                            )
                                .frame(width: 190)

                            Divider()

                            ScrollViewReader { proxy in
                                ScrollView {
                                    LazyVStack(spacing: 7) {
                                        ForEach(settings.xiaomiRemoteVariant.mappableButtons) { button in
                                            mappingRow(button)
                                                .id(button.id)
                                        }
                                    }
                                    .padding(.trailing, 4)
                                }
                                .onChange(of: selectedRemoteButton) { button in
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        proxy.scrollTo(button.id, anchor: .center)
                                    }
                                }
                            }
                            .frame(height: 415)
                        }

                        Divider()

                        gestureTimingSection
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .sheet(item: $recordingTarget) { target in
            ShortcutRecorderView(
                button: target.button,
                onCancel: { recordingTarget = nil },
                onClear: {
                    setBinding(
                        target.slot == .single ? .preset(.disabled) : nil,
                        for: target.button,
                        slot: target.slot
                    )
                    recordingTarget = nil
                },
                onRecord: { chord in
                    setBinding(.shortcut(chord), for: target.button, slot: target.slot)
                    recordingTarget = nil
                }
            )
        }
    }

    private var djiControlsTab: some View {
        Form {
            Section(header: Text("DJI Mic 2 实体控制")) {
                djiControlRow("电源键", detail: "由发射器固件处理，不是 macOS 按键")
                djiControlRow("录音键", detail: "控制发射器内部录音，不等同于系统语音快捷键")
                djiControlRow("配对键", detail: "用于设备无线链路配对，不向应用发送动作")
            }
            Section(header: Text("映射状态")) {
                statusRow("可自定义动作", value: "0")
                Text("目前没有捕获到 DJI Mic 2 在 macOS 上输出可靠 HID 按键事件的真机证据，因此不会伪装成 RC003 的 13 键映射。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func djiControlRow(_ title: String, detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("硬件控制")
                .foregroundColor(.secondary)
        }
    }

    private func mappingRow(_ button: RemoteButton) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    selectedRemoteButton = button
                } label: {
                    HStack(spacing: 9) {
                        Text(button.shortLabel)
                            .font(.caption.weight(.semibold))
                            .frame(width: 42, height: 30)
                            .background(
                                selectedRemoteButton == button
                                    ? Color.accentColor
                                    : Color.secondary.opacity(0.14)
                            )
                            .foregroundColor(selectedRemoteButton == button ? .white : .primary)
                            .clipShape(Capsule())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(button.displayName)
                            Text(String(format: "HID 0x%02X", button.hidUsage))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                            if button != .microphone {
                                configuredGestureBadges(for: button)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                bindingMenu(for: button, slot: .single, width: button == .microphone ? 208 : 142)

                if button != .microphone {
                    Button(expandedMultiActionButton == button ? "收起" : "手势…") {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedRemoteButton = button
                            expandedMultiActionButton = expandedMultiActionButton == button ? nil : button
                        }
                    }
                    .frame(width: 62)
                }
            }

            if expandedMultiActionButton == button, button != .microphone {
                Divider().padding(.vertical, 8)
                multiActionEditor(for: button)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            selectedRemoteButton == button
                ? Color.accentColor.opacity(0.09)
                : Color.secondary.opacity(0.055)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                    selectedRemoteButton == button
                        ? Color.accentColor.opacity(0.45)
                        : Color.clear,
                    lineWidth: 1
                )
        )
    }

    @ViewBuilder
    private func configuredGestureBadges(for button: RemoteButton) -> some View {
        let binding = settings.multiActionBinding(for: button)
        if binding.hasAdditionalActions {
            HStack(spacing: 4) {
                if binding.doublePress != nil { gestureBadge("双击") }
                if binding.longPress != nil { gestureBadge("长按") }
            }
        }
    }

    private func gestureBadge(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12))
            .clipShape(Capsule())
    }

    private func multiActionEditor(for button: RemoteButton) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("按键手势")
                .font(.subheadline.weight(.semibold))
            gestureBindingRow(button: button, slot: .single)
            gestureBindingRow(button: button, slot: .doublePress)
            gestureBindingRow(button: button, slot: .longPress)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func gestureBindingRow(button: RemoteButton, slot: ButtonGestureSlot) -> some View {
        HStack(spacing: 10) {
            Text(slot.displayName)
                .font(.callout)
                .frame(width: 42, alignment: .leading)
            Spacer(minLength: 8)
            bindingMenu(for: button, slot: slot, width: 230)
        }
    }

    private func bindingMenu(
        for button: RemoteButton,
        slot: ButtonGestureSlot,
        width: CGFloat
    ) -> some View {
        Menu {
            if slot != .single {
                Button("未设置") { setBinding(nil, for: button, slot: slot) }
                Divider()
            }
            if button == .microphone, slot == .single {
                Button("硬件 Fn（默认语音）") { setBinding(.hardwareFn, for: button, slot: slot) }
                Button("禁用") { setBinding(.preset(.disabled), for: button, slot: slot) }
            } else {
                ForEach(ButtonAction.allCases) { action in
                    if slot == .single || action != .disabled {
                        Button(action.displayName) {
                            setBinding(.preset(action), for: button, slot: slot)
                        }
                    }
                }
            }
            Divider()
            if button != .microphone {
                Button("打开指定应用…") {
                    chooseApplication(for: button, slot: slot)
                }
            }
            Button("录制自定义快捷键…") {
                recordingTarget = ShortcutRecordingTarget(button: button, slot: slot)
            }
        } label: {
            HStack(spacing: 6) {
                Text(settings.binding(for: button, slot: slot)?.displayName ?? "未设置")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(width: width, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .help(settings.binding(for: button, slot: slot)?.displayName ?? "未设置")
    }

    private func chooseApplication(for button: RemoteButton, slot: ButtonGestureSlot) {
        let panel = NSOpenPanel()
        panel.title = "选择要打开的应用"
        panel.prompt = "选择应用"
        panel.allowedFileTypes = ["app"]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        if case let .openApplication(target) = settings.binding(for: button, slot: slot) {
            panel.directoryURL = URL(fileURLWithPath: target.path).deletingLastPathComponent()
        } else {
            panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let target = ApplicationTarget.application(at: url) else {
                let alert = NSAlert()
                alert.messageText = "无法选择此应用"
                alert.informativeText = "请选择有效的 .app 应用程序。"
                alert.runModal()
                return
            }
            setBinding(.openApplication(target), for: button, slot: slot)
        }
    }

    private func setBinding(
        _ binding: ButtonBinding?,
        for button: RemoteButton,
        slot: ButtonGestureSlot = .single
    ) {
        if button == .microphone, slot == .single, let binding {
            _ = model.setVoiceKeyBinding(binding)
        } else {
            settings.setBinding(binding, for: button, slot: slot)
        }
    }

    private var gestureTimingSection: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("手势判定")
                .font(.headline)

            Spacer(minLength: 12)

            compactTimingInput(
                title: "双击间隔",
                text: $doubleClickTimingText,
                range: MultiActionTiming.minimumDoubleClickMs...MultiActionTiming.maximumDoubleClickMs,
                currentValue: { settings.multiActionDoubleClickMs }
            )

            Divider().frame(height: 28)

            compactTimingInput(
                title: "长按时长",
                text: $longPressTimingText,
                range: MultiActionTiming.minimumLongPressMs...MultiActionTiming.maximumLongPressMs,
                currentValue: { settings.multiActionLongPressMs }
            )

            Button(timingHasChanges ? "保存" : "已保存", action: saveGestureTiming)
                .disabled(!timingHasChanges)
                .frame(width: 58)

            Button("恢复默认") {
                settings.resetMultiActionTiming()
                doubleClickTimingText = String(settings.multiActionDoubleClickMs)
                longPressTimingText = String(settings.multiActionLongPressMs)
            }
        }
        .onChange(of: settings.multiActionDoubleClickMs) { value in
            doubleClickTimingText = String(value)
        }
        .onChange(of: settings.multiActionLongPressMs) { value in
            longPressTimingText = String(value)
        }
    }

    private var timingHasChanges: Bool {
        doubleClickTimingText != String(settings.multiActionDoubleClickMs) ||
            longPressTimingText != String(settings.multiActionLongPressMs)
    }

    private func saveGestureTiming() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        let doubleClick = MultiActionTimingInput.committedValue(
            from: doubleClickTimingText, fallback: settings.multiActionDoubleClickMs,
            range: MultiActionTiming.minimumDoubleClickMs...MultiActionTiming.maximumDoubleClickMs
        )
        let longPress = MultiActionTimingInput.committedValue(
            from: longPressTimingText, fallback: settings.multiActionLongPressMs,
            range: MultiActionTiming.minimumLongPressMs...MultiActionTiming.maximumLongPressMs
        )
        let accepted = settings.setMultiActionTiming(
            doubleClickMs: doubleClick, longPressMs: longPress
        )
        doubleClickTimingText = String(accepted.doubleClickMs)
        longPressTimingText = String(accepted.longPressMs)
    }

    private func compactTimingInput(
        title: String,
        text: Binding<String>,
        range: ClosedRange<Int>,
        currentValue: @escaping () -> Int
    ) -> some View {
        return HStack(spacing: 6) {
            Text(title)
                .font(.callout)
            GestureTimingTextField(
                title: title, text: text, range: range,
                currentValue: currentValue, onSubmit: saveGestureTiming
            )
            .frame(width: 64, height: 25)
            Text("ms")
                .foregroundColor(.secondary)
        }
    }

    private var permissionsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if settings.selectedDeviceProfile == .xiaomiRC003 {
                    settingsCard("RC003 权限状态", systemImage: "lock.shield") {
                        Text("按键映射需要输入监控和辅助功能；Mac Fn 默认开启，但只在按住物理 Fn 时采集并需要麦克风权限。")
                            .font(.footnote)
                            .foregroundColor(.secondary)

                        permissionStatusRow(
                            title: "蓝牙",
                            detail: "连接 RC003 并读取 ATVV 语音服务",
                            status: rc003Connected ? "连接正常" : "需要检查",
                            systemImage: "antenna.radiowaves.left.and.right",
                            tint: rc003Connected ? .green : .orange,
                            actionTitle: "打开设置"
                        ) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        permissionStatusRow(
                            title: "输入监控",
                            detail: "读取 RC003 原始 HID 报告，并抑制重复系统事件",
                            status: HIDRemoteMonitor.isInputMonitoringGranted ? "已授权" : "未授权",
                            systemImage: "keyboard",
                            tint: HIDRemoteMonitor.isInputMonitoringGranted ? .green : .orange,
                            actionTitle: HIDRemoteMonitor.isInputMonitoringGranted ? "查看" : "去授权"
                        ) { model.requestInputMonitoringPermission() }
                        permissionStatusRow(
                            title: "辅助功能",
                            detail: "把映射后的按键动作发送给当前应用",
                            status: KeyboardInjector.isAccessibilityTrusted ? "已授权" : "未授权",
                            systemImage: "hand.raised",
                            tint: KeyboardInjector.isAccessibilityTrusted ? .green : .orange,
                            actionTitle: KeyboardInjector.isAccessibilityTrusted ? "查看" : "去授权"
                        ) { model.requestAccessibilityPermission() }
                        permissionStatusRow(
                            title: "麦克风（Mac Fn）",
                            detail: "仅在开启 Mac Fn 兼容并按住物理 Fn 时采集",
                            status: model.microphonePermission.statusText(
                                featureEnabled: settings.localFnMicEnabled
                            ),
                            systemImage: "mic",
                            tint: settings.localFnMicEnabled && model.microphonePermission == .authorized
                                ? .green
                                : .secondary,
                            actionTitle: !settings.localFnMicEnabled
                                ? "启用"
                                : (model.microphonePermission == .authorized ? "查看" : "请求权限")
                        ) {
                            if settings.localFnMicEnabled {
                                model.requestMicrophonePermission()
                            } else {
                                model.setLocalFnMicEnabled(true)
                            }
                        }
                    }
                } else {
                    settingsCard("DJI Mic 2 权限", systemImage: "mic") {
                        permissionStatusRow(
                            title: "系统麦克风",
                            detail: "DJI Mic 2 由 macOS 和实际录音应用管理，本应用不代为录音",
                            status: model.djiMic2InputDevices.isEmpty ? "未发现输入" : "已发现输入",
                            systemImage: "waveform",
                            tint: model.djiMic2InputDevices.isEmpty ? .secondary : .green,
                            actionTitle: "打开声音设置"
                        ) { model.openSoundInputSettings() }
                        Text("此模式不需要本应用的蓝牙、输入监控或辅助功能权限。真正录音的输入法或应用需要自己的麦克风权限。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                settingsCard("隐私与诊断", systemImage: "doc.text.magnifyingglass") {
                    HStack(alignment: .center, spacing: 12) {
                        Text("日志只记录连接、状态和失败类别，不记录语音内容、蓝牙地址或外设 UUID。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("在 Finder 中显示日志") { model.openLogFolder() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
        .onAppear { model.refreshMicrophonePermission() }
    }

    private var supportedDevicesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                settingsCard("支持的设备", systemImage: "square.grid.2x2") {
                    HStack(alignment: .firstTextBaseline) {
                        Text("当前内置 \(model.deviceProfileCatalog.profiles.count) 个设备模块")
                            .font(.body.weight(.medium))
                        Spacer()
                        Text("当前设备可在顶部手动切换")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text("目录展示已适配和计划支持的设备；模块存在不等于当前平台已实现，也不代表设备已连接。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                if let error = model.deviceProfileCatalog.errorMessage {
                    settingsCard("设备目录不可用", systemImage: "exclamationmark.triangle") {
                        Text(error)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ForEach(model.deviceProfileCatalog.profiles) { profile in
                        supportedDeviceCard(profile)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
    }

    private func supportedDeviceCard(_ profile: DeviceProfileDescriptor) -> some View {
        settingsCard(profile.displayName, systemImage: deviceProfileSymbol(profile)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(profile.vendor) · \(profile.model) · \(profile.id)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(profile.support.status.displayName)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .foregroundColor(deviceProfileTint(profile))
                        .background(deviceProfileTint(profile).opacity(0.12))
                        .clipShape(Capsule())
                }

                Text(profile.support.notes)
                    .font(.footnote)
                    .foregroundColor(.secondary)

                Divider()
                catalogSectionTitle("平台状态")
                ForEach(profile.platforms) { platform in
                    HStack(alignment: .top) {
                        Text(platform.platform.displayName)
                            .frame(width: 76, alignment: .leading)
                        Text(platform.status.displayName)
                            .frame(width: 64, alignment: .leading)
                            .foregroundColor(.secondary)
                        Text(platform.notes)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                catalogSectionTitle("连接与传输")
                ForEach(Array(profile.transports.enumerated()), id: \.offset) { _, transport in
                    HStack(alignment: .top) {
                        Text(transport.kind.displayName)
                            .frame(width: 128, alignment: .leading)
                        Text(transport.status.displayName)
                            .frame(width: 64, alignment: .leading)
                            .foregroundColor(.secondary)
                        Text(transport.notes)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                catalogSectionTitle("设备能力")
                Text(profile.capabilities.map(\.displayName).joined(separator: " · "))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func catalogSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
    }

    private var rc003Connected: Bool {
        model.connectionStatus.contains("已连接")
    }

    private var compactConnectionStatus: String {
        if rc003Connected { return "已连接" }
        if model.connectionStatus.contains("连接中") || model.connectionStatus.contains("正在") {
            return "连接中"
        }
        return "未连接"
    }

    private var hidIsReady: Bool {
        let status = model.hidStatus
        let hasReadySignal = status.contains("监听") || status.contains("读取中") || status.contains("已连接")
        return hasReadySignal && !status.contains("未读取") && !status.contains("需要")
    }

    private var compactHIDStatus: String {
        hidIsReady ? "监听中" : "未就绪"
    }

    private var activeDeviceTint: Color {
        switch settings.selectedDeviceProfile {
        case .xiaomiRC003:
            return rc003Connected ? .green : .orange
        case .djiMic2:
            return model.djiMic2InputDevices.isEmpty ? .secondary : .green
        }
    }

    private var activeDeviceDisplayName: String {
        switch settings.selectedDeviceProfile {
        case .xiaomiRC003:
            guard rc003Connected else { return "小米蓝牙语音遥控器" }
            if rc003Connected, model.detectedXiaomiModelNumber == nil {
                return "小米蓝牙语音遥控器（识别型号中）"
            }
            return settings.xiaomiRemoteVariant.displayName
        case .djiMic2:
            return settings.selectedDeviceProfile.displayName
        }
    }

    private var activeWorkspaceSelection: DeviceWorkspaceSelection {
        switch settings.selectedDeviceProfile {
        case .djiMic2:
            return .djiMic2
        case .xiaomiRC003:
            return settings.xiaomiRemoteVariant == .arn9 ? .xiaomiARN9 : .xiaomiRC003Pro
        }
    }

    private var availableWorkspaceSelections: [DeviceWorkspaceSelection] {
        var selections: [DeviceWorkspaceSelection] = []
        if rc003Connected || settings.selectedDeviceProfile == .xiaomiRC003 {
            selections.append(
                settings.xiaomiRemoteVariant == .arn9 ? .xiaomiARN9 : .xiaomiRC003Pro
            )
        }
        if !model.djiMic2InputDevices.isEmpty || settings.selectedDeviceProfile == .djiMic2 {
            selections.append(.djiMic2)
        }
        return selections.isEmpty ? [activeWorkspaceSelection] : selections
    }

    private func selectWorkspace(_ selection: DeviceWorkspaceSelection) {
        switch selection {
        case .xiaomiRC003Pro:
            settings.xiaomiRemoteVariant = .rc003Pro
            model.selectDeviceProfile(.xiaomiRC003)
        case .xiaomiARN9:
            settings.xiaomiRemoteVariant = .arn9
            if selectedRemoteButton == .tv { selectedRemoteButton = .ok }
            model.selectDeviceProfile(.xiaomiRC003)
        case .djiMic2:
            model.selectDeviceProfile(.djiMic2)
        }
    }

    private var activeDeviceSummary: String {
        switch settings.selectedDeviceProfile {
        case .xiaomiRC003:
            return compactConnectionStatus
        case .djiMic2:
            return model.djiMic2InputDevices.isEmpty ? "未发现音频输入" : "已发现音频输入"
        }
    }

    private var connectionOverviewActions: some View {
        VStack(alignment: .trailing, spacing: 7) {
            statusPill(
                rc003Connected ? "已连接" : compactConnectionStatus,
                tint: rc003Connected ? .green : .orange,
                help: model.connectionStatus
            )
            Button("立即重新连接") { model.reconnect() }
                .buttonStyle(AccentActionButtonStyle())
        }
    }

    private var bridgeHeaderActions: some View {
        VStack(alignment: .trailing, spacing: 7) {
            statusPill(
                model.bridgeEnabled ? "桥接已启用" : "桥接已停用",
                tint: model.bridgeEnabled ? .green : .secondary,
                help: model.bridgeRuntimeStatus
            )
            Button(model.bridgeEnabled ? "停用桥接" : "启用桥接") {
                model.toggleBridgeEnabled(source: "settings")
            }
        }
    }

    private var bridgeHelpPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("双击规则与降级说明", systemImage: "info.circle.fill")
                .font(.headline)
            Text(model.bridgeRuntimeStatus)
                .font(.callout.weight(.medium))
            Text(
                "快速双击遥控器语音键（两次完整短按，默认 350ms 内、每次不超过 250ms）" +
                "可在“桥接已启用/已停用”之间切换一次。停用后 RC003 不再向 Mac 注入普通按键、" +
                "Fn/🌐︎、语音或音频；再次双击或点击桥接按钮即可恢复。长按语音不受影响，也不会增加等待延迟。"
            )
                .font(.footnote)
                .foregroundColor(.secondary)
            Text(
                "运行时状态不会保存，退出并重开应用会恢复为已启用。若关闭自定义按键映射，" +
                "或系统不允许独占读取，停用时普通按键仍可能走 macOS 原生行为。"
            )
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
    }

    private func statusPill(_ text: String, tint: Color, help: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .foregroundColor(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tint.opacity(0.11))
        .clipShape(Capsule())
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(text)。\(help)"))
    }

    private func settingsCard<Content: View>(
        _ title: String,
        systemImage: String,
        minHeight: CGFloat? = nil,
        headerAccessory: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.13))
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
                .frame(width: 28, height: 28)

                Text(title)
                    .font(.headline.weight(.semibold))
                Spacer()
                if let headerAccessory {
                    headerAccessory
                }
            }

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.075), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusMetric(
        title: String,
        value: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.14))
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(tint)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    private func audioStatusMetric(
        title: String,
        value: String,
        systemImage: String,
        tint: Color,
        level: Double
    ) -> some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.14))
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(tint)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    Text(value)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                ProgressView(value: level)
                    .progressViewStyle(.linear)
                    .accentColor(tint)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    private func permissionStatusRow(
        title: String,
        detail: String,
        status: String,
        systemImage: String,
        tint: Color,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.13))
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(tint)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.callout.weight(.medium))
                    Text(status)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(tint)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(actionTitle, action: action)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    private func deviceProfileSymbol(_ profile: DeviceProfileDescriptor) -> String {
        profile.id.contains("xiaomi") || profile.id.contains("rc003")
            ? "dot.radiowaves.left.and.right"
            : "mic.fill"
    }

    private func deviceProfileTint(_ profile: DeviceProfileDescriptor) -> Color {
        switch profile.support.status {
        case .implemented: return .green
        case .research: return .orange
        case .planned: return .accentColor
        case .unsupported: return .secondary
        }
    }

    private func statusRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func audioSignalRow(
        title: String,
        detail: String,
        level: AudioLevelSnapshot,
        status: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(status)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(level.isRecent ? .secondary : .secondary.opacity(0.7))
            }
            ProgressView(value: level.meterValue)
                .progressViewStyle(.linear)
                .accentColor(level.isRecent ? .accentColor : .secondary)
            Text(detail)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct AccentActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.72 : 1.0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct RemoteControlDiagram: View {
    @Binding var selectedButton: RemoteButton
    let voiceActive: Bool
    let variant: XiaomiRemoteVariant
    let diagramWidth: CGFloat
    let diagramHeight: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack {
                    if let photo = RemoteImageCatalog.image(for: variant) {
                        Image(nsImage: photo)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.secondary.opacity(0.10))
                        Text("实物图资源缺失")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if variant == .arn9 {
                        arn9Hotspots
                    } else {
                        rc003Hotspots
                    }
                }
            }
            .frame(width: diagramWidth, height: diagramHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
            )

            Text("点击实物按键定位映射；包括语音键在内均可自定义快捷键。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var rc003Hotspots: some View {
        hotspot(.power, x: 0.386, y: 0.099, width: 0.15, height: 0.072)
        voiceHotspot(x: 0.630, y: 0.099, width: 0.15, height: 0.072)
        hotspot(.up, x: 0.502, y: 0.179, width: 0.18, height: 0.065)
        hotspot(.left, x: 0.362, y: 0.246, width: 0.15, height: 0.080)
        hotspot(.ok, x: 0.502, y: 0.246, width: 0.19, height: 0.095)
        hotspot(.right, x: 0.638, y: 0.246, width: 0.15, height: 0.080)
        hotspot(.down, x: 0.502, y: 0.317, width: 0.18, height: 0.065)
        hotspot(.back, x: 0.406, y: 0.389, width: 0.17, height: 0.080)
        hotspot(.volumeUp, x: 0.604, y: 0.390, width: 0.16, height: 0.080)
        hotspot(.home, x: 0.406, y: 0.479, width: 0.17, height: 0.080)
        hotspot(.volumeDown, x: 0.604, y: 0.480, width: 0.16, height: 0.080)
        hotspot(.menu, x: 0.406, y: 0.569, width: 0.17, height: 0.080)
        hotspot(.tv, x: 0.604, y: 0.569, width: 0.17, height: 0.080)
    }

    @ViewBuilder
    private var arn9Hotspots: some View {
        hotspot(.power, x: 0.511, y: 0.087, width: 0.11, height: 0.055)
        voiceHotspot(x: 0.509, y: 0.153, width: 0.11, height: 0.055)
        hotspot(.up, x: 0.510, y: 0.235, width: 0.24, height: 0.070)
        hotspot(.left, x: 0.345, y: 0.304, width: 0.15, height: 0.090)
        hotspot(.ok, x: 0.509, y: 0.302, width: 0.17, height: 0.085)
        hotspot(.right, x: 0.675, y: 0.304, width: 0.15, height: 0.090)
        hotspot(.down, x: 0.510, y: 0.366, width: 0.24, height: 0.070)
        hotspot(.home, x: 0.367, y: 0.450, width: 0.12, height: 0.060)
        hotspot(.back, x: 0.510, y: 0.450, width: 0.12, height: 0.060)
        hotspot(.menu, x: 0.656, y: 0.450, width: 0.12, height: 0.060)
        hotspot(.volumeUp, x: 0.510, y: 0.531, width: 0.11, height: 0.055)
        hotspot(.volumeDown, x: 0.510, y: 0.603, width: 0.11, height: 0.055)
    }

    private func hotspot(
        _ button: RemoteButton,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        Button {
            selectedButton = button
        } label: {
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(
                    selectedButton == button
                        ? Color.accentColor.opacity(0.27)
                        : Color.clear
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .stroke(
                            selectedButton == button ? Color.accentColor : Color.clear,
                            lineWidth: 2
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 999, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(width: diagramWidth * width, height: diagramHeight * height)
        .position(x: diagramWidth * x, y: diagramHeight * y)
        .help(button.displayName)
        .accessibilityLabel(Text(button.displayName))
    }

    private func voiceHotspot(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        Button { selectedButton = .microphone } label: {
            Circle()
                .fill(
                    voiceActive
                        ? Color.orange.opacity(0.30)
                        : selectedButton == .microphone ? Color.accentColor.opacity(0.27) : Color.clear
                )
                .overlay(
                    Circle().stroke(
                        voiceActive ? Color.orange : selectedButton == .microphone ? Color.accentColor : Color.clear,
                        lineWidth: 2
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: diagramWidth * width, height: diagramHeight * height)
        .position(x: diagramWidth * x, y: diagramHeight * y)
        .help("语音键：默认硬件 Fn，也可录制自定义快捷键")
        .accessibilityLabel(Text("语音键"))
    }
}
