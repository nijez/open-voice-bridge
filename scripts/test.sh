#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="$ROOT/.build/self-test/XiaomiRemoteBridgeMacSelfTest"
SPARKLE_FRAMEWORK="$ROOT/Vendor/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

mkdir -p "${OUTPUT:h}"
test "$(plutil -extract CFBundleShortVersionString raw -o - "$SPARKLE_FRAMEWORK/Versions/B/Resources/Info.plist")" = "2.9.2"
codesign --verify --deep --strict "$SPARKLE_FRAMEWORK"
print "PASS vendored Sparkle framework is the reviewed 2.9.2 bundle and its upstream code seal is intact"
xcrun swiftc \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/ATVVProtocol.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/VoiceBridgeDeviceProfile.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/DeviceProfileCatalog.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/BluetoothLifecycle.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/RemoteButtons.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/AppSettings.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/LaunchAtLoginManager.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/VoiceFunctionKeyLatch.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/LocalMicrophoneCapture.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/LocalMicrophoneArbitration.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/ExternalMicrophoneProfile.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/RemoteVoiceFunctionMapper.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/AppLogger.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/TestTone.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/UpdatePolicy.swift" \
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

if [ "$(rg -c 'NSImage\(contentsOf:' "$ROOT/Sources/XiaomiRemoteBridgeMac/SettingsView.swift")" -ne 1 ]; then
  print -u2 "FAIL SettingsView must load bundled remote images only in RemoteImageCatalog"
  exit 1
fi
if ! rg -Fq 'RemoteImageCatalog.image(for:' \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/SettingsView.swift"; then
  print -u2 "FAIL SettingsView does not use the process-lifetime remote image cache"
  exit 1
fi
if ! rg -Fq 'RemoteImageCatalog.prewarm()' \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/SettingsView.swift"; then
  print -u2 "FAIL SettingsView does not prewarm the remote image cache before body evaluation"
  exit 1
fi
print "PASS SettingsView performs no synchronous remote-image decoding from view bodies"

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

INFO_PLIST="$ROOT/Resources/Info.plist"
test "$(plutil -extract SUFeedURL raw -o - "$INFO_PLIST")" = \
  "https://raw.githubusercontent.com/nijez/open-voice-bridge/main/appcast.xml"
test "$(plutil -extract SUPublicEDKey raw -o - "$INFO_PLIST")" = \
  "gtTlOWJuW/zsBtP27uWp48WdHtdztj33zVGNdvJo40I="
test "$(plutil -extract SUEnableAutomaticChecks raw -o - "$INFO_PLIST")" = "true"
test "$(plutil -extract SUScheduledCheckInterval raw -o - "$INFO_PLIST")" = "86400"
test "$(plutil -extract SUAllowsAutomaticUpdates raw -o - "$INFO_PLIST")" = "false"
test "$(plutil -extract SUEnableSystemProfiling raw -o - "$INFO_PLIST")" = "false"
test "$(plutil -extract SURequireSignedFeed raw -o - "$INFO_PLIST")" = "true"
test "$(plutil -extract SUVerifyUpdateBeforeExtraction raw -o - "$INFO_PLIST")" = "true"
rg -Fq 'DOWNLOAD_PREFIX="https://github.com/nijez/open-voice-bridge/releases/download/v$VERSION/"' \
  "$ROOT/scripts/notarize-update-app.sh"
rg -Fq 'RELEASE_NOTES="$ROOT/release-notes/v$VERSION.md"' \
  "$ROOT/scripts/notarize-update-app.sh"
test -f "$ROOT/release-notes/v$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST").md"
rg -Fq 'shasum -a 256 "$UPDATE_BASENAME" > "$UPDATE_BASENAME.sha256"' \
  "$ROOT/scripts/notarize-update-app.sh"
print "PASS Sparkle feed, EdDSA key, signed-feed/pre-extraction verification, daily schedule, no-silent-install, and no-profiling policy are pinned"

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
