#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT_DIR="$ROOT/dist"
DISPLAY_NAME="小米遥控器桥接"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$ROOT/Resources/Info.plist")"
REQUIRE_DEVELOPER_ID=0
REQUIRE_NOTARIZED=0
DMG=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --require-developer-id) REQUIRE_DEVELOPER_ID=1 ;;
    --require-notarized)
      REQUIRE_NOTARIZED=1
      REQUIRE_DEVELOPER_ID=1
      ;;
    --*) print -u2 "unknown argument: $1"; exit 1 ;;
    *)
      if [[ -n "$DMG" ]]; then
        print -u2 "only one DMG path may be supplied"
        exit 1
      fi
      DMG="$1"
      ;;
  esac
  shift
done

if [[ -z "$DMG" ]]; then
  if [[ "$REQUIRE_DEVELOPER_ID" -eq 1 ]]; then
    DMG="$OUTPUT_DIR/$DISPLAY_NAME-$VERSION.dmg"
  else
    DMG="$OUTPUT_DIR/$DISPLAY_NAME-$VERSION-测试版.dmg"
  fi
fi
CHECKSUM="$DMG.sha256"
SOURCE_ROOT="open-voice-bridge-$VERSION-source"
SOURCE_ARCHIVE="$DISPLAY_NAME-$VERSION-对应源码.zip"
VERIFY_ROOT="$(mktemp -d /private/tmp/xrbm-dmg-verify.XXXXXX)"
MOUNT_POINT="$VERIFY_ROOT/mount"
SOURCE_EXTRACT="$VERIFY_ROOT/source"
ZIP_LIST="$VERIFY_ROOT/zip-entries.txt"
ATTACHED=0

mkdir -p "$MOUNT_POINT" "$SOURCE_EXTRACT"

cleanup() {
  if [[ "$ATTACHED" -eq 1 ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  case "$VERIFY_ROOT" in
    /private/tmp/xrbm-dmg-verify.*) rm -rf -- "$VERIFY_ROOT" ;;
    *) print -u2 "refusing to clean unexpected verification path: $VERIFY_ROOT" ;;
  esac
}
trap cleanup EXIT

test -f "$DMG"
test -f "$CHECKSUM"
(
  cd "${DMG:h}"
  shasum -a 256 -c "${CHECKSUM:t}"
)
hdiutil verify "$DMG"

if [[ "$REQUIRE_DEVELOPER_ID" -eq 1 ]]; then
  codesign --verify --strict "$DMG"
  DMG_SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$DMG" 2>&1)"
  if ! rg -q '^Authority=Developer ID Application:' <<<"$DMG_SIGNATURE_DETAILS"; then
    print -u2 "DMG is not signed with Developer ID Application"
    exit 1
  fi
  if ! rg -q '^Timestamp=' <<<"$DMG_SIGNATURE_DETAILS"; then
    print -u2 "DMG signature is missing a secure timestamp"
    exit 1
  fi
fi

hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$DMG" -quiet
ATTACHED=1

APP="$MOUNT_POINT/$DISPLAY_NAME.app"
GUIDE="$MOUNT_POINT/首次安装说明.txt"
SOURCE_ZIP="$MOUNT_POINT/$SOURCE_ARCHIVE"

test -L "$MOUNT_POINT/Applications"
test "$(readlink "$MOUNT_POINT/Applications")" = "/Applications"
test -f "$GUIDE"
test -f "$SOURCE_ZIP"
APP_VERIFY_ARGS=(--universal)
if [[ "$REQUIRE_DEVELOPER_ID" -eq 1 ]]; then
  APP_VERIFY_ARGS+=(--require-developer-id)
fi
"$ROOT/scripts/verify-app.sh" "${APP_VERIFY_ARGS[@]}" "$APP"

test "$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")" = "$VERSION"
test "$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")" = "$BUILD"
APP_SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP" 2>&1)"
if ! rg -q '^Signature=adhoc$|^Authority=' <<<"$APP_SIGNATURE_DETAILS"; then
  print -u2 "app is missing both an ad-hoc signature and a named signing authority"
  exit 1
fi

if [[ "$REQUIRE_NOTARIZED" -eq 1 ]]; then
  xcrun stapler validate "$DMG"
  GATEKEEPER_RESULT="$(spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1)"
  if ! rg -q '^source=Notarized Developer ID$' <<<"$GATEKEEPER_RESULT"; then
    print -u2 "DMG did not pass Gatekeeper as a Notarized Developer ID artifact"
    print -u2 -- "$GATEKEEPER_RESULT"
    exit 1
  fi
