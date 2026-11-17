#!/usr/bin/env bash
# Build a signed .app, package as DMG, create a GitHub release.
# Usage: ./scripts/release.sh 0.2.0
#        ./scripts/release.sh --build-only 0.2.0
#
# Flow: preflight (read-only; every abort happens before anything is changed)
#       -> swift test -> version bump -> Release build -> sign -> DMG
#       -> commit + tag -> push -> GitHub release -> relaunch the installed app.
#
# --build-only: the same tests, version bump, Release build, signing, signature
# checks and DMG, leaving dist/HoldSpeak.app and the DMG to install and test by
# hand. It then reverts the version bump. It does not need 'main', does not talk
# to origin, commits, tags, pushes or publishes nothing, and never quits, launches
# or replaces the installed HoldSpeak.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="HoldSpeak Dev (self-signed)"
INSTALLED_APP="/Applications/HoldSpeak.app"

die() {
  echo "release.sh: $*" >&2
  exit 1
}

usage() {
  echo "Usage: $0 <version>                e.g. $0 0.2.0"
  echo "       $0 --build-only <version>   build, sign and package only; publish nothing"
}

# ---------------------------------------------------------------------------
# Preflight. Nothing below this banner, up to "End of preflight", modifies a
# file, kills the app or changes anything on the remote.
# ---------------------------------------------------------------------------

BUILD_ONLY=0
if [[ "${1:-}" == "--build-only" ]]; then
  BUILD_ONLY=1
  shift
fi
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  usage
  exit 1
