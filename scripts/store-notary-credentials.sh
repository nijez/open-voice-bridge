#!/bin/zsh
set -euo pipefail

PROFILE_NAME="${1:-OpenVoiceBridge Notary}"

if [[ -z "$PROFILE_NAME" || "$PROFILE_NAME" == *$'\n'* ]]; then
  print -u2 "invalid keychain profile name"
  exit 1
fi

print "Apple notarization credentials will be stored in Keychain profile: $PROFILE_NAME"
print "The app-specific password will be requested by a secure hidden prompt."

read "APPLE_ACCOUNT?Apple Account email: "
read "DEVELOPER_TEAM_ID?Developer Team ID: "

if [[ -z "$APPLE_ACCOUNT" || "$APPLE_ACCOUNT" == *$'\n'* ]]; then
  print -u2 "invalid Apple Account"
  exit 1
fi
if [[ ! "$DEVELOPER_TEAM_ID" =~ '^[A-Z0-9]{10}$' ]]; then
  print -u2 "Developer Team ID must contain exactly 10 uppercase letters or digits"
  exit 1
fi

xcrun notarytool store-credentials "$PROFILE_NAME" \
  --apple-id "$APPLE_ACCOUNT" \
  --team-id "$DEVELOPER_TEAM_ID"
