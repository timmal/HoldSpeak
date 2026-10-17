#!/usr/bin/env bash
# Regenerates the synthetic test clips from clips.tsv with macOS `say`
# (16 kHz mono 16-bit WAV, the format HoldSpeak records in).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p audio
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
grep -v '^#' clips.tsv | while IFS=$'\t' read -r id voice text; do
  [ -n "$id" ] || continue
  say -v "$voice" -o "$tmp/$id.aiff" "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$tmp/$id.aiff" "audio/$id.wav"
  printf '%-12s %5.1f s\n' "$id" "$(afinfo "audio/$id.wav" | awk '/estimated duration/ {print $3}')"
done
