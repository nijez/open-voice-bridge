# XRBM-042 Design QA

- source visual truth: `/Users/kingwell/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/kingwell_edf2/temp/RWTemp/2026-07/994baa69ff45fb1482c13c47e54419d1/b817792a5c63b49c9ccb3475afeaf0d1.png`
- implementation screenshot: `docs/design/xrbm-042/implementation-build10.png`
- comparison image: `docs/design/xrbm-042/reference-vs-build10.png`
- viewport/state: macOS 设置窗口，800×684 CSS pt，Retina 2×；RC003 已连接、桥接已启用、语音等待按键
- source pixels: 1333×1509；比较时裁掉查看器顶部 209 px，取 1333×1140 并缩放到 1600×1368
- implementation pixels: 1600×1368，对应 800×684 CSS pt、2× density

## Full-view comparison

并排证据确认顶部设备卡、RC003 / DJI Mic 2 选择、连接状态块、桥接状态与操作、语音输出卡的顺序、比例和视觉层级与标注目标一致。删除的重复说明不再占用纵向空间；两个红框建议位置均由紧凑绿色状态 pill 实现。

## Focused-region comparison

连接与桥接两个标注区域在 3200×1368 并排图中足够清晰，不需要额外放大图。信息按钮可见、可点击，并有 hover 帮助及 VoiceOver 标签；完整降级说明保留在 popover 中。

## Required fidelity surfaces

- Fonts and typography: 继续使用 macOS 系统字体、原生字重和既有层级；标题、状态和操作无异常换行。
- Spacing and layout rhythm: 卡片 padding、圆角和区块间距保持现有设计系统；状态与按钮形成右上纵向操作组，没有新增测量反馈。
- Colors and visual tokens: 沿用 accentColor、绿色成功态、灰色次级文案；状态不只依赖颜色，同时保留文字。
- Image quality and asset fidelity: 继续使用原始 RC003 实物图资源，比例与裁切未改变。
- Copy and content: 删除重复在线说明；连接/桥接状态、按钮语义和双击降级说明完整保留。

## Findings

没有可执行的 P0、P1 或 P2 差异。参考图中的红框、箭头和删除线属于设计批注，不应进入产品界面。

## Comparison history

- pass 1: build 10 与参考标注并排检查，无 P0/P1/P2；未因 QA 修改代码。

## Final result

final result: passed
