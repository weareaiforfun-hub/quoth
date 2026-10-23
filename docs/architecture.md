# Architecture

Quoth is a native Swift app (AppKit + SwiftUI) with no third-party Swift dependencies. It's built with Swift Package Manager; Xcode isn't required. AI runs in two local servers that ship inside Quoth.app and that Quoth talks to over HTTP on `127.0.0.1`, or in a cloud API. Ollama can replace the built-in language-model server.

```
┌──────────────────────── Quoth.app ────────────────────────┐
│  HotkeyMonitor (CGEventTap) ──► DictationController          │
│  AudioRecorder (AVAudioEngine, 16 kHz) ─┘   │                │
│  ContextCapture (Accessibility) ────────────┤                │
│                                             ▼                │
│              QuothCore.DictationPipeline                  │
│                │                    │                        │
│                ▼                    ▼                        │
│   whisper-server (whisper.cpp)   llama-server (llama.cpp)    │
│   speech → raw text              raw text → cleaned text     │
│                                  (or Ollama /api/chat)       │
│                │                    │                        │
│                └──── deterministic rules ────┘               │
│                             ▼                                │
│   TextInserter (clipboard + ⌘V, restore) ──► focused app     │
│   HistoryStore (SQLite) · Insights · AutoLearner             │
└──────────────────────────────────────────────────────────────┘
```

## Targets

| Target | What |
| --- | --- |
| `QuothCore` | All logic without UI: clients, prompts, rules, stores. Unit-tested. |
| `Quoth` | The menu-bar + Dock app: OS integration and the Hub UI. |
| `quoth-eval` | Command-line evaluation of models and prompts. |
| `quoth-mcp` | Read-only MCP server over stdio. |
| `QuothCoreTests` | Swift Testing suite. |

## QuothCore

| Folder | Contents |
| --- | --- |
| `ASR/` | `Transcriber` protocol; `WhisperServerTranscriber` (local) and `OpenAITranscriber` (cloud); WAV encoding and streaming writer |
| `Cleanup/` | `LLMClient`/`Cleaner` protocols; `OllamaCleaner` (native `/api/chat`, keeps the model loaded) and `ChatCompletionsCleaner` (OpenAI-compatible: the built-in llama-server via `LlamaServer`, and cloud APIs); `CleanupPrompt` (system prompt + examples, `ListDetector`) |
| `Pipeline/` | `DictationPipeline`: audio → text → final string, plus `Continuation`, `Greeting`, `LanguageRules` |
| `PostProcess/` | Spoken punctuation, output sanitiser, whisper hallucination filter |
| `Personal/` | Dictionary/snippets/styles/transforms data (`PersonalData`), `TextRules` (replacements, snippets), `StyleRules`, `AutoLearn`, `DevFormatting` |
| `Command/` | Command Mode prompt + JSON parsing, Transforms prompts, `WordDiff` |
| `Notes/` | Scratchpad `NotesStore` with versions |
| `Meetings/` | Meeting store, voice-activity segmentation, transcript merge, summaries, cross-meeting search |
| `History/` | SQLite `HistoryStore` (system libsqlite3) and `Insights` |
| `Models/` | `ModelCatalog` (Whisper and GGUF files with size + SHA-256, Ollama tags), `ModelBundle` (Lite/Standard/Best by memory), `ResumableDownloader` (Range resume, retries, SHA-256 check), Ollama pull, `ModelBench` scoring |
| `MCP/` | `MCPServer` (JSON-RPC 2.0) |
| `Settings/` | `Settings` (tolerant JSON decoding with migrations), paths, Keychain |

## The dictation pipeline

`DictationPipeline.run` → `process` → `cleanup`, in this order:

1. **Audio:** gain-normalise quiet recordings (whisper mode); encode a 16 kHz WAV.
2. **Language:** pinned, or detected and constrained to the user's set.
3. **Speech recognition**, with dictionary words and code identifiers as a vocabulary prompt.
4. **Filter** whisper's non-speech tags and silence hallucinations.
5. A **snippet spoken alone** short-circuits: its exact text is returned.
6. **Code editors:** spoken filenames ("index dot ts") and identifiers.
7. **Dictionary replacements** before the LLM, so the model sees the right spelling.
8. **Snippet triggers** are replaced by `[[S1]]` placeholders so the model can't paraphrase them.
9. **LLM cleanup** with a length-scaled timeout (base + 0.08 s/word locally).
   - *Prompt layout:* a static system prompt + few-shot examples (identical for every dictation, so llama-server and Ollama reuse their prompt cache), then a per-dictation `<notes>` block (LIST, app, email, tone, variant, vocabulary, text before the cursor) and the `<transcript>`.
   - *Output checks:* sanitise; repair list numbering; restore a dropped list lead-in; reject output that looks like an answer (much longer than the input); join greetings outside email; flatten lists nobody dictated.
   - *Any failure* → deterministic spoken-punctuation fallback.
