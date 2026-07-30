#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DISPLAY_NAME="小米遥控器桥接"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$ROOT/Resources/Info.plist")"
EXPECTED_ARCHIVE_NAME="OpenVoiceBridge-macOS-$VERSION.zip"
EXPECTED_URL="https://github.com/nijez/open-voice-bridge/releases/download/v$VERSION/$EXPECTED_ARCHIVE_NAME"
EXPECTED_PUBLIC_KEY="$(plutil -extract SUPublicEDKey raw -o - "$ROOT/Resources/Info.plist")"
KEY_ACCOUNT="ed25519"
REQUIRE_NOTARIZED=0
ARCHIVE=""
APPCAST=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --require-notarized) REQUIRE_NOTARIZED=1 ;;
    --key-account)
      shift
      test "$#" -gt 0
      KEY_ACCOUNT="$1"
      ;;
    --*) print -u2 "unknown argument: $1"; exit 1 ;;
    *)
      if [[ -z "$ARCHIVE" ]]; then
        ARCHIVE="$1"
      elif [[ -z "$APPCAST" ]]; then
        APPCAST="$1"
      else
        print -u2 "expected one update archive and one appcast"
        exit 1
      fi
      ;;
  esac
  shift
done

test -f "$ARCHIVE"
test -f "$APPCAST"
test "${ARCHIVE:t}" = "$EXPECTED_ARCHIVE_NAME"

WORK_DIR="$(mktemp -d /private/tmp/ovb-update-verify.XXXXXX)"
cleanup() {
  case "$WORK_DIR" in
    /private/tmp/ovb-update-verify.*) rm -rf -- "$WORK_DIR" ;;
    *) print -u2 "refusing to clean unexpected verification path: $WORK_DIR" ;;
  esac
}
trap cleanup EXIT

EXTRACT_DIR="$WORK_DIR/extracted"
mkdir -p "$EXTRACT_DIR"
ditto -x -k "$ARCHIVE" "$EXTRACT_DIR"
APP="$EXTRACT_DIR/$DISPLAY_NAME.app"
test -d "$APP"
test "$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d -name '*.app' | wc -l | tr -d ' ')" = "1"

"$ROOT/scripts/verify-app.sh" --universal --require-developer-id "$APP"
test "$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")" = "$VERSION"
test "$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")" = "$BUILD"

if [[ "$REQUIRE_NOTARIZED" -eq 1 ]]; then
  xcrun stapler validate "$APP"
  APP_GATEKEEPER_RESULT="$(spctl -a -vvv -t execute "$APP" 2>&1)"
  if ! rg -q '^source=Notarized Developer ID$' <<<"$APP_GATEKEEPER_RESULT"; then
    print -u2 "update archive app did not pass Gatekeeper as Notarized Developer ID"
    print -u2 -- "$APP_GATEKEEPER_RESULT"
    exit 1
  fi
fi

DIST_APP="$ROOT/dist/$DISPLAY_NAME.app"
test -d "$DIST_APP"
DIST_CDHASH="$(codesign -dv --verbose=4 "$DIST_APP" 2>&1 | sed -n 's/^CDHash=//p' | head -n 1)"
ARCHIVE_CDHASH="$(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^CDHash=//p' | head -n 1)"
test -n "$DIST_CDHASH"
test "$ARCHIVE_CDHASH" = "$DIST_CDHASH"

ENCLOSURE_URL="$(xmllint --xpath 'string(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"]/*[local-name()="enclosure"]/@url)' "$APPCAST")"
ENCLOSURE_LENGTH="$(xmllint --xpath 'string(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"]/*[local-name()="enclosure"]/@length)' "$APPCAST")"
ENCLOSURE_TYPE="$(xmllint --xpath 'string(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"]/*[local-name()="enclosure"]/@type)' "$APPCAST")"
ENCLOSURE_SIGNATURE="$(xmllint --xpath 'string(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"]/*[local-name()="enclosure"]/@*[local-name()="edSignature"])' "$APPCAST")"
ITEM_COUNT="$(xmllint --xpath 'count(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"])' "$APPCAST")"
ENCLOSURE_COUNT="$(xmllint --xpath 'count(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"]/*[local-name()="enclosure"])' "$APPCAST")"
ITEM_VERSION="$(xmllint --xpath 'string(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"]/*[local-name()="version"])' "$APPCAST")"
ITEM_SHORT_VERSION="$(xmllint --xpath 'string(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"]/*[local-name()="shortVersionString"])' "$APPCAST")"
MINIMUM_SYSTEM_VERSION="$(xmllint --xpath 'string(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"]/*[local-name()="minimumSystemVersion"])' "$APPCAST")"

test "$ITEM_COUNT" = "1"
test "$ENCLOSURE_COUNT" = "1"
test "$ENCLOSURE_URL" = "$EXPECTED_URL"
test "$ENCLOSURE_LENGTH" = "$(stat -f %z "$ARCHIVE")"
test "$ENCLOSURE_TYPE" = "application/octet-stream"
test "$ITEM_VERSION" = "$BUILD"
test "$ITEM_SHORT_VERSION" = "$VERSION"
test "$MINIMUM_SYSTEM_VERSION" = "11.0"
test -n "$ENCLOSURE_SIGNATURE"

SPARKLE_TOOLS="$($ROOT/scripts/prepare-sparkle-tools.sh "$WORK_DIR/sparkle-tools")"
KEYCHAIN_PUBLIC_KEY="$($SPARKLE_TOOLS/generate_keys --account "$KEY_ACCOUNT" -p | tr -d '\r\n')"
test "$KEYCHAIN_PUBLIC_KEY" = "$EXPECTED_PUBLIC_KEY"
"$SPARKLE_TOOLS/sign_update" --account "$KEY_ACCOUNT" --verify "$APPCAST"
"$SPARKLE_TOOLS/sign_update" --account "$KEY_ACCOUNT" --verify "$ARCHIVE" "$ENCLOSURE_SIGNATURE"

print "UPDATE ARCHIVE VERIFY PASS: $ARCHIVE"
print "VERSION: $VERSION ($BUILD)"
print "CDHASH: $ARCHIVE_CDHASH"
