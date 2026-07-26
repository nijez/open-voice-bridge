#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="$ROOT/.build/self-test/XiaomiRemoteBridgeMacSelfTest"

mkdir -p "${OUTPUT:h}"
xcrun swiftc \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/ATVVProtocol.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/VoiceBridgeDeviceProfile.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/DeviceProfileCatalog.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/BluetoothLifecycle.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/RemoteButtons.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/AppSettings.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/LaunchAtLoginManager.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/VoiceFunctionKeyLatch.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/LocalMicrophoneArbitration.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/ExternalMicrophoneProfile.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/RemoteVoiceFunctionMapper.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/AppLogger.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/TestTone.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/AudioPathDiagnostics.swift" \
  "$ROOT/Tests/SelfTest/main.swift" \
  -o "$OUTPUT"
OVB_DEVICE_PROFILES_DIR="$ROOT/device-profiles" "$OUTPUT"

python3 "$ROOT/scripts/validate-device-profiles.py"

if rg -q 'bottomSettingsCardHeight|BottomSettingsCardHeightKey|reportBottomCardHeight' \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/SettingsView.swift"; then
  print -u2 "FAIL SettingsView contains the retired bottom-card layout feedback path"
  exit 1
fi
print "PASS SettingsView bottom-card layout is state-feedback free"

SETTINGS_SOURCE="$ROOT/Sources/XiaomiRemoteBridgeMac/SettingsView.swift"
if rg -Fq '启用 (settings.xiaomiRemoteVariant.shortName)' "$SETTINGS_SOURCE"; then
  print -u2 "FAIL SettingsView renders the Xiaomi variant expression as literal text"
  exit 1
fi
if ! rg -Fq '启用 \(settings.xiaomiRemoteVariant.shortName) 自定义按键映射' "$SETTINGS_SOURCE"; then
  print -u2 "FAIL SettingsView does not interpolate the detected Xiaomi variant name"
  exit 1
fi
print "PASS SettingsView interpolates the detected Xiaomi variant name"

BLUETOOTH_SOURCE="$ROOT/Sources/XiaomiRemoteBridgeMac/XiaomiBluetoothBridge.swift"
for required_model_gate in \
  'modelConfirmation.isConfirmed' \
  '遥控器未提供可验证的型号信息' \
  '遥控器未提供型号字段' \
  '读取遥控器型号失败' \
  '暂不支持遥控器型号'; do
  if ! rg -Fq "$required_model_gate" "$BLUETOOTH_SOURCE"; then
    print -u2 "FAIL Xiaomi model-number gate is missing: $required_model_gate"
    exit 1
  fi
done
print "PASS Xiaomi BLE initialization fails closed until a supported model number is confirmed"

APP_SOURCE="$ROOT/Sources/XiaomiRemoteBridgeMac/XiaomiRemoteBridgeMacApp.swift"
if ! rg -q 'hostingController\.sizingOptions = \[\]' "$APP_SOURCE"; then
  print -u2 "FAIL settings host can feed SwiftUI preferred size back into the AppKit window"
  exit 1
fi
if ! rg -q 'func windowWillClose' "$APP_SOURCE" || \
   ! rg -q 'closingWindow\.contentViewController = nil' "$APP_SOURCE" || \
   ! rg -q 'settingsWindowController = nil' "$APP_SOURCE"; then
  print -u2 "FAIL closing Settings does not destroy the hidden SwiftUI observation tree"
  exit 1
fi
print "PASS Settings window has one-way sizing and releases its hidden SwiftUI tree"

if rg -q '1\.0 / 25\.0|A 25 Hz UI snapshot' \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/BridgeAppModel.swift"; then
  print -u2 "FAIL BridgeAppModel contains the retired permanent 25 Hz diagnostics refresh"
  exit 1
fi
if rg -q 'Timer\(' "$ROOT/Sources/XiaomiRemoteBridgeMac/BridgeAppModel.swift"; then
  print -u2 "FAIL BridgeAppModel directly owns a diagnostics Timer"
  exit 1
fi
if ! rg -q 'AudioDiagnosticsRefreshController' \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/BridgeAppModel.swift"; then
  print -u2 "FAIL BridgeAppModel does not use the diagnostics lifecycle controller"
  exit 1
fi
print "PASS BridgeAppModel delegates diagnostics scheduling to one lifecycle controller"

xcrun swift build
