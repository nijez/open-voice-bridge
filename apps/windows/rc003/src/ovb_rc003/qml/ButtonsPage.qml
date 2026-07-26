// "按键" tab (XRBM-030 In-scope items 4/5): the RC003 product photo with 13
// clickable hotspots (macOS-verified coordinates, see remote_layout.py) on
// the left, the mapping list (Chinese name / HID usage / current action) on
// the right. Both sides are two views over the SAME ButtonMappingModel row,
// kept in sync through SettingsController.selectButton()/
// SettingsController.selectedButtonId - clicking either one updates both
// (In-scope item 4's "双向定位"). SettingsController/ButtonMappingModel are
// QML singletons - see main.qml's module docstring for why.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import OvbRc003Settings 1.0

Item {
    id: root
    property var tokens

    readonly property real photoAspectRatio: 1030 / 508

    RowLayout {
        id: rc003MappingLayout
        objectName: "rc003MappingLayout"
        visible: SettingsController.isRc003Device
        anchors.fill: parent
        anchors.margins: tokens.spacingLarge
        spacing: tokens.spacingLarge

        // -- Left: product photo with hotspots -----------------------------
        ColumnLayout {
            Layout.preferredWidth: 250
            Layout.fillHeight: true
            spacing: tokens.spacingSmall

            Rectangle {
                id: photoFrame
                Layout.preferredWidth: 230
                Layout.preferredHeight: 230 * root.photoAspectRatio
                Layout.alignment: Qt.AlignHCenter | Qt.AlignTop
                radius: tokens.cornerRadiusLarge
                color: tokens.surface
                border.color: tokens.border
                border.width: 1
                clip: true

                Image {
                    id: photoImage
                    objectName: "photoImage"  // stable hook so a real-QML test can read paintedWidth/paintedHeight and the letterbox offset to verify hotspot centers
                    anchors.fill: parent
                    anchors.margins: 8
                    fillMode: Image.PreserveAspectFit
                    source: SettingsController.photoAvailable ? SettingsController.photoSource : ""
                    visible: SettingsController.photoAvailable
                    smooth: true
                    asynchronous: true
                }

                Label {
                    anchors.centerIn: parent
                    anchors.margins: tokens.spacingMedium
                    width: parent.width - tokens.spacingMedium * 2
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    visible: !SettingsController.photoAvailable
                    text: qsTr("实物图资源缺失")
                    color: tokens.textSecondary
                    font.pixelSize: tokens.fontSizeSmall
                }

                Repeater {
                    model: ButtonMappingModel

                    delegate: Item {
                        id: hotspot

                        // Stable, device-identifier-free hook so a real-QML
                        // test can locate any one hotspot Item by button (see
                        // tests/test_qt_settings_app.py). buttonId is an
                        // internal action id ("ok", "power", ...), never a
                        // hardware/BLE identifier.
                        objectName: "photoHotspot_" + buttonId

                        required property string buttonId
                        required property string displayName
                        required property real hotspotX
                        required property real hotspotY
                        required property real hotspotWidth
                        required property real hotspotHeight
                        required property bool isSelected
                        required property bool isVoice

                        readonly property real paintedW: photoImage.paintedWidth
                        readonly property real paintedH: photoImage.paintedHeight
                        readonly property real offsetX: photoImage.x + (photoImage.width - paintedW) / 2
                        readonly property real offsetY: photoImage.y + (photoImage.height - paintedH) / 2

                        // hotspotX/hotspotY are the hotspot's CENTER as a
                        // fraction of the painted photo, copied byte-for-byte
                        // from the macOS-verified coordinates
                        // (remote_layout.py). SwiftUI's RemoteControlDiagram
                        // places each hotspot with `.position(x:y:)`, which
                        // centers the view on that point, AFTER giving it its
                        // width/height (SettingsView.swift hotspot()/
                        // voiceHotspot()). A QML Item's x/y are its TOP-LEFT,
                        // so we convert center -> top-left by subtracting half
                        // the item's own width/height, keeping the
                        // PreserveAspectFit letterbox offset. Without this the
                        // whole highlight/click region drifts down-right by
                        // half a hotspot (XRBM-032).
                        width: hotspotWidth * paintedW
                        height: hotspotHeight * paintedH
                        x: offsetX + hotspotX * paintedW - width / 2
                        y: offsetY + hotspotY * paintedH - height / 2
                        visible: SettingsController.photoAvailable

                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button
                        Accessible.name: displayName

                        Rectangle {
                            anchors.fill: parent
                            radius: height / 2
                            color: hotspot.isSelected
                                ? Qt.rgba(tokens.accent.r, tokens.accent.g, tokens.accent.b, 0.28)
                                : (hoverHandler.hovered
                                    ? Qt.rgba(tokens.accent.r, tokens.accent.g, tokens.accent.b, 0.14)
                                    : "transparent")
                            border.width: hotspot.isSelected ? 2 : (hotspot.activeFocus ? 1 : 0)
                            border.color: hotspot.isVoice ? tokens.voiceAccent : tokens.accent
                        }

                        HoverHandler { id: hoverHandler }
                        TapHandler { onTapped: SettingsController.selectButton(hotspot.buttonId) }
                        Keys.onReturnPressed: SettingsController.selectButton(hotspot.buttonId)
                        Keys.onSpacePressed: SettingsController.selectButton(hotspot.buttonId)
                    }
                }
            }

            Label {
                Layout.preferredWidth: 230
                Layout.alignment: Qt.AlignHCenter
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                text: qsTr("点击实物按键定位映射；麦克风键固定为语音，遥控器没有独立的实体静音键。")
                color: tokens.textSecondary
                font.pixelSize: tokens.fontSizeSmall
            }
        }

        // -- Right: mapping list --------------------------------------------
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: tokens.spacingSmall

            RowLayout {
                Layout.fillWidth: true
                Label {
                    Layout.fillWidth: true
                    text: qsTr("按键映射")
                    font.pixelSize: tokens.fontSizeTitle
                    font.bold: true
                    color: tokens.textPrimary
                }
                Button {
                    text: qsTr("恢复默认")
                    onClicked: SettingsController.restoreDefaults()
                }
                Button {
                    // XRBM-030 RETRY 1 blocker 4: without this button, a
                    // mapping edit made on this page could only actually be
                    // persisted by switching to "连接" and clicking "保存并
                    // 应用" - a user who edits a mapping and just closes the
                    // window loses it. Calls the exact same
                    // SettingsController.saveSettings() slot the "连接" page
                    // uses (same validation, same config.save_*() calls) -
                    // no separate/duplicated save path.
                    id: saveMappingButton
                    objectName: "saveMappingButton"
                    text: qsTr("保存映射")
                    highlighted: true
                    onClicked: SettingsController.saveSettings()
                }
            }

            // -- Status / error feedback (mirrors ConnectionPage.qml) --------
            // "恢复默认" alone never persists anything - restoreDefaults()
            // sets a status message saying so explicitly (see
            // SettingsController.restoreDefaults()), so this page can never
            // look "silently saved" when it is only showing an in-memory
            // reset.
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                visible: text.length > 0
                text: SettingsController.errorMessage
                color: tokens.errorColor
                font.pixelSize: tokens.fontSizeSmall
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                visible: text.length > 0 && SettingsController.errorMessage.length === 0
                text: SettingsController.statusMessage
                color: tokens.successColor
                font.pixelSize: tokens.fontSizeSmall
            }

            ListView {
                id: mappingList
                objectName: "mappingList"  // lets a test force a specific row into view via positionViewAtIndex()
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: ButtonMappingModel
                spacing: tokens.spacingTiny
                currentIndex: ButtonMappingModel.indexOfButton(SettingsController.selectedButtonId)
                highlightFollowsCurrentItem: true
                onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

                delegate: Rectangle {
                    id: mappingRow

                    required property int index
                    required property string buttonId
                    required property string displayName
                    required property string hidUsage
                    required property string actionText
                    required property bool isMic
                    required property bool isSelected

                    width: mappingList.width
                    height: rowContent.implicitHeight + tokens.spacingMedium * 2
                    radius: tokens.cornerRadiusSmall
                    color: isSelected
                        ? Qt.rgba(tokens.accent.r, tokens.accent.g, tokens.accent.b, 0.12)
                        : "transparent"
                    border.width: isSelected ? 1 : 0
                    border.color: tokens.accent

                    // Editable QQC2 ComboBox's own internal currentIndex/
                    // editText sync (triggered during its construction, and
                    // again on every user selection) overwrites a plain
                    // declarative `editText: mappingRow.actionText` binding
                    // the moment the component finishes initializing - a
                    // well-known ComboBox(editable:true) pitfall. Setting it
                    // imperatively once after completion, then re-syncing it
                    // explicitly whenever the underlying row data changes
                    // (e.g. "恢复默认"), keeps the visible text correct
                    // without fighting ComboBox's own internal writes.
                    onActionTextChanged: actionCombo.editText = actionText

                    TapHandler {
                        onTapped: SettingsController.selectButton(mappingRow.buttonId)
                    }

                    RowLayout {
                        id: rowContent
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: tokens.spacingMedium
                        spacing: tokens.spacingMedium

                        ColumnLayout {
                            Layout.preferredWidth: 120
                            spacing: 0
                            Label {
                                text: mappingRow.displayName
                                color: tokens.textPrimary
                                font.pixelSize: tokens.fontSizeBody
                            }
                            Label {
                                text: mappingRow.hidUsage
                                color: tokens.textSecondary
                                font.pixelSize: tokens.fontSizeSmall
                            }
                        }

                        ColumnLayout {
                            visible: mappingRow.isMic
                            Layout.fillWidth: true
                            spacing: 2
                            TextField {
                                id: voiceHotkeyField
                                Layout.fillWidth: true
                                text: SettingsController.hotkeyText
                                placeholderText: qsTr("例如 ctrl+shift+u 或 win+h")
                                selectByMouse: true
                                onEditingFinished: SettingsController.hotkeyText = text
                                Accessible.name: qsTr("语音键组合键")
                            }
                            Label {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: qsTr("需与 Windows 或输入法的语音快捷键保持一致；系统语音键入通常为 Win+H。")
                                color: tokens.textSecondary
                                font.pixelSize: tokens.fontSizeSmall
                            }
                        }

                        ComboBox {
                            id: actionCombo
                            // Per-row name (not a fixed literal) so a test
                            // can locate one specific row's ComboBox, e.g.
                            // findChild(QObject, "actionCombo_power") - a
                            // real, stable hook, not a fake production
                            // behavior.
                            objectName: "actionCombo_" + mappingRow.buttonId
                            visible: !mappingRow.isMic
                            Layout.fillWidth: true
                            editable: true
                            model: SettingsController.presetActionOptions
                            Accessible.name: mappingRow.displayName

                            // Guards onEditTextChanged below against the
                            // SAME construction-time noise
                            // Component.onCompleted works around (ComboBox's
                            // own internal currentIndex-driven editText sync
                            // fires during construction, before this flag is
                            // set true) - without it, every row would
                            // immediately persist its transient default
                            // ("escape", index 0 of presetActionOptions)
                            // into the model the instant it's created,
                            // reintroducing the "all rows show/save escape"
                            // bug this task's own screenshot step caught
                            // earlier.
                            property bool _initialized: false

                            // NOT `editText: mappingRow.actionText` (a
                            // plain declarative binding) - ComboBox's own
                            // internal currentIndex/editText sync overwrites
                            // that the moment construction finishes (a
                            // well-known ComboBox(editable:true) pitfall).
                            // Set imperatively here instead, strictly AFTER
                            // that internal sync has already run.
                            Component.onCompleted: {
                                editText = mappingRow.actionText
                                _initialized = true
                            }

                            // XRBM-030 RETRY 1 blocker 1: onAccepted (Enter)
                            // and onActivated (picking a dropdown item)
                            // alone are not enough - a user who types a
                            // custom chord (e.g. "ctrl+shift+p") and clicks
                            // a SAVE button without ever pressing Enter
                            // previously left the model (and therefore
                            // _save()'s persisted binding) holding the OLD
                            // value, silently discarding the typed edit.
                            // Committing on every live editText change closes
                            // that gap unconditionally - by the time any
                            // save action runs, the model already holds
                            // whatever is visibly displayed, with no
                            // separate "commit on blur/save" event to miss.
                            // Guarded by _initialized (see above) so this
                            // never fires from ComboBox's own construction-
                            // time internal writes, only from a real,
                            // post-construction edit (by typing or by
                            // restoreDefaults()/onActionTextChanged
                            // resetting editText, which harmlessly re-writes
                            // the model with the exact same value it already
                            // has).
                            onEditTextChanged: {
                                if (_initialized) {
                                    ButtonMappingModel.setActionTextAt(mappingRow.index, editText)
                                }
                            }

                            // Kept for defense-in-depth / clarity of intent
                            // even though onEditTextChanged above already
                            // covers both cases (accepting Enter, or picking
                            // a dropdown item, both change editText too).
                            onAccepted: ButtonMappingModel.setActionTextAt(mappingRow.index, editText)
                            onActivated: ButtonMappingModel.setActionTextAt(mappingRow.index, currentText)
                        }
                    }
                }
            }
        }
    }

    RowLayout {
        id: djiControlLayout
        objectName: "djiControlLayout"
        visible: SettingsController.isDjiMic2Device
        anchors.fill: parent
        anchors.margins: tokens.spacingLarge
        spacing: tokens.spacingLarge

        ColumnLayout {
            Layout.preferredWidth: 250
            Layout.fillHeight: true
            spacing: tokens.spacingSmall

            Rectangle {
                Layout.preferredWidth: 210
                Layout.preferredHeight: 360
                Layout.alignment: Qt.AlignHCenter | Qt.AlignTop
                radius: tokens.cornerRadiusLarge
                color: tokens.surface
                border.color: tokens.border
                border.width: 1

                Rectangle {
                    id: transmitter
                    width: 112
                    height: 250
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    anchors.topMargin: 32
                    radius: tokens.cornerRadiusLarge
                    color: tokens.fieldBackground
                    border.color: tokens.border
                    border.width: 1

                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        anchors.topMargin: 22
                        text: qsTr("DJI MIC 2")
                        font.bold: true
                        color: tokens.textPrimary
                    }

                    Rectangle {
                        width: 36
                        height: 36
                        radius: 18
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        anchors.topMargin: 72
                        color: tokens.surface
                        border.color: tokens.voiceAccent
                        border.width: 2
                        Label {
                            anchors.centerIn: parent
                            text: qsTr("录")
                            color: tokens.textPrimary
                            font.bold: true
                        }
                    }

                    Rectangle {
                        width: 64
                        height: 32
                        radius: tokens.cornerRadiusSmall
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        anchors.topMargin: 132
                        color: tokens.surface
                        border.color: tokens.border
                        Label {
                            anchors.centerIn: parent
                            text: qsTr("连接")
                            color: tokens.textPrimary
                        }
                    }

                    Rectangle {
                        width: 64
                        height: 32
                        radius: tokens.cornerRadiusSmall
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        anchors.topMargin: 184
                        color: tokens.surface
                        border.color: tokens.border
                        Label {
                            anchors.centerIn: parent
                            text: qsTr("电源")
                            color: tokens.textPrimary
                        }
                    }
                }

                Label {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 22
                    text: qsTr("功能示意，非产品照片")
                    color: tokens.textSecondary
                    font.pixelSize: tokens.fontSizeSmall
                }
            }

            Label {
                Layout.preferredWidth: 230
                Layout.alignment: Qt.AlignHCenter
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: qsTr("DJI Mic 2 在 Windows 中首先是录音输入设备，不继承 RC003 的 13 键映射。")
                color: tokens.textSecondary
                font.pixelSize: tokens.fontSizeSmall
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: tokens.spacingSmall

            Label {
                text: qsTr("DJI Mic 2 设备控制")
                font.pixelSize: tokens.fontSizeTitle
                font.bold: true
                color: tokens.textPrimary
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: qsTr("当前可自定义映射：0。只有在真实 Windows 捕获到某个实体键的独立输入事件后，才会开放该键的映射选项。")
                color: tokens.textSecondary
                font.pixelSize: tokens.fontSizeSmall
            }

            Repeater {
                model: SettingsController.djiControlRows
                delegate: Rectangle {
                    required property var modelData
                    Layout.fillWidth: true
                    implicitHeight: controlRow.implicitHeight + tokens.spacingMedium * 2
                    radius: tokens.cornerRadiusSmall
                    color: tokens.surface
                    border.color: tokens.border
                    border.width: 1

                    RowLayout {
                        id: controlRow
                        anchors.fill: parent
                        anchors.margins: tokens.spacingMedium
                        spacing: tokens.spacingMedium

                        Rectangle {
                            Layout.preferredWidth: 72
                            Layout.preferredHeight: 32
                            radius: tokens.cornerRadiusSmall
                            color: tokens.fieldBackground
                            Label {
                                anchors.centerIn: parent
                                text: modelData.name
                                color: tokens.textPrimary
                                font.bold: true
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Label {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: modelData.behavior
                                color: tokens.textPrimary
                                font.pixelSize: tokens.fontSizeBody
                            }
                            Label {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: modelData.mapping
                                color: tokens.textSecondary
                                font.pixelSize: tokens.fontSizeSmall
                            }
                        }
                        Label {
                            text: qsTr("硬件内置")
                            color: tokens.disabledText
                            font.pixelSize: tokens.fontSizeSmall
                        }
                    }
                }
            }

            Item { Layout.fillHeight: true }

            RowLayout {
                Layout.alignment: Qt.AlignRight
                Button {
                    text: qsTr("重新检测麦克风")
                    onClicked: SettingsController.refreshDjiMicStatus()
                }
                Button {
                    text: qsTr("打开 Windows 声音输入设置")
                    highlighted: true
                    onClicked: SettingsController.openSoundSettings()
                }
            }
        }
    }
}
