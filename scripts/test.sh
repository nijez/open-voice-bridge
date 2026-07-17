#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="$ROOT/.build/self-test/XiaomiRemoteBridgeMacSelfTest"

mkdir -p "${OUTPUT:h}"
xcrun swiftc \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/ATVVProtocol.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/VoiceBridgeDeviceProfile.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/BluetoothLifecycle.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/RemoteButtons.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/AppSettings.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/VoiceFunctionKeyLatch.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/RemoteVoiceFunctionMapper.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/AppLogger.swift" \
  "$ROOT/Sources/XiaomiRemoteBridgeMac/TestTone.swift" \
  "$ROOT/Tests/SelfTest/main.swift" \
  -o "$OUTPUT"
"$OUTPUT"

python3 "$ROOT/scripts/validate-device-profiles.py"

xcrun swift build
