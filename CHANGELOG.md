# Changelog

## 0.3.0 (2026-10-18)

### Changed
- The floating pill is now called **Earshot**, and mouse-button dictation is **Thumb Talk**.
- App ID `app.quoth`; data lives in `~/Library/Application Support/Quoth`.

## 0.2.1 (2026-10-16)

### Added
- **Features** tab: every feature, how to use it, and a button to its settings. It's the first thing you see in the Quoth window.

### Fixed
- "No text field" when dictating into Electron/Chromium apps (Claude, Slack, VS Code, Chrome…). Quoth now asks these apps to expose their text fields, and never refuses a paste just because Accessibility can't see the field (password fields are still refused).
- Meeting notes recorded an empty mic track: starting system-audio capture reconfigures audio, which stopped the mic. The mic now resumes into the same file (with a guard against reconfiguration loops).

### Changed
- New app icon: "Said." (two voice bars and a forest-green full stop).

## 0.2.0 (2026-10-16)

### Added
- **Models tab:** choose speech and language models per job (cleanup, commands & transforms, meetings), mix local and cloud, and download Whisper and Ollama models in the app.
- **Model Lab:** compare 2–3 models side by side on test sentences, test recordings and your own recent dictations, with scores, word error rates and timings.
- Quoth now lives in the **Dock** as well as the menu bar, with a new icon.
- `setup.sh` picks the language model by your Mac's memory.
- Full documentation in `docs/`, contribution guide, issue templates and CI.

### Fixed
- Long dictations no longer skip cleanup with "timed out": the timeout now grows with dictation length (a 250-word dictation needs ~12 s on a local 14B model).

### Changed
- Default cleanup model: Qwen 2.5 14B (more reliable on corrections and never answering dictated questions than 7B).
- `quoth-eval` and the Model Lab share one scoring implementation (`ModelBench`).

## 0.1.0 (2026-10-15)

- Core dictation: push-to-talk, hands-free, Earshot pill, paste anywhere with clipboard restore, local Whisper + Ollama cleanup, history.
- Personalisation: context awareness, styles, dictionary with auto-learn, snippets, languages and variants, whisper mode.
- Power features: Command Mode, Transforms, developer features, Thumb Talk, Scratchpad.
- Insights, meeting notes with cross-meeting Q&A, read-only MCP server.
