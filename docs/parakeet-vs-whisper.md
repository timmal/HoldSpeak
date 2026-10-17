# Parakeet Ultra vs Whisper (HS-8)

Measured 2026-10-18 on an M2 Max (64 GB), macOS 27.0.1, with `scripts/asr-compare`.
FluidAudio 0.17.7 (Parakeet Ultra, Core ML on the Neural Engine) vs WhisperKit 0.18.0
(the versions the app builds with).

**Caveat: the audio is synthetic.** Every clip was spoken by macOS `say` (Milena for
Russian and mixed, Samantha for English). TTS is clean, evenly paced and has no room
noise, accents or hesitations, so absolute error rates say little about real
dictation. Latency, load time, memory and the *relative* behaviour on IT terms are the
useful parts. Repeat with real recordings before drawing quality conclusions.

## Summary

| | Whisper Turbo (app default) | Whisper Small | Parakeet Ultra |
|---|---:|---:|---:|
| Latency, ~4 s clip (median) | 2.47–2.60 s | 0.38–0.54 s | **0.06–0.07 s** |
| Latency, ~18 s clip (median) | 3.1–3.4 s | 1.0–1.4 s | **0.17–0.18 s** |
| Mean WER, 6 clips | 12.3 % | 12.3 % | **10.3 %** |
| Model on disk | 1545 MB | 479 MB | 613 MB |
| Load, compile cache warm | 0.31 s | 0.38 s | 0.12 s |
| Load, first time for this binary / model copy | 5.6 s | — | 12.4–12.7 s |
| Process memory peak (footprint / resident) | 137 / 1452 MB | 118 / 149 MB | 71 / 121 MB |

- **Parakeet is ~15–40× faster than the app's default Whisper Turbo** and 5–8× faster
  than Whisper Small. A 4 s dictation is ready in ~60 ms after release; Turbo needs
  ~2.5 s regardless of length (it encodes a full 30 s window twice: language
  detection, then decoding). The app's own log shows the same Turbo figure for real
  dictations (2.56 s for 2.97 s of speech, 2026-10-14).
- **Quality is on par on plain Russian and English** (all engines 0 % on the long
  clips; the 8 % on `en-short` is "10 o'clock" vs "ten o'clock", the same for every
  engine). Parakeet capitalises and punctuates on its own; on `en-long` it joined
  sentences with commas where Whisper put periods.
- **Mixed RU+EN (IT terms) is slightly better with Parakeet but imperfect everywhere.**
  Parakeet kept `pull`, `main`, `Merge`, `GitHub Actions`, `Kubernetes Cluster` in Latin
  but wrote `реквест`, `деплей` and mangled `Kubernetes` on the short clip
  (`Qbernicts`). Whisper Turbo wrote `пул реквест`, `куберниц`, `Graphene`. HoldSpeak's
  terminology list still runs after either engine and can fix recurring terms.
- **Load:** Core ML compiles Parakeet's encoder for the Neural Engine once per
  executable (~12 s, measured again for each new binary and for a fresh copy of the
  model). The app loads the model when Parakeet is selected and at launch, so this is
  felt only by a dictation started within ~12 s of the first launch after an
  install/update. Afterwards loads take ~0.15 s.
- **Memory:** process footprint/resident numbers don't include what the Neural Engine
  driver holds, so they understate both engines; the resident peak for Turbo is
  dominated by its memory-mapped 1.5 GB weights.

## FluidAudio's language hint (`language:`) — don't use it

`AsrManager.transcribe(_:decoderState:language:)` takes a language, but for Parakeet it
is only a *script filter*: tokens outside that alphabet are dropped. With `ru` forced:

