<p align="center"><img src="Sources/Quoth/Resources/AppIcon-1024.png" width="160" alt="Quoth icon"></p>

<h1 align="center">Quoth</h1>

<p align="center"><b>Talk instead of type, anywhere on your Mac. Private, free, open source.</b></p>

Hold a key, speak, let go: polished text appears in whatever app you're typing in. Quoth removes the "um"s, applies your corrections ("Tuesday, no, Wednesday"), formats lists and emails, spells your names right, and never answers a question you dictate. It's simply typed.

Everything runs **on your Mac** by default: OpenAI's open-source Whisper turns speech into text, and an open-weights language model (Qwen 2.5) cleans it up. No subscription, no account, and no audio leaves your computer. If you prefer speed over privacy, any OpenAI-compatible cloud API works with your own key.

Quoth is an independent open-source project and isn't affiliated with any commercial dictation product.

## Features

| | |
| --- | --- |
| **Dictation everywhere** | Push-to-talk or hands-free, in any text field. Your clipboard is restored after pasting. |
| **Smart cleanup** | Removes fillers, applies corrections, handles spoken punctuation, lists, emails, numbers. Three levels: None, Light, Medium. |
| **Personal** | Dictionary (learns from your corrections), snippets, per-app tone (Formal → Very casual), cursor context, ~100 languages. |
| **Command Mode** | Hold the hotkey + Control and say "make this shorter", "translate to Spanish", "reply that I'll be late", "what does this mean?" |
| **Transforms** | ⌥1 Polish, ⌥2 Prompt Engineer, ⌥3–9 your own rewrite prompts, ⌥O shows the diff. |
| **For developers** | "index dot ts" becomes `@index.ts` in Cursor/Windsurf; spoken identifiers match your code; terminal-safe pasting. |
| **Scratchpad** | ⌥S opens a floating notepad with version history. |
| **Meeting notes** | Records your mic and the call audio locally (no bot joins), then writes speaker-labelled transcripts, summaries, decisions and action items. You can ask questions across meetings. |
| **Insights** | Words per minute, time saved, streaks, a "Your Voice" profile. |
| **Models you choose** | Swap speech and language models per job, download them in-app, and compare them side by side in the Model Lab. |
| **AI-app access (MCP)** | Lets Claude and other MCP clients read your meeting and Scratchpad notes (read-only, never dictations). |

## Requirements

- A Mac with **Apple Silicon** (M1 or later) and **macOS 14 Sonoma** or later
- **Memory:** 16 GB works (7B model); 32 GB+ recommended for the default 14B model. 8 GB Macs can use the 3B model or a cloud API.
- **Disk:** about 1 GB for speech, plus 2–9 GB for the language model
- Homebrew and the Xcode Command Line Tools (`xcode-select --install`); full Xcode is not needed

## Quick start

```bash
git clone https://github.com/<you>/quoth.git && cd quoth
scripts/setup.sh              # installs whisper.cpp + Ollama, downloads models sized to your Mac
scripts/build-app.sh --open   # builds and installs ~/Applications/Quoth.app
```

Then follow **[Getting started](docs/getting-started.md)**: grant three permissions, hold the hotkey, and talk.

## Documentation

| Guide | For |
| --- | --- |
| [Getting started](docs/getting-started.md) | New users: installation, permissions, first dictation, troubleshooting |
| [User guide](docs/user-guide.md) | Every feature and shortcut |
| [Models](docs/models.md) | Which model does what, how to switch, how to compare |
| [Privacy](docs/privacy.md) | What's stored, what's read, what leaves your Mac |
| [Architecture](docs/architecture.md) | How it works inside |
| [Development](docs/development.md) | Building, testing, evals |
| [Status & roadmap](docs/status.md) | What's done, what's next, known limits |
| [Distribution](docs/distribution.md) | Options for a one-click download |
| [Contributing](CONTRIBUTING.md) | How to help |

## License

[MIT](LICENSE). The models Quoth downloads have their own licences (Whisper: MIT; Qwen 2.5 7B/14B: Apache-2.0); see [docs/models.md](docs/models.md).
