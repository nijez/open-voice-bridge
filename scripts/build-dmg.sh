#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT_DIR="$ROOT/dist"
DISPLAY_NAME="小米遥控器桥接"
APP_DIR="$OUTPUT_DIR/$DISPLAY_NAME.app"
PLIST="$ROOT/Resources/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$PLIST")"
SOURCE_ROOT="open-voice-bridge-$VERSION-source"
SOURCE_ARCHIVE="$DISPLAY_NAME-$VERSION-对应源码.zip"
RELEASE_SIGN=0

for arg in "$@"; do
  case "$arg" in
    --release-sign) RELEASE_SIGN=1 ;;
    *) print -u2 "unknown argument: $arg"; exit 1 ;;
  esac
done

if [[ "$RELEASE_SIGN" -eq 1 ]]; then
  DMG_BASENAME="$DISPLAY_NAME-$VERSION.dmg"
  VOLUME_NAME="$DISPLAY_NAME $VERSION"
else
  DMG_BASENAME="$DISPLAY_NAME-$VERSION-测试版.dmg"
  VOLUME_NAME="$DISPLAY_NAME $VERSION 测试版"
fi
DMG="$OUTPUT_DIR/$DMG_BASENAME"

mkdir -p "$OUTPUT_DIR"
WORK_DIR="$(mktemp -d "$OUTPUT_DIR/.package-work.XXXXXX")"
STAGING="$WORK_DIR/dmg"
SOURCE_DIR="$WORK_DIR/$SOURCE_ROOT"

cleanup() {
  case "$WORK_DIR" in
    "$OUTPUT_DIR/.package-work."*) rm -rf -- "$WORK_DIR" ;;
    *) print -u2 "refusing to clean unexpected work path: $WORK_DIR" ;;
  esac
}
trap cleanup EXIT

mkdir -p "$STAGING" "$SOURCE_DIR" "$SOURCE_DIR/docs"

APP_BUILD_ARGS=(--universal)
APP_VERIFY_ARGS=(--universal)
if [[ "$RELEASE_SIGN" -eq 1 ]]; then
  APP_BUILD_ARGS+=(--release-sign)
  APP_VERIFY_ARGS+=(--require-developer-id)
fi
"$ROOT/scripts/build-app.sh" "${APP_BUILD_ARGS[@]}"
"$ROOT/scripts/verify-app.sh" "${APP_VERIFY_ARGS[@]}" "$APP_DIR"

ditto --norsrc --noextattr --noqtn --noacl \
  "$APP_DIR" "$STAGING/$DISPLAY_NAME.app"
ln -s /Applications "$STAGING/Applications"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/Resources/首次安装说明.txt" "$STAGING/首次安装说明.txt"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/LICENSE" "$STAGING/LICENSE"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/COPYRIGHT" "$STAGING/COPYRIGHT"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGING/THIRD_PARTY_NOTICES.md"

for item in Package.swift Sources Tests scripts Resources device-profiles specs README.md LICENSE COPYRIGHT THIRD_PARTY_NOTICES.md; do
  ditto --norsrc --noextattr --noqtn --noacl \
    "$ROOT/$item" "$SOURCE_DIR/$item"
done

for item in ARCHITECTURE.md ADDING_A_DEVICE.md; do
  ditto --norsrc --noextattr --noqtn --noacl \
    "$ROOT/docs/$item" "$SOURCE_DIR/docs/$item"
done

ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl \
  "$SOURCE_DIR" "$STAGING/$SOURCE_ARCHIVE"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -fs "HFS+" \
  -format UDZO \
  -ov \
  "$DMG"

if [[ "$RELEASE_SIGN" -eq 1 ]]; then
  codesign \
    --force \
    --timestamp \
    --sign "$OVB_CODESIGN_IDENTITY" \
    "$DMG"
  codesign --verify --strict "$DMG"

  DMG_SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$DMG" 2>&1)"
  if ! rg -q '^Authority=Developer ID Application:' <<<"$DMG_SIGNATURE_DETAILS"; then
    print -u2 "release DMG is not signed with Developer ID Application"
    exit 1
  fi
  if ! rg -q '^Timestamp=' <<<"$DMG_SIGNATURE_DETAILS"; then
    print -u2 "release DMG signature is missing a secure timestamp"
    exit 1
  fi
fi

(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$DMG_BASENAME" > "$DMG_BASENAME.sha256"
)

print "DMG: $DMG"
print "SHA256: $DMG.sha256"
print "VERSION: $VERSION ($BUILD)"
