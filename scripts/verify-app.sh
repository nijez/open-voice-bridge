#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
ENTITLEMENTS="$ROOT/Resources/XiaomiRemoteBridgeMac.entitlements"
EXPECTED_RELEASE_TEAM_ID="T486HD59BP"
UNIVERSAL=0
REQUIRE_DEVELOPER_ID=0
APP=""
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --require-developer-id) REQUIRE_DEVELOPER_ID=1 ;;
    --*) print -u2 "unknown argument: $arg"; exit 1 ;;
    *)
      if [[ -n "$APP" ]]; then
        print -u2 "only one app path may be supplied"
        exit 1
      fi
      APP="$arg"
      ;;
  esac
done
APP="${APP:-$ROOT/dist/小米遥控器桥接.app}"
PLIST="$APP/Contents/Info.plist"
BINARY="$APP/Contents/MacOS/XiaomiRemoteBridgeMac"
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION_DIR="$SPARKLE_FRAMEWORK/Versions/B"

test -d "$APP"
test -f "$PLIST"
test -x "$BINARY"
test -f "$APP/Contents/Resources/LICENSE"
test -f "$APP/Contents/Resources/README.md"
test -f "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
test -f "$APP/Contents/Resources/Sparkle-LICENSE.txt"
test -f "$APP/Contents/Resources/COPYRIGHT"
test -f "$APP/Contents/Resources/RC003-remote-photo.png"
test -f "$APP/Contents/Resources/ARN9-remote-photo.png"
test -f "$APP/Contents/Resources/OpenVoiceBridge.icns"
test -f "$APP/Contents/Resources/device-profiles/xiaomi-rc003.json"
test -f "$APP/Contents/Resources/device-profiles/xiaomi-arn9.json"
test -f "$APP/Contents/Resources/device-profiles/dji-mic-2.json"
test -f "$ENTITLEMENTS"
test -d "$SPARKLE_FRAMEWORK"
test -d "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
test -d "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc"
test -x "$SPARKLE_VERSION_DIR/Autoupdate"
test -d "$SPARKLE_VERSION_DIR/Updater.app"
cmp -s \
  "$ROOT/device-profiles/xiaomi-rc003.json" \
  "$APP/Contents/Resources/device-profiles/xiaomi-rc003.json"
cmp -s \
  "$ROOT/device-profiles/xiaomi-arn9.json" \
  "$APP/Contents/Resources/device-profiles/xiaomi-arn9.json"
cmp -s \
  "$ROOT/device-profiles/dji-mic-2.json" \
  "$APP/Contents/Resources/device-profiles/dji-mic-2.json"

test "$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")" = \
  "com.kingwell.XiaomiRemoteBridgeMac"
test "$(plutil -extract LSUIElement raw -o - "$PLIST")" = "false"
test "$(plutil -extract CFBundleIconFile raw -o - "$PLIST")" = \
  "OpenVoiceBridge.icns"
test "$(plutil -extract LSMinimumSystemVersion raw -o - "$PLIST")" = "11.0"
test -n "$(plutil -extract NSBluetoothAlwaysUsageDescription raw -o - "$PLIST")"
test -n "$(plutil -extract NSMicrophoneUsageDescription raw -o - "$PLIST")"
test "$(plutil -extract SUFeedURL raw -o - "$PLIST")" = \
  "https://raw.githubusercontent.com/nijez/open-voice-bridge/main/appcast.xml"
test "$(plutil -extract SUPublicEDKey raw -o - "$PLIST")" = \
  "gtTlOWJuW/zsBtP27uWp48WdHtdztj33zVGNdvJo40I="
test "$(plutil -extract SUEnableAutomaticChecks raw -o - "$PLIST")" = "true"
test "$(plutil -extract SUScheduledCheckInterval raw -o - "$PLIST")" = "86400"
test "$(plutil -extract SUAutomaticallyUpdate raw -o - "$PLIST")" = "false"
test "$(plutil -extract SUAllowsAutomaticUpdates raw -o - "$PLIST")" = "false"
test "$(plutil -extract SUEnableSystemProfiling raw -o - "$PLIST")" = "false"
test "$(plutil -extract SURequireSignedFeed raw -o - "$PLIST")" = "true"
test "$(plutil -extract SUVerifyUpdateBeforeExtraction raw -o - "$PLIST")" = "true"
test "$(plutil -extract CFBundleShortVersionString raw -o - "$SPARKLE_VERSION_DIR/Resources/Info.plist")" = "2.9.2"