fi
# Also catches '<version> --build-only', which must not run a real release.
if (( $# > 1 )); then
  usage >&2
  die "unexpected arguments after the version: ${*:2}"
fi
VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
if [[ ! "$VERSION" =~ $VERSION_RE ]]; then
  die "version must look like 1.2.3, without a leading 'v' (got '$VERSION')."
fi
TAG="v$VERSION"

if (( ! BUILD_ONLY )) && ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI not found. brew install gh"
  exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  die "xcodegen not found. brew install xcodegen"
fi
if [[ ! -f Xcode.resolved ]]; then
  die "Xcode.resolved (the tracked dependency lock file) is missing from the repo root."
fi

if (( ! BUILD_ONLY )); then
  BRANCH="$(git symbolic-ref --short -q HEAD || true)"
  if [[ "$BRANCH" != "main" ]]; then
    die "releases are cut from 'main'; current branch is '${BRANCH:-detached HEAD}'."
  fi
fi

# Untracked files (.claude/, build leftovers) are fine; tracked edits are not.
# --build-only needs this too: it reverts the version bump with a checkout.
DIRTY="$(git status --porcelain --untracked-files=no)"
if [[ -n "$DIRTY" ]]; then
  echo "release.sh: tracked files have uncommitted or staged changes; commit or discard them first:" >&2
  echo "$DIRTY" >&2
  exit 1
fi

if (( ! BUILD_ONLY )); then
  CURRENT_VERSION="$(/usr/bin/sed -n 's/.*MARKETING_VERSION: "\(.*\)".*/\1/p' project.yml)"
  if [[ "$CURRENT_VERSION" == "$VERSION" ]]; then
    die "project.yml is already at $VERSION; there is no version bump to release."
  fi
fi

# An ad-hoc signature changes the app's designated requirement, so every user
# would lose their Microphone / Accessibility / Input Monitoring grants.
# (Output is captured first: `security | grep -q` can SIGPIPE under pipefail.)
IDENTITIES="$(security find-identity -v -p codesigning login.keychain-db 2>/dev/null || true)"
if ! grep -qF "$IDENTITY" <<<"$IDENTITIES"; then
  die "signing identity '$IDENTITY' not found in the login keychain. Run scripts/setup-signing.sh once, then retry. Refusing to publish an ad-hoc signed release: users would lose their Microphone / Accessibility / Input Monitoring grants."
fi

if (( BUILD_ONLY )); then
  # The build never touches the installed app, so a running HoldSpeak is fine —
  # unless it runs from this checkout's build/ or dist/, which the build deletes.
  for PID in $(pgrep -x HoldSpeak || true); do
    EXE="$(ps -o comm= -p "$PID" 2>/dev/null || true)"
    case "$EXE" in
      "$PWD"/build/* | "$PWD"/dist/*)
        die "HoldSpeak (pid $PID) is running from $EXE, which this build deletes; quit it first." ;;
    esac
  done
else
  if ! git fetch --quiet origin; then
    die "git fetch origin failed; cannot compare main and tags with origin."
  fi

  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    die "tag $TAG already exists locally."
  fi
  if ! REMOTE_TAG="$(git ls-remote --tags origin "refs/tags/$TAG")"; then
    die "could not list tags on origin."
  fi
  if [[ -n "$REMOTE_TAG" ]]; then
    die "tag $TAG already exists on origin."
  fi

  if ! git rev-parse -q --verify refs/remotes/origin/main >/dev/null; then
    die "origin/main not found after fetch."
  fi
  BEHIND="$(git rev-list --count HEAD..origin/main)"
  AHEAD="$(git rev-list --count origin/main..HEAD)"
  if (( BEHIND > 0 && AHEAD > 0 )); then
    die "local main has diverged from origin/main ($AHEAD ahead, $BEHIND behind). Reconcile them first."
  fi
  if (( BEHIND > 0 )); then
    die "local main is $BEHIND commit(s) behind origin/main. Run 'git pull --ff-only' first."
  fi
  if (( AHEAD > 0 )); then
    echo "Note: $AHEAD unpushed commit(s) on main will be pushed with this release."
  fi
fi

# ---------------------------------------------------------------------------
# End of preflight.
# ---------------------------------------------------------------------------

# Tests (SPM covers Sources/Core). Still nothing tracked has been modified.
echo "Running swift test..."
TEST_LOG="$(mktemp -t holdspeak-release-tests)"
if swift test >"$TEST_LOG" 2>&1; then
  # Print the XCTest total; the trailing swift-testing lines always say "0 tests".
  grep -E 'Executed [0-9]+ tests' "$TEST_LOG" | tail -n 1 || tail -n 3 "$TEST_LOG"
  rm -f "$TEST_LOG"
else
  { grep -E 'error:' "$TEST_LOG" | tail -n 20 || true; tail -n 5 "$TEST_LOG"; } >&2
  die "swift test failed; nothing was changed. Full log: $TEST_LOG"
fi

# From here on the script changes things. On failure: undo an uncommitted
# version bump (so the next run passes the clean-tree check) and bring the app
# back if we killed it. --build-only also undoes the bump on success.
STAGE="version bump"
BUMP_PENDING=0
RELEASE_COMMITTED=0
APP_KILLED=0

revert_bump() {
  git checkout -q HEAD -- project.yml Resources/Info.plist
}

on_exit() {
  local status=$?
  trap - EXIT
  if (( status == 0 )); then
    return
  fi
  echo >&2
  echo "release.sh: FAILED (exit $status) during: $STAGE" >&2
  if (( BUMP_PENDING )); then
    if revert_bump; then
      echo "release.sh: reverted the uncommitted version bump in project.yml and Resources/Info.plist." >&2
    else
      echo "release.sh: could not revert the version bump; run: git checkout HEAD -- project.yml Resources/Info.plist" >&2
    fi
  fi
  if (( RELEASE_COMMITTED )); then
    echo "release.sh: the commit 'release: $TAG' exists locally but $TAG is not fully published." >&2
    echo "release.sh: check 'git tag -l $TAG', 'git status -sb' and 'gh release view $TAG', then finish or undo by hand; a re-run will refuse." >&2
  fi
  if (( APP_KILLED )) && [[ -d "$INSTALLED_APP" ]]; then
    echo "release.sh: relaunching $INSTALLED_APP" >&2
    open "$INSTALLED_APP" || true
  fi
}
trap on_exit EXIT
# macOS bash 3.2 skips the EXIT trap when a signal kills the script; route
# Ctrl-C / TERM / HUP through a normal exit so on_exit still runs.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Bump versions in project.yml; xcodegen then rewrites Resources/Info.plist.
BUMP_PENDING=1
/usr/bin/sed -i '' "s/CFBundleShortVersionString: \".*\"/CFBundleShortVersionString: \"$VERSION\"/" project.yml
/usr/bin/sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml

xcodegen generate >/dev/null

# Dependency lock file. The Package.resolved that xcodebuild honours lives inside
# the generated, git-ignored HoldSpeak.xcodeproj, so the tracked copy is
# Xcode.resolved at the repo root; it is put in place after every xcodegen run and
# the build uses -onlyUsePackageVersionsFromResolvedFile, so a lock file that no
# longer matches project.yml fails the build instead of being silently re-resolved.
# To bump a dependency on purpose:
#   1. change the version in project.yml (packages:) and run `xcodegen generate`;
#   2. xcodebuild -resolvePackageDependencies -project HoldSpeak.xcodeproj -scheme HoldSpeak
#      (WITHOUT -onlyUsePackageVersionsFromResolvedFile);
#   3. cp HoldSpeak.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved Xcode.resolved
#   4. commit project.yml and Xcode.resolved together.
STAGE="dependency lock file"
mkdir -p HoldSpeak.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Xcode.resolved HoldSpeak.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

STAGE="build"
# Quit only so the end of a real release can relaunch the new install; the build
# itself does not need it. --build-only leaves the running app alone.
if (( ! BUILD_ONLY )) && pkill -x HoldSpeak 2>/dev/null; then
  APP_KILLED=1
fi
chmod -R u+w build dist 2>/dev/null || true
rm -rf build dist 2>/dev/null || true
rm -rf build dist 2>/dev/null || true
mkdir -p build dist
xcodebuild -scheme HoldSpeak -configuration Release \
  -derivedDataPath build -onlyUsePackageVersionsFromResolvedFile \
  clean build 2>&1 | tail -5

APP_SRC="build/Build/Products/Release/HoldSpeak.app"
mkdir -p dist
cp -R "$APP_SRC" "dist/HoldSpeak.app"

# No ad-hoc fallback: the identity was verified in the preflight.
# Hardened runtime + entitlements, signed inside-out rather than with --deep
# (deprecated for signing since macOS 13; codesign(1) applies all signing options
# to nested code). Nested code (HoldSpeakParakeet.framework, any dylib) gets the
# runtime flag but no entitlements; only the app's main executable carries them.
# The designated requirement (identifier + certificate leaf) is unchanged, so TCC
# grants survive.
STAGE="code signing"
APP="dist/HoldSpeak.app"
ENTITLEMENTS="Resources/HoldSpeak.entitlements"
NESTED_BUNDLES="$(find "$APP/Contents" -mindepth 1 \( -name '*.app' -o -name '*.appex' -o -name '*.xpc' -o -name '*.systemextension' \) -print)"
if [[ -n "$NESTED_BUNDLES" ]]; then
  die "nested executable bundle(s) found; give them their own signing step with their own entitlements: $NESTED_BUNDLES"
fi
# -depth lists children before their parents, i.e. inside-out.
while IFS= read -r -d '' NESTED; do
  codesign --force --options runtime --sign "$IDENTITY" "$NESTED"
done < <(find "$APP/Contents" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0)
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"

if ! codesign --verify --deep --strict --verbose=2 "$APP"; then
  die "codesign --verify --deep --strict failed on $APP"
fi
APP_ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"
if grep -q 'get-task-allow' <<<"$APP_ENTITLEMENTS"; then
  die "the release signature carries com.apple.security.get-task-allow"
fi
codesign -d -r- "$APP" 2>&1 | grep designated || true

# Build DMG
STAGE="DMG"
STAGING="dist/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "dist/HoldSpeak.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

DMG="dist/HoldSpeak-$VERSION.dmg"
hdiutil create -volname "HoldSpeak $VERSION" \
  -srcfolder "$STAGING" \
  -ov -format UDZO "$DMG"

rm -rf "$STAGING"

if (( BUILD_ONLY )); then
  STAGE="reverting the version bump"
  revert_bump
  BUMP_PENDING=0
  echo
  echo "Built HoldSpeak $VERSION (not released; the version bump is reverted)."
  echo "App: dist/HoldSpeak.app"
  echo "DMG: $DMG"
  codesign -d -vv "$APP" 2>&1 | grep 'flags=' || true
  echo
  echo "To install it by hand:"
  echo "  pkill -x HoldSpeak"
  echo "  rm -rf \"$INSTALLED_APP\" && cp -R \"$PWD/dist/HoldSpeak.app\" \"$INSTALLED_APP\""
  echo "  open \"$INSTALLED_APP\""
  exit 0
fi

# Commit version bump (project.yml and the Info.plist xcodegen regenerated from it)
STAGE="release commit"
git add project.yml Resources/Info.plist
git commit -m "release: $TAG"
BUMP_PENDING=0
RELEASE_COMMITTED=1

STAGE="tag"
git tag -a "$TAG" -m "Release $TAG"

STAGE="push"
git push origin main
git push origin "$TAG"

# GitHub release
STAGE="GitHub release"
gh release create "$TAG" "$DMG" \
  --title "HoldSpeak $VERSION" \
  --generate-notes
RELEASE_COMMITTED=0
STAGE="relaunch (the release itself is published)"

echo
echo "Released $TAG"
echo "DMG: $DMG"

# Relaunch the installed app so the user isn't left without HoldSpeak running
if [[ -d "$INSTALLED_APP" ]]; then
  open "$INSTALLED_APP"
fi
