// "连接" tab (XRBM-030 In-scope item 3): bridge-process status, save/launch,
// voice output endpoint, voice hotkey/trigger mode, open log directory.
// Every string shown here comes straight from settings_ui.py's pure
// describe_*()/build_save_model() functions via SettingsController - this
// file only lays the text out, it never decides what the text says.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import OvbRc003Settings 1.0

Item {
    id: root
    property var tokens

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        ColumnLayout {
            width: root.width - tokens.spacingLarge * 2
            x: tokens.spacingLarge
            y: tokens.spacingLarge
            spacing: tokens.spacingLarge

            // -- Bridge control ------------------------------------------------
            Rectangle {
                Layout.fillWidth: true
                radius: tokens.cornerRadiusLarge
                color: tokens.surface
                border.color: tokens.border
                border.width: 1
                implicitHeight: bridgeColumn.implicitHeight + tokens.spacingLarge * 2

                ColumnLayout {
                    id: bridgeColumn
                    anchors.fill: parent
                    anchors.margins: tokens.spacingLarge
                    spacing: tokens.spacingSmall

                    Label {
                        text: qsTr("桥接进程")
                        font.pixelSize: tokens.fontSizeTitle
                        font.bold: true
                        color: tokens.textPrimary
                    }
                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: SettingsController.launchStatusText
                        color: tokens.textSecondary
                        font.pixelSize: tokens.fontSizeBody
                    }
                    RowLayout {
                        spacing: tokens.spacingSmall
                        Button {
                            id: saveAndLaunchButton
                            text: qsTr("保存并启动桥接")
                            highlighted: true
                            onClicked: SettingsController.saveAndLaunch()
                            KeyNavigation.tab: openLogButton
                        }
                        Button {
                            id: openLogButton
                            objectName: "openLogButton"  // test hook: a plain (non-highlighted) Button, for the rendered contrast regression test
                            text: qsTr("打开日志目录")
                            onClicked: SettingsController.openLogLocation()
                        }
                    }
                }
            }

            // -- Voice output endpoint ------------------------------------------
            Rectangle {
                Layout.fillWidth: true
                radius: tokens.cornerRadiusLarge
                color: tokens.surface
                border.color: tokens.border
                border.width: 1
                implicitHeight: outputColumn.implicitHeight + tokens.spacingLarge * 2

                ColumnLayout {
                    id: outputColumn
                    anchors.fill: parent
                    anchors.margins: tokens.spacingLarge
                    spacing: tokens.spacingSmall

                    Label {
                        text: qsTr("语音输出设备")
                        font.pixelSize: tokens.fontSizeTitle
                        font.bold: true
                        color: tokens.textPrimary
                    }
                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("语音只会写入下方选中且当前存在的设备；未选择或设备缺失时语音静默失败，普通按键仍可用。")
                        color: tokens.textSecondary
                        font.pixelSize: tokens.fontSizeSmall
                    }
                    ComboBox {
                        id: endpointCombo
                        Layout.fillWidth: true
                        model: SettingsController.endpointOptions
                        currentIndex: SettingsController.selectedEndpointIndex
                        onActivated: SettingsController.selectedEndpointIndex = index
                        Accessible.name: qsTr("语音输出设备")
                    }
                }
            }

            // -- Voice hotkey / trigger mode --------------------------------
            Rectangle {
                Layout.fillWidth: true
                radius: tokens.cornerRadiusLarge
                color: tokens.surface
                border.color: tokens.border
                border.width: 1
                implicitHeight: hotkeyColumn.implicitHeight + tokens.spacingLarge * 2

                ColumnLayout {
                    id: hotkeyColumn
                    anchors.fill: parent
                    anchors.margins: tokens.spacingLarge
                    spacing: tokens.spacingSmall

                    Label {
                        text: qsTr("麦克风与语音")
                        font.pixelSize: tokens.fontSizeTitle
                        font.bold: true
                        color: tokens.textPrimary
                    }

                    GridLayout {
                        columns: 2
                        columnSpacing: tokens.spacingMedium
                        rowSpacing: tokens.spacingSmall

                        Label {
                            text: qsTr("语音热键 (mod+mod+key)")
                            color: tokens.textPrimary
                        }
                        TextField {
                            id: hotkeyField
                            objectName: "hotkeyField"  // test hook: for the rendered contrast regression test
                            Layout.fillWidth: true
                            text: SettingsController.hotkeyText
                            selectByMouse: true
                            onEditingFinished: SettingsController.hotkeyText = text
                            Accessible.name: qsTr("语音热键")
                        }

                        Label {
                            text: qsTr("触发方式")
                            color: tokens.textPrimary
                        }
                        ComboBox {
                            id: triggerModeCombo
                            Layout.fillWidth: true
                            model: SettingsController.triggerModeOptions
                            currentIndex: SettingsController.triggerModeIndex
                            onActivated: SettingsController.triggerModeIndex = index
                            Accessible.name: qsTr("语音触发方式")
                        }
                    }
                }
            }

            // -- Status / error feedback -------------------------------------
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                visible: text.length > 0
                text: SettingsController.errorMessage
                color: tokens.errorColor
                font.pixelSize: tokens.fontSizeBody
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                visible: text.length > 0 && SettingsController.errorMessage.length === 0
                text: SettingsController.statusMessage
                color: tokens.successColor
                font.pixelSize: tokens.fontSizeBody
            }

            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: tokens.spacingSmall
                Button {
                    text: qsTr("恢复全部默认")
                    onClicked: SettingsController.restoreDefaults()
                }
                Button {
                    text: qsTr("保存并应用")
                    highlighted: true
                    onClicked: SettingsController.saveSettings()
                }
            }

            Item { Layout.preferredHeight: tokens.spacingLarge }
        }
    }
}