| Clip | Parakeet (auto) | Parakeet with `language: .russian` |
|---|---|---|
| en-short | Please schedule the review meeting for tomorrow morning at 10 o'clock. | `...t'a 200-40-10.` |
| en-long | (correct, 0 % WER) | `.20-гото, ... ...-то 10-4-2-2, …` (100 % WER) |
| mixed-long | … pull реквест … GitHub Actions в Kubernetes Cluster … | … пул реквест … Гихаб Акшн в Кубернекс кластер … |

Mean WER 10.3 % → 45.4 %. So the app never passes a hint: Parakeet always detects the
language itself, and the "Primary language" setting only picks the Terms list
(Preferences says so when Parakeet is selected).

## Per-clip results (median of 5 runs, after one warm-up run)

| Clip | Audio | Whisper Turbo | Whisper Small | Parakeet Ultra |
|---|---:|---:|---:|---:|
| ru-short | 4.1 s | 2474 ms · 0 % | 400 ms · 0 % | 60 ms · 0 % |
| ru-long | 19.0 s | 3435 ms · 0 % | 1376 ms · 0 % | 182 ms · 0 % |
| en-short | 3.6 s | 2544 ms · 8 % | 378 ms · 8 % | 58 ms · 8 % |
| en-long | 18.8 s | 3128 ms · 0 % | 1033 ms · 0 % | 169 ms · 0 % |
| mixed-short | 4.1 s | 2596 ms · 40 % | 538 ms · 40 % | 69 ms · 30 % |
| mixed-long | 17.7 s | 3418 ms · 26 % | 1383 ms · 26 % | 173 ms · 23 % |

Latency = time from having the whole recording to having text (everything is already
recorded, so this is what the user waits after releasing the hotkey, minus VAD and
insertion). The first run of each clip was at most slightly slower (Parakeet up to +15 ms,
Turbo up to +0.15 s), except Turbo's first `en-long` (4.8 s).

WER: word error rate against the text `say` read, after lowercasing, ё→е and dropping
punctuation; hyphenated words count as one.

### Mixed clips, verbatim

Reference `mixed-short`: *Сделай pull request, и после ревью запустим деплой в Kubernetes.*

- Turbo: Сделай пул реквест, и после ревью запустим деплай в куберниц.
- Small: Сделай пул реквест, и после ревью запустим деплей в кюберниц.
- Parakeet: Сделай pull реквест и после ревью запустим деплей в Qbernicts.

Reference `mixed-long`: *Я открыл pull request с исправлением, ревьюер оставил пару
комментариев. После мержа в main запускаем деплой через GitHub Actions в Kubernetes
кластер, потом проверяем логи в Grafana и, если что-то пошло не так, делаем rollback на
прошлый релиз. Хотфикс пушим отдельной веткой.*

- Turbo: Я открыл пул реквест с исправлением, ревью и расставил пару комментариев. После мержи в main запускаем депло через GitHub Actions в Kubernetes Cluster, потом проверяем логи в Graphene, если что-то пошло не так, делаем роллбэк на прошлый релиз, хотфикс пушим отдельной веткой.
- Small: Я открыл pull request с исправлением, ревью и расставил пару комментариев. После мержи в мейн запускаем деплой через github actions в Qubernitz Cluster, потом проверяем логи в графене. Если что-то пошло не так, делаем rollback на прошлый релиз, ход фикс пушим отдельной веткой.
- Parakeet: Я открыл pull реквест с исправлением, ревью и расставил пару комментариев. После Merge в main запускаем деплой через GitHub Actions в Kubernetes Cluster, потом проверяем логи в графоне. Если что-то пошло не так, делаем роллбэк на прошлый релиз. Входфикс пушим отдельной веткой

All three hear "ревьюер оставил" as "ревью и расставил" — most likely the TTS voice, not
the engines.

## Disk sizes

Parakeet Ultra: 613 MB in `~/Library/Application Support/HoldSpeak/models/parakeet-ultra`
(FluidAudio's folder name for the HF repo `FluidInference/parakeet-ultra-coreml`).
Whisper Turbo: 1545 MB (the copy MacWhisper downloaded, which HoldSpeak reuses) —
noticeably more than the "~800 MB" in the app's model label; Whisper Small: 479 MB
(label says ~250 MB).

## How Parakeet is wired into the app

- New local engine `parakeet` with model `ParakeetModelID.ultra`; the Audio tab's Model
  dropdown has a "Parakeet — on this Mac, free" section. Download / status / "Delete…"
  work like Whisper's (the model goes to HoldSpeak's own `models/` folder; a copy in
  `~/Library/Application Support/FluidAudio/Models` from another FluidAudio app is reused).
- Engine fallback: cloud engines fall back to the local engine picked last (Whisper or
  Parakeet); the HUD names it.
- Text cleanup: terminology, auto punctuation/capitalisation and the filler list apply;
  the Whisper hallucination list (subtitle boilerplate) does not. The language for
  terminology and history is guessed from the transcript's alphabet.
- **macOS 14 gating:** FluidAudio requires macOS 14; the app targets 13, and Swift
  refuses to import a module built for a newer OS. So FluidAudio lives in
  `HoldSpeakParakeet.framework` (deployment target 14), embedded but not linked; on
  macOS 14+ on Apple Silicon the app loads it at runtime and talks to it through an
  `@objc` protocol (`Sources/ParakeetShared`). On macOS 13 or Intel, Parakeet is hidden.
  The framework adds ~20 MB to the app bundle (Release).

## Re-running

```bash
scripts/asr-compare/make-audio.sh        # regenerate the clips from clips.tsv (optional)
scripts/asr-compare/run.sh               # app default Whisper + Parakeet, one process each
scripts/asr-compare/run.sh whisper:openai_whisper-small parakeet:ru   # other variants
scripts/asr-compare/bridge-smoke.sh      # app's Parakeet bridge, from the Debug build
```

Tables land in `scripts/asr-compare/results/` (git-ignored). Parakeet downloads into
HoldSpeak's models folder if missing (~40 s); Whisper models are taken from where the
app finds them, otherwise downloaded into `scripts/asr-compare/.cache`. `--whisper-dir`
/ `--parakeet-dir` point at a fresh copy of a model to measure a cold load.
