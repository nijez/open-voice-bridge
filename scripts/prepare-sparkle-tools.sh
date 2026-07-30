#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="2.9.2"
EXPECTED_SHA256="b83e37436774556ed055e0244b297ef2c790e0737393bf65bf495fcbba6eed65"
URL="https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-for-Swift-Package-Manager.zip"
CACHE_ROOT="$ROOT/.build/sparkle-tools/$VERSION"
ARCHIVE="$CACHE_ROOT/Sparkle-for-Swift-Package-Manager.zip"
DESTINATION="${1:-}"

mkdir -p "$CACHE_ROOT"

if [[ -z "$DESTINATION" ]]; then
  DESTINATION="$(mktemp -d "$CACHE_ROOT/session.XXXXXX")"
elif [[ -e "$DESTINATION" ]]; then
  print -u2 "Sparkle tools destination must not already exist"
  exit 1
else
  mkdir -p "$DESTINATION"
fi

if [[ ! -f "$ARCHIVE" ]] || \
   [[ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" != "$EXPECTED_SHA256" ]]; then
  curl --fail --location --retry 3 --output "$ARCHIVE" "$URL"
fi

ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  print -u2 "Sparkle tools archive checksum mismatch"
  exit 1
fi

ditto -x -k "$ARCHIVE" "$DESTINATION"

typeset -A EXPECTED_TOOL_SHA256
EXPECTED_TOOL_SHA256[generate_appcast]="d70b1872fb6a859695f8abc0a403301d151d1c6c83cf427f4a2716c37a48983d"
EXPECTED_TOOL_SHA256[sign_update]="bfb52400c3da18bb4c251ac4818c2c2e1e31c2e649a45b31c11109b6e57b34ad"
EXPECTED_TOOL_SHA256[generate_keys]="2d18ed3a9c744e58150513d9b2e3c2eb76fd0b9621e3e4678d46dd972547e8fe"

for tool in generate_appcast sign_update generate_keys; do
  TOOL_PATH="$DESTINATION/bin/$tool"
  test -x "$TOOL_PATH"
  ACTUAL_TOOL_SHA256="$(shasum -a 256 "$TOOL_PATH" | awk '{print $1}')"
  if [[ "$ACTUAL_TOOL_SHA256" != "$EXPECTED_TOOL_SHA256[$tool]" ]]; then
    print -u2 "Sparkle tool checksum mismatch: $tool"
    exit 1
  fi
  codesign --verify --strict "$TOOL_PATH"
done

print -r -- "$DESTINATION/bin"
