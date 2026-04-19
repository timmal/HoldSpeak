<p align="center">
  <img src="docs/screenshots/logo.webp" width="180" alt="Push-to-Talk logo" />
</p>

# Push-to-Talk

Local push-to-talk dictation for macOS. Hold the hotkey, speak, release — recognized text is inserted into the focused input. No cloud: Whisper runs on GPU via WhisperKit.

<p align="center">
  <img src="docs/screenshots/popover.webp?v=2" width="320" alt="Menu bar popover" />
</p>

## Features

- **Local transcription** through WhisperKit (CoreML, GPU)
- **Code-switching RU/EN/UK and more** — in auto mode the language is chosen only from the ones you have in System Settings → Language & Region
- **Insertion without clipboard** — via `CGEventKeyboardSetUnicodeString`; password fields are skipped
- **Menu bar popover** with the last 10 transcriptions (click to copy) and metrics: total words, 7-day avg WPM
- **HUD overlay** while you hold the key: black pill with a live mic level or a live transcript
- **Light text cleanup** — trims long "eeeeee / mmmmm / ummm", collapses 3+ consecutive repeats, capitalizes the first letter and adds a period
- **Terminology dictionary** — canonical IT terms (pull request, Kubernetes, Claude Code, …) replace misrecognized Russian transliterations in transcripts; ships with ~110 defaults and is fully editable

## Install