fi

test "$(sips -g pixelWidth "$APP/Contents/Resources/RC003-remote-photo.png" | tail -n 1 | tr -cd '0-9')" = "508"
test "$(sips -g pixelHeight "$APP/Contents/Resources/RC003-remote-photo.png" | tail -n 1 | tr -cd '0-9')" = "1030"

unzip -Z1 "$SOURCE_ZIP" > "$ZIP_LIST"
for required in \
  "$SOURCE_ROOT/Package.swift" \
  "$SOURCE_ROOT/Sources/XiaomiRemoteBridgeMac/SettingsView.swift" \
  "$SOURCE_ROOT/Tests/SelfTest/main.swift" \
  "$SOURCE_ROOT/scripts/build-dmg.sh" \
  "$SOURCE_ROOT/Resources/RC003-remote-photo.png" \
  "$SOURCE_ROOT/device-profiles/xiaomi-rc003.json" \
  "$SOURCE_ROOT/device-profiles/dji-mic-2.json" \
  "$SOURCE_ROOT/specs/device-profile.schema.json" \
  "$SOURCE_ROOT/docs/ARCHITECTURE.md" \
  "$SOURCE_ROOT/docs/ADDING_A_DEVICE.md" \
  "$SOURCE_ROOT/LICENSE"; do
  rg -qx "$required" "$ZIP_LIST"
done

if rg -q '(^|/)(\.build|dist|logs?|\.DS_Store)(/|$)|(^|/)__MACOSX(/|$)' "$ZIP_LIST"; then
  print -u2 "source archive contains a forbidden build, log, or metadata path"
  exit 1
fi

unzip -qq "$SOURCE_ZIP" -d "$SOURCE_EXTRACT"
if rg -a -q '/Users/[^/[:space:]]+|/tmp/remote-bridge|AA:BB:CC:DD:EE:FF' \
  "$SOURCE_EXTRACT/$SOURCE_ROOT/Sources" \
  "$SOURCE_EXTRACT/$SOURCE_ROOT/Tests" \
  "$SOURCE_EXTRACT/$SOURCE_ROOT/Resources" \
  "$SOURCE_EXTRACT/$SOURCE_ROOT/device-profiles" \
  "$SOURCE_EXTRACT/$SOURCE_ROOT/specs" \
  "$SOURCE_EXTRACT/$SOURCE_ROOT/docs" \
  "$SOURCE_EXTRACT/$SOURCE_ROOT/Package.swift" \
  "$SOURCE_EXTRACT/$SOURCE_ROOT/README.md" \
  "$SOURCE_EXTRACT/$SOURCE_ROOT/LICENSE" \
  "$SOURCE_EXTRACT/$SOURCE_ROOT/COPYRIGHT" \
  "$SOURCE_EXTRACT/$SOURCE_ROOT/THIRD_PARTY_NOTICES.md"; then
  print -u2 "source archive contains a forbidden local path or example device address"
  exit 1
fi

if rg -a -q '/Users/[^/[:space:]]+|/tmp/remote-bridge|AA:BB:CC:DD:EE:FF' \
  "$APP/Contents" "$GUIDE" "$MOUNT_POINT/THIRD_PARTY_NOTICES.md"; then
  print -u2 "DMG payload contains a forbidden local path or example device address"
  exit 1
fi

print "DMG VERIFY PASS: $DMG"
print "VERSION: $VERSION ($BUILD)"
SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP" 2>&1)"
if rg -q '^Signature=adhoc$' <<<"$SIGNATURE_DETAILS"; then
  SIGNATURE_LABEL="ad-hoc"
else
  SIGNING_AUTHORITY="$(print -r -- "$SIGNATURE_DETAILS" | sed -n 's/^Authority=//p' | head -n 1)"
  SIGNATURE_LABEL="named (${SIGNING_AUTHORITY:-unknown authority})"
fi
if [[ "$REQUIRE_NOTARIZED" -eq 1 ]]; then
  print "SIGNATURE: $SIGNATURE_LABEL / stapled notarization ticket validated"
else
  print "SIGNATURE: $SIGNATURE_LABEL / notarization not required by this invocation"
fi
