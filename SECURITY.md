# Security policy

HoldSpeak holds Microphone, Accessibility and Input Monitoring permissions, types text into other apps, and keeps Gemini and OpenAI API keys in the macOS Keychain. A bug in any of that can hurt users, so please report it privately.

## Supported versions

Only the [latest release](https://github.com/timmal/HoldSpeak/releases/latest) gets security fixes. Fixes ship as a new release, not as patches to older ones. If you're on an older version, update first and check the issue still happens.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: open the repository's **Security** tab and click **Report a vulnerability**. The report is visible only to you and the maintainer.

Please don't open a public issue, discussion or pull request for a vulnerability before it's fixed.

Examples of what to report this way:

- an API key leaving the Keychain — written to logs, preferences or history, or sent anywhere other than its provider
- audio or text sent somewhere the user didn't choose, e.g. to a cloud engine while a local model is selected
- text inserted into a password field, or into a different app than the focused one
- another app or process abusing HoldSpeak's permissions through it
- a malicious model download, update or terminology file making HoldSpeak run code or overwrite files

## What to include

- HoldSpeak version (Preferences → General shows "You're on v…") and macOS version
- the engine and model in use, if it matters
- what an attacker can do, and what they need first (local access, another installed app, a network position, a crafted file)
- steps to reproduce, or a proof of concept
- relevant lines from `~/Library/Logs/HoldSpeak.log` — remove anything private first

Never include a real API key, yours or anyone else's. If a key was exposed, revoke it with the provider first.

The maintainer replies in the report thread. Say there whether you'd like to be credited when the fix is released.

## Not a security issue?

Ordinary bugs — crashes, wrong transcriptions, a hotkey that doesn't fire, permissions macOS forgot after an update — are fine as [public issues](https://github.com/timmal/HoldSpeak/issues).