Grab the latest DMG from the [Releases page](https://github.com/timmal/push-to-talk/releases/latest), open it, and drag `PushToTalk.app` into `Applications`.

Because the app is self-signed, macOS will block the first launch. Open **System Settings → Privacy & Security**, scroll to the message *"PushToTalk was blocked…"* and click **Open Anyway**. Confirm with Touch ID / password. After that it launches normally from Launchpad / Applications.

On first launch, grant three permissions:

- **Microphone** — for audio capture
- **Accessibility** — for the global hotkey and text insertion
- **Input Monitoring** — to use Right Option / Right Cmd (or the hotkey you choose) as push-to-talk

The onboarding window has Open… and Re-check buttons.

### Updating

The app checks GitHub for new versions in the background and shows an **Update available** banner in the menu bar popover. You can also trigger a check manually via Preferences → General → **Check for updates**.

1. Click **Download** in the banner — it opens the latest release on GitHub.
2. Download the `.dmg`, open it, and drag `PushToTalk.app` into `Applications`. macOS will ask to replace the old copy — confirm.
3. Quit the running app from the menu bar (Quit), then launch the new one from `Applications`.

Your preferences, history, and downloaded models live in `~/Library/Application Support/PushToTalk/` and are preserved across updates.

### Model

The default is **Turbo (large-v3 distilled, ~800 MB)** — the best quality/speed trade-off. You can switch to Tiny or Small in Preferences → Audio.

If you already have MacWhisper / another WhisperKit client installed, their models will be picked up automatically. Otherwise the first model is downloaded to `~/Library/Application Support/PushToTalk/Models/`.

### Reducing insertion latency

The delay between releasing the hotkey and text appearing in the input is dominated by the Whisper forward pass. Two levers:

- **Pick a smaller model.** Preferences → Audio → *Whisper model*:
  - **Tiny (~40 MB)** — fastest (~80–150 ms on Apple Silicon for a short utterance), lowest quality. Good for quick English/single-language dictation.
  - **Small (~250 MB)** — middle ground.
  - **Turbo (~800 MB)** — default; best quality but ~400–800 ms per utterance.
- **Set a fixed language** instead of Auto. Preferences → Audio → *Primary language*: picking Russian or English skips an extra language-detection forward pass that Auto mode runs before transcription.

Combining **Tiny + explicit language** gives the lowest end-to-end latency. Combining **Turbo + Auto** gives the best quality but is the slowest path.

## Usage

1. Hold **Right Option** (or whatever you set in Preferences).
2. Speak. A HUD appears in the top right corner (or bottom center — configurable) showing the mic level.
3. Release the key. After ~1–2 s the text is inserted into the focused field.
4. If the field lost focus — open the menu bar icon: it shows the last 10 transcriptions; click to copy.

### Short taps

By default, presses shorter than **150 ms** don't start recording — the key behaves as a normal Option. The threshold is configurable in Preferences → General (50–800 ms).

## Preferences

- **General** — hotkey, hold threshold, HUD position (under the icon / bottom center), theme (Auto / Light / Dark), launch at login, update check
- **Audio** — language (Auto / Russian / English), Whisper model, Fast insert (streaming), model download
- **Terms** — terminology dictionary (see below)
- **History** — clear history and reset metrics
- **Support** — donation address (USDT TRC-20)

<p align="center">
  <img src="docs/screenshots/preferences-general.webp" width="560" alt="Preferences · General" />
  <br /><br />
  <img src="docs/screenshots/preferences-audio.webp" width="560" alt="Preferences · Audio" />
</p>

### Auto language detection

In Auto mode the app reads `Locale.preferredLanguages` from the system and restricts Whisper to those languages only. So if macOS has RU, EN, UK enabled, Whisper will pick among them and won't drift into, say, Bulgarian.

When two of your preferred languages score close in detection (e.g. a sentence mixes Russian with English terms), the app drops the forced language for that utterance and lets Whisper switch per-segment — this tends to preserve English terms verbatim instead of transliterating them.

### Terminology dictionary

Whisper reliably recognizes common speech but routinely mangles IT terminology in mixed RU+EN dictation (`пулл реквест` instead of `pull request`, `кубернетес` instead of `Kubernetes`, and so on). The **Terms** tab lets you map your spoken variants to a single canonical form, which is then substituted in the transcript before it's inserted.

> **Tip.** If Whisper keeps mangling the same word or name — a project codename, a library you use daily, a colleague's surname — stop fighting the model. Open **Preferences → Terms**, put the correct spelling in *Canonical*, and add the two or three variants Whisper tends to produce. Next time the word shows up it'll come out right without any hand-editing. That's the whole point of this feature: if you have to fix the transcript by hand every time, it's not dictation — it's a slower way to type. Teach the app once, save the corrections forever.

<p align="center">
  <img src="docs/screenshots/terminology-edit.webp" width="560" alt="Preferences · Terms — edit entry" />
</p>

**Default dictionary.** The app ships with ~110 curated IT entries spanning the whole dev cycle — VCS (pull request, rebase, cherry-pick), languages (TypeScript, Swift, Rust), frontend (React, Tailwind, Next.js), UX (wireframe, mockup, accessibility), backend (endpoint, middleware, migration), data (Postgres, Redis, ClickHouse), DevOps (Docker, Kubernetes, Helm chart), cloud (AWS, S3, Lambda), and AI tooling (Claude, MCP, Opus). On first launch the bundled list is copied to your Application Support directory — from then on the file is yours.

**How updates work.** App updates do **not** touch your dictionary — your edits, additions, and deletions persist verbatim. To pull in new entries from the latest bundled default, open Preferences → Terms and click **Load defaults…**:

- **Merge** — adds only canonical forms that aren't already in your list. Existing entries and your custom terms are untouched.
- **Replace** — discards your list entirely and reloads the bundled defaults. Use with care.

**Adding your own terms.** Click **Add term**, put the target form in *Canonical* (`webp`), and list the variants Whisper tends to produce in *Variants* (one per line: `Веб-пи`, `вебпп`, `вепп`, `Беппи`). Matching is case-insensitive by default and respects word boundaries, so `пулреквест` won't hit inside `пулреквестер`.

**Import / Export.** Pure JSON — commit it to a dotfiles repo, share with a team, seed a new machine.

**Storage.** `~/Library/Application Support/push-to-talk/terminology.json`.

## Architecture

- `Sources/Core` — pure logic (hotkey, recorder, inserter, text cleaner, storage, metrics, model manager)
- `Sources/Whisper` — thin wrapper around WhisperKit
- `Sources/UI` — SwiftUI: menu bar popover, preferences, onboarding, HUD
- `Sources/App` — AppDelegate and entry point

Transcription history is stored in a GRDB-SQLite database at `~/Library/Application Support/PushToTalk/history.sqlite`.

## Logs

Diagnostic events go to `~/Library/Logs/PushToTalk.log`. Useful for microphone / language detection / hotkey issues:

```bash
tail -f ~/Library/Logs/PushToTalk.log
```

## Troubleshooting

**Hotkey doesn't fire.** Check Input Monitoring and Accessibility in System Settings → Privacy & Security. When the signature changes (e.g. a fresh ad-hoc build) TCC may drop entries — delete and re-add, or run `scripts/setup-signing.sh` and rebuild.

**Recognizes silence / empty result.** Check the input level in System Settings → Sound → Input. In the logs, look at `finalize: rms=...` — normal speech is ≥ 0.02. If you see `0.0005` the mic is quiet (wrong device / muted / mic TCC not granted).

**Confuses Ukrainian / Russian with English in auto.** Auto relies on `Locale.preferredLanguages`. Make sure the language is actually listed in System Settings → Language & Region, or switch Preferences → Audio from Auto to an explicit Russian / English.

**TCC permissions reset on every rebuild.** You haven't run `scripts/setup-signing.sh` yet. It creates a persistent self-signed certificate in the login keychain. After that every rebuild is signed with the same key, and macOS treats it as the same app.

## License

MIT.
