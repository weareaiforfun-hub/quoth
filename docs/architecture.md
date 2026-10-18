# Architecture

Quoth is a native Swift app (AppKit + SwiftUI) with no third-party Swift dependencies. It's built with Swift Package Manager; Xcode isn't required. AI runs in two local servers that Quoth talks to over HTTP on `127.0.0.1`, or in a cloud API.

```
┌──────────────────────── Quoth.app ────────────────────────┐
│  HotkeyMonitor (CGEventTap) ──► DictationController          │
│  AudioRecorder (AVAudioEngine, 16 kHz) ─┘   │                │
│  ContextCapture (Accessibility) ────────────┤                │
│                                             ▼                │
│              QuothCore.DictationPipeline                  │
│                │                    │                        │
│                ▼                    ▼                        │
│   whisper-server (whisper.cpp)   Ollama /api/chat            │
│   speech → raw text              raw text → cleaned text     │
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
| `Cleanup/` | `LLMClient`/`Cleaner` protocols; `OllamaCleaner` (native `/api/chat`, keeps the model loaded) and `ChatCompletionsCleaner` (OpenAI-compatible); `CleanupPrompt` (system prompt + examples, `ListDetector`) |
| `Pipeline/` | `DictationPipeline`: audio → text → final string, plus `Continuation`, `Greeting`, `LanguageRules` |
| `PostProcess/` | Spoken punctuation, output sanitiser, whisper hallucination filter |
| `Personal/` | Dictionary/snippets/styles/transforms data (`PersonalData`), `TextRules` (replacements, snippets), `StyleRules`, `AutoLearn`, `DevFormatting` |
| `Command/` | Command Mode prompt + JSON parsing, Transforms prompts, `WordDiff` |
| `Notes/` | Scratchpad `NotesStore` with versions |
| `Meetings/` | Meeting store, voice-activity segmentation, transcript merge, summaries, cross-meeting search |
| `History/` | SQLite `HistoryStore` (system libsqlite3) and `Insights` |
| `Models/` | `ModelCatalog`, `ModelDownloader`, Ollama pull, `ModelBench` scoring |
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
   - *Prompt layout:* a static system prompt + few-shot examples (identical for every dictation, so Ollama reuses its prompt cache), then a per-dictation `<notes>` block (LIST, app, email, tone, variant, vocabulary, text before the cursor) and the `<transcript>`.
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
| whisper-server | `WhisperServerProcess` launches and keeps it warm (Metal), restarts it if it dies, reuses an existing one |
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
| `models/` | Whisper model files |
| `app-overrides.json` | Optional per-app paste overrides |
| `whisper-server.log` | Speech server log |

The cloud API key lives in the login Keychain (service `app.quoth`).
