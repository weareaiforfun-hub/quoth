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

## Download

<p align="center"><a href="https://github.com/weareaiforfun-hub/quoth/releases/latest/download/Quoth.dmg"><b>⬇ Download Quoth for Mac</b></a><br>
<sub>Free · Apple Silicon (M1 or later) · macOS 14 or later · <a href="https://github.com/weareaiforfun-hub/quoth/releases/latest">release notes</a></sub></p>

**New to this? Follow the [step-by-step install guide](docs/install.md).** In short:

1. Open the downloaded **Quoth.dmg** and drag **Quoth** onto **Applications**.
2. Open Quoth. macOS blocks it the first time: click **Done**.
3. Open **System Settings → Privacy & Security**, scroll down to **Security**, click **Open Anyway** next to "Quoth was blocked", and confirm with your password. You only do this once; updates open normally.
4. On the **Setup** page, download the AI models (the right size for your Mac is preselected) and grant the three permissions. Then hold **Fn** and talk.

**Why the extra step?** Apple charges developers a yearly fee (€99 every year) before macOS opens their apps without asking. To keep Quoth free without paying that fee, I publish it a different way: signed with the project's own certificate instead of Apple's. The code is open, and every update is signed and checked. [More in the install guide](docs/install.md#why-theres-one-extra-step).

**Memory:** 8 GB Macs get the Lite models; 16 GB, Standard; 32 GB or more, Best. **Disk:** 3–10 GB for the models. A cloud API works too, with your own key.

## Build from source

You need the Xcode Command Line Tools (`xcode-select --install`; full Xcode isn't needed) and Homebrew.

```bash
git clone https://github.com/weareaiforfun-hub/quoth.git && cd quoth
scripts/setup.sh              # installs cmake, downloads models sized to your Mac
scripts/build-app.sh --open   # builds the engines and the app, installs ~/Applications/Quoth.app
```

Then follow **[Getting started](docs/getting-started.md)**: grant three permissions, hold the hotkey, and talk.

## Documentation

| Guide | For |
| --- | --- |
| [Install](docs/install.md) | Everyone: download, the one-time "Open Anyway" step, setup, first dictation |
| [Getting started](docs/getting-started.md) | Building from source, permissions, troubleshooting |
| [User guide](docs/user-guide.md) | Every feature and shortcut |
| [Models](docs/models.md) | Which model does what, how to switch, how to compare |
| [Privacy](docs/privacy.md) | What's stored, what's read, what leaves your Mac |
| [Architecture](docs/architecture.md) | How it works inside |
| [Development](docs/development.md) | Building, testing, evals |
| [Status & roadmap](docs/status.md) | What's done, what's next, known limits |
| [Distribution](docs/distribution.md) | Options for a one-click download |
| [Releasing](docs/releasing.md) | Signing certificate, building and publishing a release |
| [Contributing](CONTRIBUTING.md) | How to help |

## License

[MIT](LICENSE). The models Quoth downloads have their own licences (Whisper: MIT; Qwen 2.5 7B/14B: Apache-2.0); see [docs/models.md](docs/models.md).
