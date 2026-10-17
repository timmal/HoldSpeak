#!/usr/bin/env bash
# Checks the app's Parakeet bridge end to end without launching HoldSpeak:
# builds a macOS 13 binary with the shared protocol, loads the framework from the
# Debug build and transcribes a clip.
#   scripts/asr-compare/bridge-smoke.sh [path/to/HoldSpeak.app] [clip id]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
app="${1:-$repo/build/Build/Products/Debug/HoldSpeak.app}"
clip="${2:-mixed-short}"
out="$here/.build/bridge-smoke"
mkdir -p "$here/.build"
swiftc -O -target arm64-apple-macos13.0 -o "$out" \
  "$repo/Sources/ParakeetShared/ParakeetEngineProtocol.swift" "$here/bridge-smoke/main.swift" 2>&1 \
  | grep -v "^$" || true
"$out" "$app" "$HOME/Library/Application Support/HoldSpeak/models/parakeet-ultra" "$here/audio/$clip.wav"
