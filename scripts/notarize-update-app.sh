#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DISPLAY_NAME="小米遥控器桥接"
APP="$ROOT/dist/$DISPLAY_NAME.app"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$ROOT/Resources/Info.plist")"
PROFILE_NAME="${OVB_NOTARY_KEYCHAIN_PROFILE:-}"
UPDATE_BASENAME="OpenVoiceBridge-macOS-$VERSION.zip"
UPDATE_ARCHIVE="$ROOT/dist/$UPDATE_BASENAME"
RELEASE_NOTES="$ROOT/release-notes/v$VERSION.md"
DOWNLOAD_PREFIX="https://github.com/nijez/open-voice-bridge/releases/download/v$VERSION/"
SPARKLE_KEY_ACCOUNT="ed25519"
WORK_DIR="$(mktemp -d "$ROOT/dist/.update-work.XXXXXX")"

cleanup() {
  case "$WORK_DIR" in
    "$ROOT/dist/.update-work."*) rm -rf -- "$WORK_DIR" ;;
    *) print -u2 "refusing to clean unexpected update work path: $WORK_DIR" ;;
  esac
}
trap cleanup EXIT

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --keychain-profile)
      shift
      test "$#" -gt 0
      PROFILE_NAME="$1"
      ;;
    *) print -u2 "unknown argument: $1"; exit 1 ;;
  esac
  shift
done

if [[ -z "$PROFILE_NAME" ]]; then
  print -u2 "provide --keychain-profile or OVB_NOTARY_KEYCHAIN_PROFILE"
  exit 1
fi

test -d "$APP"
test -f "$RELEASE_NOTES"
"$ROOT/scripts/verify-app.sh" --universal --require-developer-id "$APP"

PRE_NOTARY_ZIP="$WORK_DIR/pre-notary.zip"
ditto -c -k --sequesterRsrc --keepParent --norsrc --noextattr --noqtn --noacl \
  "$APP" "$PRE_NOTARY_ZIP"
xcrun notarytool submit "$PRE_NOTARY_ZIP" --keychain-profile "$PROFILE_NAME" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv -t execute "$APP" 2>&1 | rg -q '^source=Notarized Developer ID$'

ditto -c -k --sequesterRsrc --keepParent --norsrc --noextattr --noqtn --noacl \
  "$APP" "$UPDATE_ARCHIVE"
(
  cd "$ROOT/dist"
  shasum -a 256 "$UPDATE_BASENAME" > "$UPDATE_BASENAME.sha256"
)

APPCAST_DIR="$WORK_DIR/appcast"
mkdir -p "$APPCAST_DIR"
ditto --norsrc --noextattr --noqtn --noacl "$UPDATE_ARCHIVE" "$APPCAST_DIR/$UPDATE_BASENAME"
ditto --norsrc --noextattr --noqtn --noacl "$RELEASE_NOTES" "$APPCAST_DIR/OpenVoiceBridge-macOS-$VERSION.md"

SPARKLE_TOOLS="$($ROOT/scripts/prepare-sparkle-tools.sh "$WORK_DIR/sparkle-tools")"
EXPECTED_PUBLIC_KEY="$(plutil -extract SUPublicEDKey raw -o - "$ROOT/Resources/Info.plist")"
KEYCHAIN_PUBLIC_KEY="$($SPARKLE_TOOLS/generate_keys --account "$SPARKLE_KEY_ACCOUNT" -p | tr -d '\r\n')"
if [[ "$KEYCHAIN_PUBLIC_KEY" != "$EXPECTED_PUBLIC_KEY" ]]; then
  print -u2 "Sparkle Keychain public key does not match the reviewed Info.plist key"
  exit 1
fi
"$SPARKLE_TOOLS/generate_appcast" \
  --account "$SPARKLE_KEY_ACCOUNT" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --embed-release-notes \
  --maximum-versions 3 \
  --maximum-deltas 0 \
  --versions "$BUILD" \
  "$APPCAST_DIR"

test -f "$APPCAST_DIR/appcast.xml"
"$SPARKLE_TOOLS/sign_update" --account "$SPARKLE_KEY_ACCOUNT" --verify "$APPCAST_DIR/appcast.xml"
ditto --norsrc --noextattr --noqtn --noacl "$APPCAST_DIR/appcast.xml" "$ROOT/appcast.xml"
"$ROOT/scripts/verify-update-archive.sh" \
  --require-notarized \
  --key-account "$SPARKLE_KEY_ACCOUNT" \
  "$UPDATE_ARCHIVE" \
  "$ROOT/appcast.xml"

print "NOTARIZED UPDATE APP: $APP"
print "UPDATE ARCHIVE: $UPDATE_ARCHIVE"
print "APPCAST: $ROOT/appcast.xml"
