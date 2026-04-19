#!/usr/bin/env bash
# Build a signed .app, package as DMG, create a GitHub release.
# Usage: ./scripts/release.sh 0.2.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>   e.g. $0 0.2.0"
  exit 1
fi
TAG="v$VERSION"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI not found. brew install gh"
  exit 1
fi

# Bump versions in project.yml
/usr/bin/sed -i '' "s/CFBundleShortVersionString: \".*\"/CFBundleShortVersionString: \"$VERSION\"/" project.yml
/usr/bin/sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml

xcodegen generate >/dev/null

pkill -x PushToTalk 2>/dev/null || true
chmod -R u+w build dist 2>/dev/null || true
rm -rf build dist 2>/dev/null || true
rm -rf build dist 2>/dev/null || true
mkdir -p build dist
xcodebuild -scheme PushToTalk -configuration Release \
  -derivedDataPath build clean build 2>&1 | tail -5

APP_SRC="build/Build/Products/Release/PushToTalk.app"
mkdir -p dist
cp -R "$APP_SRC" "dist/PushToTalk.app"

IDENTITY="PushToTalk Dev (self-signed)"
if security find-identity -v -p codesigning login.keychain-db 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --deep --sign "$IDENTITY" "dist/PushToTalk.app"
else
  codesign --force --deep --sign - "dist/PushToTalk.app"
fi

# Build DMG
STAGING="dist/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "dist/PushToTalk.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

DMG="dist/PushToTalk-$VERSION.dmg"
hdiutil create -volname "Push-to-Talk $VERSION" \
  -srcfolder "$STAGING" \
  -ov -format UDZO "$DMG"

rm -rf "$STAGING"

# Commit version bump
git add project.yml
git commit -m "release: $TAG" || true
git tag -a "$TAG" -m "Release $TAG"
git push origin main
git push origin "$TAG"

# GitHub release
gh release create "$TAG" "$DMG" \
  --title "Push-to-Talk $VERSION" \
  --generate-notes

echo
echo "Released $TAG"
echo "DMG: $DMG"

# Relaunch the installed app so the user isn't left without PushToTalk running
if [[ -d /Applications/PushToTalk.app ]]; then
  open /Applications/PushToTalk.app
fi