codesign --verify --deep --strict "$APP"
EXPECTED_ENTITLEMENTS="$(plutil -convert xml1 -o - "$ENTITLEMENTS")"
SIGNED_ENTITLEMENTS="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"
NORMALIZED_SIGNED_ENTITLEMENTS="$(plutil -convert xml1 -o - - <<<"$SIGNED_ENTITLEMENTS")"
if [[ "$NORMALIZED_SIGNED_ENTITLEMENTS" != "$EXPECTED_ENTITLEMENTS" ]]; then
  print -u2 "app signature entitlements differ from the reviewed entitlement allowlist"
  exit 1
fi
if [[ "$REQUIRE_DEVELOPER_ID" -eq 1 ]]; then
  SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP" 2>&1)"
  if ! rg -q '^Authority=Developer ID Application:' <<<"$SIGNATURE_DETAILS"; then
    print -u2 "app is not signed with Developer ID Application"
    exit 1
  fi
  if ! rg -q '^CodeDirectory .*flags=.*\(runtime\)' <<<"$SIGNATURE_DETAILS"; then
    print -u2 "app signature is missing the hardened runtime flag"
    exit 1
  fi
  if ! rg -q '^Timestamp=' <<<"$SIGNATURE_DETAILS"; then
    print -u2 "app signature is missing a secure timestamp"
    exit 1
  fi
  if [[ "$(print -r -- "$SIGNATURE_DETAILS" | sed -n 's/^TeamIdentifier=//p' | head -n 1)" != "$EXPECTED_RELEASE_TEAM_ID" ]]; then
    print -u2 "app signature TeamIdentifier is not the reviewed project team"
    exit 1
  fi
  DESIGNATED_REQUIREMENT="$(codesign -dr - "$APP" 2>&1)"
  if ! rg -Fq "certificate leaf[subject.OU] = $EXPECTED_RELEASE_TEAM_ID" <<<"$DESIGNATED_REQUIREMENT"; then
    print -u2 "app designated requirement is not pinned to the reviewed project team"
    exit 1
  fi

  for nested_component in \
    "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc" \
    "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc" \
    "$SPARKLE_VERSION_DIR/Autoupdate" \
    "$SPARKLE_VERSION_DIR/Updater.app" \
    "$SPARKLE_FRAMEWORK"; do
    NESTED_DETAILS="$(codesign -dv --verbose=4 "$nested_component" 2>&1)"
    if ! rg -q '^Authority=Developer ID Application:' <<<"$NESTED_DETAILS"; then
      print -u2 "Sparkle component is not signed with Developer ID Application: $nested_component"
      exit 1
    fi
    if [[ "$(print -r -- "$NESTED_DETAILS" | sed -n 's/^TeamIdentifier=//p' | head -n 1)" != "$EXPECTED_RELEASE_TEAM_ID" ]]; then
      print -u2 "Sparkle component TeamIdentifier is not the reviewed project team: $nested_component"
      exit 1
    fi
    if ! rg -q '^CodeDirectory .*flags=.*\(runtime\)' <<<"$NESTED_DETAILS"; then
      print -u2 "Sparkle component is missing hardened runtime: $nested_component"
      exit 1
    fi
    if ! rg -q '^Timestamp=' <<<"$NESTED_DETAILS"; then
      print -u2 "Sparkle component is missing a secure timestamp: $nested_component"
      exit 1
    fi
    NESTED_REQUIREMENT="$(codesign -dr - "$nested_component" 2>&1)"
    if ! rg -Fq "certificate leaf[subject.OU] = $EXPECTED_RELEASE_TEAM_ID" <<<"$NESTED_REQUIREMENT"; then
      print -u2 "Sparkle component designated requirement is not pinned to the reviewed project team: $nested_component"
      exit 1
    fi
  done
fi

