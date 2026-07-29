#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT_DIR="$ROOT/dist"
DISPLAY_NAME="小米遥控器桥接"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
DMG="$OUTPUT_DIR/$DISPLAY_NAME-$VERSION.dmg"
PROFILE_NAME="${OVB_NOTARY_KEYCHAIN_PROFILE:-}"
DMG_WAS_SET=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --keychain-profile)
      shift
      if [[ "$#" -eq 0 ]]; then
        print -u2 "--keychain-profile requires a value"
        exit 1
      fi
      PROFILE_NAME="$1"
      ;;
    --*) print -u2 "unknown argument: $1"; exit 1 ;;
    *)
      if [[ "$DMG_WAS_SET" -eq 1 ]]; then
        print -u2 "only one DMG path may be supplied"
        exit 1
      fi
      DMG="$1"
      DMG_WAS_SET=1
      ;;
  esac
  shift
done

if [[ -z "$PROFILE_NAME" ]]; then
  print -u2 "provide --keychain-profile or OVB_NOTARY_KEYCHAIN_PROFILE"
  exit 1
fi
if [[ "$PROFILE_NAME" == *$'\n'* ]]; then
  print -u2 "invalid keychain profile name"
  exit 1
fi
test -f "$DMG"

"$ROOT/scripts/verify-dmg.sh" --require-developer-id "$DMG"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$PROFILE_NAME" \
  --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

(
  cd "${DMG:h}"
  shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256"
)

"$ROOT/scripts/verify-dmg.sh" --require-notarized "$DMG"
print "NOTARIZED DMG: $DMG"
print "SHA256: $DMG.sha256"
