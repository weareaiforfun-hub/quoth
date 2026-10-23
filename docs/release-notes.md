Quoth is free, open-source voice dictation for Macs with Apple Silicon (M1 or later) and macOS 14 or later. Hold a key, speak, let go, and tidy text appears where you were typing. Everything runs on your Mac.

## Install

New to this? The **[step-by-step install guide](https://github.com/weareaiforfun-hub/quoth/blob/main/docs/install.md)** walks you through everything.

1. Download **Quoth.dmg** below and open it.
2. Drag **Quoth** onto **Applications**.
3. Open Quoth from Applications. macOS says it can't check Quoth for malicious software, because Quoth isn't registered with Apple. Registering costs €99 every year, so to keep Quoth free I publish it a different way, signed with the project's own certificate. Click **Done**.
4. Open **System Settings → Privacy & Security**, scroll down to **Security**, and click **Open Anyway** next to "Quoth was blocked". Confirm with your password, then click **Open Anyway** again. (The button appears for about an hour after step 3; if it's gone, repeat step 3.)
5. Quoth opens on its **Setup** page:
   - Click **Download** to get the AI models; the one sized to your Mac is preselected (3–10 GB).
   - Grant the three permissions while it downloads.

You only do steps 3–4 once; updates open normally. You can check the download against the `.sha256` file: `shasum -a 256 Quoth-*.dmg`.

## What's new

- **One download:** the speech and language engines now ship inside the app. No Homebrew, Terminal or Ollama needed.
- **First-run setup:**
  - Choose Lite, Standard or Best models for your Mac's memory.
  - The download resumes if interrupted, and every file's checksum is verified.
- **Automatic updates:** Quoth can keep itself up to date (Settings → Updates). Updates are signed and verified, and install without the "Open Anyway" step.
- **Ollama and cloud APIs** still work as options in Models.