10. **Dictionary replacements** again, then identifiers.
11. **Style rules** (period stripping, very-casual lowercase, formal final period).
12. **Continuation** with the text around the cursor.
13. **Language rules** (Swiss ß→ss, French spacing).
14. **Snippet expansion** (placeholders, then any remaining triggers).
15. **@file tagging** in Cursor/Windsurf, unless a dictionary entry or snippet fired.

Design rule: anything a small model does unreliably (lists, greetings, periods, snippets) is decided by code, and the model only gets clear instructions.

## The app

| Piece | How |
| --- | --- |
| Hotkeys | `CGEventTap` on flagsChanged/keyDown/otherMouse. Fn is keycode 63 with the `secondaryFn` flag. Work is dispatched off the tap callback so macOS never disables the tap. |
| Recording | `AVAudioEngine` input tap, converted to 16 kHz mono and streamed to disk (crash recovery); device ranking and fallback via CoreAudio |
| Earshot pill | Non-activating `NSPanel` at status-bar level, so it never steals focus |
| Context | `AXFocusedUIElement` (system-wide, then per app). Electron/Chromium apps get `AXManualAccessibility`/`AXEnhancedUserInterface` switched on so their text fields are visible. Value, selection and window title are read; secure fields and password managers are skipped |
| Insertion | Snapshot the pasteboard → write text (marked transient) → synthetic ⌘V → restore after 0.5–5 s per app (`AppOverrides`). Only a password field blocks pasting; if Accessibility can't see the field, it pastes anyway |
| Engines | `EngineProcess` launches `whisper-server` (port 8178) and `llama-server` (port 8179, one slot, 16k context, `--alias` = the GGUF file name) from `Contents/MacOS`, warms them up (Metal), restarts them if they die (gives up after three failed starts), stops them on quit or SIGTERM, and kills a server orphaned by a force-quit Quoth (pid files) |
| Updates | `Updater` wraps Sparkle 2: appcast attached to each GitHub release, EdDSA-signed DMGs, and Sparkle's check that the new app has the same code signature. Disabled in builds without `SUPublicEDKey` |
| Downloads | `DownloadCenter` queues model downloads app-wide (progress survives closing the Hub), and remembers a bundle chosen on the Setup page so it resumes after a restart |
| Meetings | `SystemAudioRecorder` (ScreenCaptureKit audio only) + a second disk-only `AudioRecorder`. After the call: per-track voice-activity regions → per-region transcription (accurate timestamps) → echo-aware merge → map-reduce summary |
| Hub (the Quoth window) | SwiftUI `NavigationSplitView` with tabs: Features, History, Insights, Meetings, Dictionary, Snippets, Style, Transforms, Models, Settings, Setup |
| Debug hooks | `DistributedNotificationCenter` hooks for automated testing, enabled only by a defaults flag (see [Development](development.md)) |

## Data on disk

`~/Library/Application Support/Quoth/`:

| Path | Contents |
| --- | --- |
| `settings.json` | App settings |
| `personal.json` | Dictionary, snippets, styles, transforms |
| `history.sqlite` | `dictations`, plus `stats_daily`/`stats_apps` (counts only) |
| `audio/*.wav` | Dictation audio (retention per Settings) |
| `notes/` | `index.json`, `<id>.rtf`, `<id>.txt`, `versions/` |
| `meetings/<id>/` | `meta.json`, `me.wav`, `others.wav`, `transcript.json`, `summary.md` |
| `models/` | Whisper (`.bin`) and language model (`.gguf`) files |
| `app-overrides.json` | Optional per-app paste overrides |
| `whisper-server.log`, `llama-server.log` | Engine logs (rewritten at each start) |
| `whisper-server.pid`, `llama-server.pid` | The running engines, so a later launch can stop orphans |

The cloud API key lives in the login Keychain (service `app.quoth`).