if codesign -d --entitlements :- "$APP" 2>/dev/null | rg -q 'get-task-allow'; then
  print -u2 "application contains forbidden get-task-allow entitlement"
  exit 1
fi
for nested_component in \
  "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc" \
  "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc" \
  "$SPARKLE_VERSION_DIR/Autoupdate" \
  "$SPARKLE_VERSION_DIR/Updater.app" \
  "$SPARKLE_FRAMEWORK"; do
  if codesign -d --entitlements :- "$nested_component" 2>/dev/null | rg -q 'get-task-allow'; then
    print -u2 "Sparkle component contains forbidden get-task-allow entitlement: $nested_component"
    exit 1
  fi
done
file "$BINARY" | rg -q 'Mach-O 64-bit executable'

for arch in $(lipo -archs "$BINARY"); do
  if ! xcrun otool -l -arch "$arch" "$BINARY" | \
      awk '/LC_RPATH/{capture=1; next} capture && /path @executable_path\/\.\.\/Frameworks/{found=1} END{exit found ? 0 : 1}'; then
    print -u2 "missing bundled-framework runtime search path for $arch"
    exit 1
  fi
done

if [[ "$UNIVERSAL" -eq 1 ]]; then
  ARCHS="$(lipo -archs "$BINARY")"
  print "universal archs: $ARCHS"
  for required in arm64 x86_64; do
    if ! print -r -- "$ARCHS" | tr ' ' '\n' | rg -qx "$required"; then
      print -u2 "missing architecture in universal binary: $required"
      exit 1
    fi
  done
  for arch in arm64 x86_64; do
    BUILD_INFO="$(xcrun vtool -show-build -arch "$arch" "$BINARY")"
    if ! rg -q '^    minos 11\.0$' <<<"$BUILD_INFO"; then
      print -u2 "unexpected minimum macOS version for $arch (expected 11.0)"
      print -u2 -- "$BUILD_INFO"
      exit 1
    fi
  done
fi

EXPECTED_FILES=$'Contents/Info.plist\nContents/MacOS/XiaomiRemoteBridgeMac\nContents/Resources/ARN9-remote-photo.png\nContents/Resources/COPYRIGHT\nContents/Resources/LICENSE\nContents/Resources/OpenVoiceBridge.icns\nContents/Resources/RC003-remote-photo.png\nContents/Resources/README.md\nContents/Resources/Sparkle-LICENSE.txt\nContents/Resources/THIRD_PARTY_NOTICES.md\nContents/Resources/device-profiles/dji-mic-2.json\nContents/Resources/device-profiles/xiaomi-arn9.json\nContents/Resources/device-profiles/xiaomi-rc003.json\nContents/_CodeSignature/CodeResources'
ACTUAL_FILES="$(find "$APP/Contents" -path "$APP/Contents/Frameworks" -prune -o -type f -print | sed "s#^$APP/##" | LC_ALL=C sort)"
NOTARIZED_EXPECTED_FILES=$'Contents/CodeResources\n'"$EXPECTED_FILES"
if [[ "$ACTUAL_FILES" = "$NOTARIZED_EXPECTED_FILES" ]]; then
  # stapler adds only this ticket file at the app root.  Do not permit an
  # arbitrary extra file to masquerade as notarization metadata.
  xcrun stapler validate "$APP" >/dev/null
elif [[ "$ACTUAL_FILES" != "$EXPECTED_FILES" ]]; then
  print -u2 "application file allowlist mismatch"
  diff -u <(print -r -- "$EXPECTED_FILES") <(print -r -- "$ACTUAL_FILES") >&2 || true
  exit 1
fi

SPARKLE_ALLOWED_ROOTS="$(find "$APP/Contents/Frameworks" -mindepth 1 -maxdepth 1 -print | sed "s#^$APP/Contents/Frameworks/##")"
test "$SPARKLE_ALLOWED_ROOTS" = "Sparkle.framework"

if rg -a -q '/Users/[^/[:space:]]+|/tmp/remote-bridge|AA:BB:CC:DD:EE:FF' "$APP/Contents"; then
  print -u2 "bundle contains a forbidden local path or example device address"
  exit 1
fi

print "APP VERIFY PASS: $APP"
