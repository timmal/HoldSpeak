#!/usr/bin/env bash
# Builds the harness and runs each engine in its own process (clean memory numbers).
# Markdown tables land in results/<engine>.md.
#   scripts/asr-compare/run.sh                       # app default Whisper + Parakeet Ultra
#   scripts/asr-compare/run.sh whisper:openai_whisper-small parakeet:ru
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release 2>&1 | tail -1
engines=("$@")
[ ${#engines[@]} -gt 0 ] || engines=(whisper parakeet)
mkdir -p results
for e in "${engines[@]}"; do
  .build/release/asr-compare --engine "$e" --runs "${RUNS:-5}" --markdown "results/${e//[:\/]/_}.md"
done
