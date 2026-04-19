# Push-to-Talk

Локальная push-to-talk диктовка для macOS. Зажал хоткей → говоришь → отпустил → распознанный текст вставляется в активный инпут. Никаких облаков: Whisper крутится на GPU через WhisperKit.

## Фичи

- **Push-to-talk** на Right Option или Right Cmd (настраивается)
- **Локальная транскрипция** через WhisperKit (CoreML, GPU)
- **Код-свитч RU/EN/UK** и другие — в auto-режиме язык выбирается только из тех, что стоят в System Settings → Language & Region
- **Вставка без буфера обмена** — через CGEventKeyboardSetUnicodeString, скипает поля с паролями
- **Menu bar popover** с последними 10 транскрипциями (копируются кликом) и метриками: всего слов, WPM за 7 дней
- **HUD-оверлей** пока держишь кнопку: чёрная пилюля с живым уровнем микрофона или live-transcript
- **Лёгкая чистка текста** — убирает протяжные «эээээ/ммммм/ummm» и 3+ повторы подряд, ставит заглавную и точку

## Установка

### Из исходников (рекомендуется)

Требуется Xcode (CLI Tools недостаточно) и [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
git clone https://github.com/timmal/push-to-talk.git
cd push-to-talk
brew install xcodegen
./scripts/setup-signing.sh    # один раз — создаёт self-signed cert, чтобы TCC-права не сбрасывались при каждой пересборке
./scripts/rebuild.sh          # собирает и ставит в /Applications
```

При первом запуске выдай три разрешения:

- **Microphone** — для захвата звука
- **Accessibility** — для глобального хоткея и вставки текста
- **Input Monitoring** — для Right Option / Right Cmd как push-to-talk

В онбординге есть кнопки Open… и Re-check.

### Модель

По умолчанию грузится **Turbo (large-v3 distilled, ~800 MB)** — лучший баланс качества и скорости. В Preferences → Audio можно выбрать Tiny или Small.

Если у тебя уже стоит MacWhisper / другой WhisperKit-клиент — модели из их папки подхватятся автоматически. Если нет — первая модель скачается в `~/Library/Application Support/PushToTalk/Models/`.

## Использование

1. Зажми **Right Option** (или то, что выбрал в Preferences).
2. Говори. В правом верхнем углу (или внизу по центру — настраивается) появится HUD с уровнем сигнала.
3. Отпусти кнопку. Через ~1–2 сек текст вставится в активное поле.
4. Если поле потеряло фокус — открой иконку в menu bar: там последние 10 транскрипций, кликом копируются в буфер.

### Короткие нажатия

По умолчанию нажатия короче **150 мс** не запускают запись — кнопка работает как обычный Option. Порог настраивается в Preferences → General (50–800 мс).

## Preferences

- **General** — хоткей, hold threshold, режим HUD (waveform / live transcript), позиция HUD (под иконкой / внизу по центру), launch at login
- **Audio** — язык (Auto / Russian / English), модель Whisper, скачивание
- **History** — очистить историю и метрики

### Auto-detect языка

В режиме Auto приложение читает `Locale.preferredLanguages` из системы и ограничивает Whisper только этими языками. Т.е. если в macOS стоят RU, EN, UK — Whisper выберет между ними и не уйдёт, например, в болгарский.

## Архитектура

- `Sources/Core` — чистая логика (хоткей, рекордер, кликер, чистка текста, хранилище, метрики, модели)
- `Sources/Whisper` — обёртка над WhisperKit
- `Sources/UI` — SwiftUI: menu bar popover, preferences, onboarding, HUD
- `Sources/App` — AppDelegate и точка входа

История транскрипций хранится в GRDB-SQLite базе в `~/Library/Application Support/PushToTalk/history.sqlite`.

## Логи

Диагностические события пишутся в `~/Library/Logs/PushToTalk.log`. Полезно при проблемах с микрофоном, детекцией языка или хоткеем:

```bash
tail -f ~/Library/Logs/PushToTalk.log
```

## Траблшутинг

**Хоткей не срабатывает.** Проверь Input Monitoring и Accessibility в System Settings → Privacy & Security. При смене подписи (новая ad-hoc сборка) TCC может сбросить записи — удали и добавь заново, либо запусти `scripts/setup-signing.sh` и пересобери.

**Распознаёт тишину / пусто.** Проверь входной уровень: System Settings → Sound → Input. В логах смотри `finalize: rms=...` — нормальная речь ≥ 0.02. Если 0.0005 — микрофон молчит (не тот девайс / выключен / TCC mic не дан).

**Путает украинский/русский с английским в auto.** Auto опирается на `Locale.preferredLanguages`. Убедись, что нужный язык реально добавлен в System Settings → Language & Region, либо переключи в Preferences → Audio с Auto на Russian / English явно.

**TCC-права сбрасываются каждую пересборку.** Значит ты ещё не запускал `scripts/setup-signing.sh` — там создаётся постоянный self-signed сертификат в login keychain. После этого любая пересборка подписывается одним и тем же ключом, и macOS считает это тем же приложением.

## Лицензия

MIT.
