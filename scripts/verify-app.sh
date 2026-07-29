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

test -d "$APP"
test -f "$PLIST"
test -x "$BINARY"
test -f "$APP/Contents/Resources/LICENSE"
test -f "$APP/Contents/Resources/README.md"
test -f "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
test -f "$APP/Contents/Resources/COPYRIGHT"
test -f "$APP/Contents/Resources/RC003-remote-photo.png"
test -f "$APP/Contents/Resources/ARN9-remote-photo.png"
test -f "$APP/Contents/Resources/OpenVoiceBridge.icns"
test -f "$APP/Contents/Resources/device-profiles/xiaomi-rc003.json"
test -f "$APP/Contents/Resources/device-profiles/xiaomi-arn9.json"
test -f "$APP/Contents/Resources/device-profiles/dji-mic-2.json"
test -f "$ENTITLEMENTS"
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
fi
file "$BINARY" | rg -q 'Mach-O 64-bit executable'

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

EXPECTED_FILES=$'Contents/Info.plist\nContents/MacOS/XiaomiRemoteBridgeMac\nContents/Resources/ARN9-remote-photo.png\nContents/Resources/COPYRIGHT\nContents/Resources/LICENSE\nContents/Resources/OpenVoiceBridge.icns\nContents/Resources/RC003-remote-photo.png\nContents/Resources/README.md\nContents/Resources/THIRD_PARTY_NOTICES.md\nContents/Resources/device-profiles/dji-mic-2.json\nContents/Resources/device-profiles/xiaomi-arn9.json\nContents/Resources/device-profiles/xiaomi-rc003.json\nContents/_CodeSignature/CodeResources'
ACTUAL_FILES="$(find "$APP/Contents" -type f | sed "s#^$APP/##" | LC_ALL=C sort)"
test "$ACTUAL_FILES" = "$EXPECTED_FILES"

if rg -a -q '/Users/[^/[:space:]]+|/tmp/remote-bridge|AA:BB:CC:DD:EE:FF' "$APP/Contents"; then
  print -u2 "bundle contains a forbidden local path or example device address"
  exit 1
fi

print "APP VERIFY PASS: $APP"
