# Getting started

**Just want to use Quoth?** Follow the [install guide](install.md) instead: download, open, done. No Terminal needed.

This guide is for building Quoth from source. It takes you from nothing to your first dictation in about 15 minutes, most of it waiting for downloads.

## 1. Check your Mac

- Apple Silicon (Apple menu → About This Mac → Chip says "Apple M…")
- macOS 14 or later
- At least 16 GB of memory for the local models (8 GB works with a small model or a cloud API)
- About 10 GB of free disk space

## 2. Install the tools

Open Terminal and install the Xcode Command Line Tools if you don't have them:

```bash
xcode-select --install
```

Install [Homebrew](https://brew.sh) if you don't have it, then get Quoth:

```bash
git clone https://github.com/weareaiforfun-hub/quoth.git
cd quoth
scripts/setup.sh
```

`setup.sh` does four things:

1. Installs **cmake** with Homebrew, used to build the two engines (whisper.cpp for speech, llama.cpp for text) that ship inside the app. Nothing else needs to run alongside Quoth.
2. Downloads the **Whisper Large v3 Turbo** speech model (575 MB).
3. Downloads a language model sized to your memory and checks its SHA-256: **Qwen 2.5 14B** (9 GB) on 32 GB+ Macs, **Qwen 2.5 7B** (4.7 GB) on 16 GB, **Qwen 3 4B** (2.5 GB) below that. You can switch later in Quoth → Models.
4. Creates a local code-signing certificate called "Quoth Dev", so macOS remembers the app's permissions every time you rebuild it.

## 3. Build and open the app

```bash
scripts/build-app.sh --open
```

The first time, macOS asks whether `codesign` may use the "Quoth Dev" key. Click **Always Allow** (if it asks for a password, it's your Mac login password). Quoth installs to `~/Applications` and appears in your Dock and menu bar.

## 4. Grant permissions

Quoth opens on the **Setup** page. First, under **AI models**, pick a bundle (the one sized to your Mac is marked) and click **Download**; it runs while you do the rest, can be paused, and continues after a restart. (If you ran `setup.sh`, the models are already there.) Then grant each permission; the page updates by itself.

| Permission | Why |
| --- | --- |
| **Microphone** | To hear you while you hold the hotkey. |
| **Accessibility** | To paste text into other apps, to avoid password fields, and to read the text around your cursor. |
| **Input Monitoring** | To notice when you press the hotkey. |
| Screen & System Audio Recording *(optional)* | Only for meeting notes: records what the other participants say. No video is kept. |

If you keep the default **Fn (🌐)** hotkey, also set System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing**, otherwise macOS opens the emoji picker. On a Mac without Fn, pick **Right Option** in Quoth → Settings.

## 5. Your first dictation

1. Click into any text field: Notes, Mail, Slack, a browser.
2. **Hold** the hotkey and say: *"Um, so let's meet at two, actually three, on Thursday."*
3. **Let go.** About a second later you'll see: *So let's meet at 3 on Thursday.*

The pill at the bottom of the screen (the **Earshot pill**) shows a waveform while you speak and dots while Quoth thinks.

Next things to try:

- **Double-tap** the hotkey to dictate hands-free; tap once more to stop.
- Say *"one… two… three…"* to get a numbered list.
- Select some text, hold **hotkey + Control**, and say *"make this more formal"*.
- Press **⌃⌘V** to paste your last dictation again.

The [User guide](user-guide.md) covers everything else.

## 6. Make it yours

- **Settings → Languages:** pick the language(s) you speak. Pinning one language makes speech recognition about 0.5 s faster.
- **Dictionary:** add names and jargon. When you correct a misheard name right after dictating, Quoth learns it.
- **Style:** choose how casual your messages, work chat and emails should look.
- **Models:** switch to a faster or smarter model, and compare them in the Model Lab ([Models guide](models.md)).

## Troubleshooting

| Problem | Fix |
| --- | --- |
| Nothing happens when I hold the key | Check Accessibility and Input Monitoring in the Setup page. Rebuilt the app? Click **Always Allow** on the codesign prompt; otherwise permissions reset. |
| The emoji picker opens | Set "Press 🌐 key to" → Do Nothing, or switch the hotkey to Right Option. |
| "Speech model: model missing" in the menu | Run `scripts/setup.sh` again, or download a model in Quoth → Models. |
| Text appears but isn't cleaned up ("cleanup skipped") | The language model isn't downloaded or is still loading (Quoth → Models shows its status; details in `llama-server.log`). If you chose Ollama, it isn't running (`brew services start ollama`). Very long dictations get more time automatically. |
| Something else is wrong | Quoth → Settings → Help → **Report a Problem…** opens a GitHub issue and copies diagnostics (versions, settings, engine errors; never what you dictated) for you to paste. |
| It's slow | Pin your language (Settings), choose a smaller language model (Models → Dictation cleanup), or use a cloud API. |
| Text goes to the wrong place | Quoth pastes where the cursor is when you **start** speaking. Click into the field first. |
| "Won't type into password fields" | That's intentional. |
| Mic hears nothing | Check Settings → Microphone priority, and that the right input is selected in System Settings → Sound. |

Still stuck? Open an issue with what you did, what you expected, and the output of:

```bash
log show --last 5m --predicate 'subsystem == "app.quoth"'
```
