#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Ensure xcodeproj is up to date
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate >/dev/null
fi

# Tracked dependency lock file (see the comment in scripts/release.sh on how to bump).
mkdir -p HoldSpeak.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Xcode.resolved HoldSpeak.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

# Kill running instance
pkill -x HoldSpeak 2>/dev/null || true

# Build
xcodebuild -scheme HoldSpeak -configuration Debug \
  -derivedDataPath build -onlyUsePackageVersionsFromResolvedFile \
  clean build 2>&1 | tail -5

APP_SRC="build/Build/Products/Debug/HoldSpeak.app"
APP_DST="/Applications/HoldSpeak.app"

rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

# Sign with persistent self-signed identity so TCC grants survive rebuilds.
# Falls back to ad-hoc if the cert isn't installed.
IDENTITY="HoldSpeak Dev (self-signed)"
if security find-identity -v -p codesigning login.keychain-db 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --deep --sign "$IDENTITY" "$APP_DST"
else
  echo "Note: run scripts/setup-signing.sh once for persistent TCC grants."
  codesign --force --deep --sign - "$APP_DST"
fi

echo "Installed to $APP_DST"
open "$APP_DST"
