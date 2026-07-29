#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="XiaomiRemoteBridgeMac"
DISPLAY_NAME="小米遥控器桥接"
OUTPUT_DIR="$ROOT/dist"
APP_DIR="$OUTPUT_DIR/$DISPLAY_NAME.app"
ENTITLEMENTS="$ROOT/Resources/XiaomiRemoteBridgeMac.entitlements"
EXPECTED_RELEASE_TEAM_ID="T486HD59BP"
LOCAL_SIGNING_IDENTITY="${OVB_CODESIGN_IDENTITY:-Open Voice Bridge Local Code Signing}"

UNIVERSAL=0
RELEASE_SIGN=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --release-sign) RELEASE_SIGN=1 ;;
    *) print -u2 "unknown argument: $arg"; exit 1 ;;
  esac
done

cd "$ROOT"
test -f "$ENTITLEMENTS"

AVAILABLE_SIGNING_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null)"
if [[ "$RELEASE_SIGN" -eq 1 ]]; then
  if [[ -z "${OVB_CODESIGN_IDENTITY:-}" ]]; then
    print -u2 "OVB_CODESIGN_IDENTITY must name a Developer ID Application identity for --release-sign"
    exit 1
  fi
  if [[ "$LOCAL_SIGNING_IDENTITY" != "Developer ID Application:"* ]]; then
    print -u2 "--release-sign requires a Developer ID Application identity"
    exit 1
  fi
  if ! rg -Fq "\"$LOCAL_SIGNING_IDENTITY\"" <<<"$AVAILABLE_SIGNING_IDENTITIES"; then
    print -u2 "Developer ID signing identity is not available in the current keychain"
    exit 1
  fi
fi

if [[ "$UNIVERSAL" -eq 1 ]]; then
  xcrun swift build -c "$CONFIGURATION" --triple arm64-apple-macosx11.0
  ARM64_BIN_DIR="$(xcrun swift build -c "$CONFIGURATION" --triple arm64-apple-macosx11.0 --show-bin-path)"
  xcrun swift build -c "$CONFIGURATION" --triple x86_64-apple-macosx11.0
  X86_64_BIN_DIR="$(xcrun swift build -c "$CONFIGURATION" --triple x86_64-apple-macosx11.0 --show-bin-path)"

  UNIVERSAL_BIN="$ROOT/.build/universal-$CONFIGURATION/$APP_NAME"
  mkdir -p "${UNIVERSAL_BIN:h}"
  lipo -create -output "$UNIVERSAL_BIN" \
    "$ARM64_BIN_DIR/$APP_NAME" \
    "$X86_64_BIN_DIR/$APP_NAME"
  BIN_PATH="$UNIVERSAL_BIN"
else
  xcrun swift build -c "$CONFIGURATION"
  BIN_PATH="$(xcrun swift build -c "$CONFIGURATION" --show-bin-path)/$APP_NAME"
fi

case "$APP_DIR" in
  "$ROOT/dist/"*.app) ;;
  *) print -u2 "refusing to clean unexpected app path: $APP_DIR"; exit 1 ;;
esac
rm -rf -- "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
ditto --norsrc --noextattr --noqtn --noacl \
  "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
strip -S -x "$APP_DIR/Contents/MacOS/$APP_NAME"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/LICENSE" "$APP_DIR/Contents/Resources/LICENSE"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/README.md" "$APP_DIR/Contents/Resources/README.md"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/COPYRIGHT" "$APP_DIR/Contents/Resources/COPYRIGHT"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/Resources/RC003-remote-photo.png" \
  "$APP_DIR/Contents/Resources/RC003-remote-photo.png"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/Resources/ARN9-remote-photo.png" \
  "$APP_DIR/Contents/Resources/ARN9-remote-photo.png"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/Resources/OpenVoiceBridge.icns" \
  "$APP_DIR/Contents/Resources/OpenVoiceBridge.icns"
ditto --norsrc --noextattr --noqtn --noacl \
  "$ROOT/device-profiles" \
  "$APP_DIR/Contents/Resources/device-profiles"
if [[ "$RELEASE_SIGN" -eq 1 ]]; then
  print "codesign identity: Developer ID Application (release)"
  codesign \
    --force \
    --deep \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    --timestamp \
    --sign "$LOCAL_SIGNING_IDENTITY" \
    "$APP_DIR"
elif rg -Fq "\"$LOCAL_SIGNING_IDENTITY\"" <<<"$AVAILABLE_SIGNING_IDENTITIES"; then
  print "codesign identity: $LOCAL_SIGNING_IDENTITY"
  codesign \
    --force \
    --deep \
    --entitlements "$ENTITLEMENTS" \
    --sign "$LOCAL_SIGNING_IDENTITY" \
    "$APP_DIR"
else
  print "codesign identity: ad-hoc fallback"
  codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"

EXPECTED_ENTITLEMENTS="$(plutil -convert xml1 -o - "$ENTITLEMENTS")"
SIGNED_ENTITLEMENTS="$(codesign -d --entitlements :- "$APP_DIR" 2>/dev/null)"
NORMALIZED_SIGNED_ENTITLEMENTS="$(plutil -convert xml1 -o - - <<<"$SIGNED_ENTITLEMENTS")"
if [[ "$NORMALIZED_SIGNED_ENTITLEMENTS" != "$EXPECTED_ENTITLEMENTS" ]]; then
  print -u2 "app signature entitlements differ from the reviewed entitlement allowlist"
  exit 1
fi

if [[ "$RELEASE_SIGN" -eq 1 ]]; then
  SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP_DIR" 2>&1)"
  if ! rg -q '^Authority=Developer ID Application:' <<<"$SIGNATURE_DETAILS"; then
    print -u2 "release signature is not a Developer ID Application signature"
    exit 1
  fi
  if ! rg -q '^CodeDirectory .*flags=.*\(runtime\)' <<<"$SIGNATURE_DETAILS"; then
    print -u2 "release signature is missing the hardened runtime flag"
    exit 1
  fi
  if ! rg -q '^Timestamp=' <<<"$SIGNATURE_DETAILS"; then
    print -u2 "release signature is missing a secure timestamp"
    exit 1
  fi
  if [[ "$(print -r -- "$SIGNATURE_DETAILS" | sed -n 's/^TeamIdentifier=//p' | head -n 1)" != "$EXPECTED_RELEASE_TEAM_ID" ]]; then
    print -u2 "release signature TeamIdentifier is not the reviewed project team"
    exit 1
  fi
  DESIGNATED_REQUIREMENT="$(codesign -dr - "$APP_DIR" 2>&1)"
  if ! rg -Fq "certificate leaf[subject.OU] = $EXPECTED_RELEASE_TEAM_ID" <<<"$DESIGNATED_REQUIREMENT"; then
    print -u2 "release signature designated requirement is not pinned to the reviewed project team"
    exit 1
  fi
fi

print "$APP_DIR"
