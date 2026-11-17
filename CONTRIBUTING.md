# Contributing to HoldSpeak

Thanks for wanting to help. This page covers what you need to build the app, what the tests do and don't check, and what makes a pull request easy to merge.

## What you need

- **Xcode 26 or newer.** The UI uses Liquid Glass APIs (`.glassEffect`, `.buttonStyle(.glass)`) behind `#available(macOS 26, *)`, so the project only compiles against the macOS 26 SDK or later. The app itself still runs on macOS 13.
- **XcodeGen** — the Xcode project isn't checked in, it's generated from `project.yml`:

  ```bash
  brew install xcodegen
  ```

- To run the app: a Mac with Apple Silicon, as for the release builds. The Parakeet engine is only offered on macOS 14+ on Apple Silicon.

## Build and test

```bash
swift test                 # Core logic tests
xcodegen generate          # writes HoldSpeak.xcodeproj from project.yml
mkdir -p HoldSpeak.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Xcode.resolved HoldSpeak.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
xcodebuild -project HoldSpeak.xcodeproj -scheme HoldSpeak -configuration Debug \
  -derivedDataPath ./build -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO build
```

The `cp` line and `-onlyUsePackageVersionsFromResolvedFile` pin the dependencies to the tracked `Xcode.resolved`, as CI and the scripts do: a lock file that no longer matches `project.yml` fails the build instead of being re-resolved. Copy it again after every `xcodegen generate`. The comment above the copy step in `scripts/release.sh` says how to bump a dependency.

Or open `HoldSpeak.xcodeproj` in Xcode after `xcodegen generate` and run the `HoldSpeak` scheme. Re-run `xcodegen generate` whenever you add, remove or rename files, or change `project.yml`. `Resources/Info.plist` and `Resources/HoldSpeak.entitlements` are written by XcodeGen from `project.yml` — change them there, not by hand.

**What `swift test` covers.** `Package.swift` builds only `Sources/Core` and `Sources/ObjCCatch` and runs the XCTest suite in `Tests/`. It does **not** compile `Sources/App`, `Sources/UI`, `Sources/Whisper`, `Sources/Parakeet` or `Sources/ParakeetShared` — those build only through the generated Xcode project. A change can pass `swift test` and still break the app, so run the `xcodebuild` line above too. CI runs both on every pull request (`.github/workflows/ci.yml`), unsigned. Under `swift test` the code logs to `HoldSpeak-tests.log` in the temporary directory, not to your `~/Library/Logs/HoldSpeak.log`.

**Dictated text in the log.** `~/Library/Logs/HoldSpeak.log` gets the length of each transcript, never its text, in Debug and Release builds alike. To see the text while you debug text handling, run `defaults write com.timmal.push-to-talk debugLogTranscripts -bool YES` and relaunch the app; turn it off with `defaults delete com.timmal.push-to-talk debugLogTranscripts`.

## Running your build: `scripts/rebuild.sh`

`scripts/rebuild.sh` is the maintainer's build-and-install loop. Know what it does before you run it:

- It quits a running HoldSpeak and **deletes `/Applications/HoldSpeak.app`**, replacing it with a fresh **Debug** build of your checkout.
- It then signs the app with the identity `HoldSpeak Dev (self-signed)` if that exists in your login keychain. The maintainer's copy of that identity exists only on the maintainer's machine. Without one, the script signs **ad hoc** — every build gets a new signature, and macOS forgets the app's Microphone, Accessibility and Input Monitoring permissions; you grant them again after each rebuild (if the hotkey stops working, remove HoldSpeak from the lists in System Settings → Privacy & Security and add it back). The Keychain also asks again before the new build can read a saved Gemini/OpenAI API key.

`scripts/setup-signing.sh`, run once per machine, creates your own `HoldSpeak Dev (self-signed)` certificate so the signature — and with it the permissions — survives rebuilds. It generates a self-signed code-signing certificate with `openssl`, imports it into your login keychain so any app may use its key without asking, and marks it as a trusted root for code signing. That is a change to your keychain's trust settings; delete the certificate in Keychain Access when you no longer need it. Your certificate is not the maintainer's, so switching between your build and an official release resets the permissions either way.

If you'd rather not touch `/Applications`, build with Xcode and run it from there.

## How the source is laid out

- `Sources/App` — entry point, `AppDelegate`, and `TranscriptionCoordinator` (finalize → clean → insert → save).
- `Sources/Core` — logic with no UI: hotkey monitor, audio recorder and input routing, silence trimming, text cleanup and insertion, history (GRDB), metrics, preferences, terminology, Keychain, request/response helpers for the Gemini and OpenAI APIs, update check. Everything `swift test` covers lives here.
- `Sources/UI` — SwiftUI and AppKit: menu bar popover, preferences, onboarding, HUD, design tokens.
- `Sources/Whisper` — transcription engines behind the `TranscriptionEngine` facade: WhisperKit (local), Gemini and OpenAI (cloud), model management, and the loader for the Parakeet framework.
- `Sources/Parakeet` — `HoldSpeakParakeet.framework`, the Parakeet engine on FluidAudio. It targets macOS 14, so the app embeds it and loads it at runtime instead of linking it.
- `Sources/ParakeetShared` — the Objective-C protocol compiled into both the app and the Parakeet framework so they can talk.
- `Sources/ObjCCatch` — a tiny Objective-C helper that turns `NSException`s into Swift errors.
- `Tests/` — XCTest suite for Core.
- `scripts/asr-compare` — developer-only harness comparing Whisper and Parakeet on WAV clips; not part of the app.

## A good pull request

- **One change per PR.** A bug fix and a refactor are two PRs.
- **Say what problem it solves.** Link an issue, or describe the problem in the PR: what you did, what happened, what you expected, macOS version and engine if it matters.
- **Say how you verified it.** `swift test` and the unsigned build are the minimum; for anything you can hear or see — hotkey, recording, insertion, HUD, preferences — say what you tried in the running app and on which macOS version.
- **Tests for Core logic.** If you change behaviour in `Sources/Core`, add or update a test in `Tests/`. Logic that's hard to test elsewhere often belongs in Core as plain data and pure functions (see `GeminiAPI.swift`, or `InsertionFacts` in `TextInserter.swift`).
- Keep user-facing text in the style of the existing UI, and update the README if you change what a user sees or does.

## Releases

Releases are cut by the maintainer: version bump, signed build, DMG and GitHub release. Don't bump versions in `project.yml` or add tags in your PR.

For the maintainer: `scripts/release.sh --build-only <version>` runs the same tests, Release build, signing with the hardened runtime and checks as a release, and leaves `dist/HoldSpeak.app` and `dist/HoldSpeak-<version>.dmg` to install and test by hand. It then reverts the version bump, and commits, tags, pushes and publishes nothing; it doesn't need `main` and leaves the installed app alone. It does need the `HoldSpeak Dev (self-signed)` identity and no uncommitted changes to tracked files.

## Security

Found a vulnerability? Don't open a public issue — see [SECURITY.md](SECURITY.md).
