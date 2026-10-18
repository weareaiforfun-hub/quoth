# Privacy

**Short version:** with the default local setup, nothing you say or type leaves your Mac. Quoth has no accounts, no analytics and no telemetry.

## What Quoth reads

| What | When | Why |
| --- | --- | --- |
| Microphone audio | Only while you hold the hotkey, use hands-free, or take meeting notes | To transcribe |
| The focused text field (text near the cursor, selection), app name, window title | When you start dictating, if context awareness is on (Style tab) | To continue sentences, recognise code, pick the style |
| The field again, a few seconds after pasting | If auto-learn is on | To notice names you corrected |
| Computer audio | Only during meeting notes | To transcribe other participants |

It never reads password fields, and never reads password managers (1Password, Bitwarden, Keychain Access, Apple Passwords…). It never takes screenshots: meeting capture uses ScreenCaptureKit for audio only and discards video frames.

## What's stored, and where

Everything is in `~/Library/Application Support/Quoth/` on your Mac:

| Data | Kept |
| --- | --- |
| Dictation history (raw + cleaned text, app, timing) | Per Settings → Privacy: keep / 24 hours / never |
| Dictation audio | 14 days, 24 hours, or never |
| Insights | Counts only (words, seconds per day and per app), no text |
| Dictionary, snippets, styles, transforms | Until you delete them |
| Scratchpad notes | Until you delete them |
| Meetings | Audio 14 days; transcripts and notes until you delete them |
| Cloud API key | macOS Keychain |

Delete everything by quitting Quoth and removing that folder.

## What leaves your Mac

- **Local mode (default):** nothing. whisper.cpp and Ollama run on `127.0.0.1`.
- **Cloud mode** (your choice, per job): the audio and/or text for that job goes to the provider you configured, under their terms.
- **Model downloads** come from Hugging Face and the Ollama library.
- **Command Mode web search** opens Perplexity in your browser with your query.
- **MCP (optional):** apps you connect (e.g. Claude Desktop) can read your meeting notes and Scratchpad notes, never dictations. Turn it off in Settings → AI apps.

## Permissions

| Permission | Used for |
| --- | --- |
| Microphone | Recording while you dictate |
| Accessibility | Pasting, avoiding password fields, reading the focused field |
| Input Monitoring | Detecting the hotkey |
| Screen & System Audio Recording (optional) | Meeting notes only |

You can revoke any of them in System Settings → Privacy & Security.
