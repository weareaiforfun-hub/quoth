# Distribution: making Quoth a one-click download

*Assessment and plan, October 2026. Not implemented yet.*

**Decision:** Quoth ships as a **free** Mac download, without the paid Apple Developer Program. Releases are signed with the project's own certificate and published on GitHub Releases. Users approve the app once in System Settings ("Open Anyway"). Apple notarization stays an optional upgrade if the one-time approval turns out to put people off.

## The goal

Today a user needs the Command Line Tools, Homebrew, whisper.cpp, Ollama, a model download, a self-signed certificate and a build. The goal is one download: open `Quoth.dmg`, drag to Applications, launch, grant permissions, and it works.

What currently forces the extra installs:

1. **Engines:** whisper-server comes from Homebrew; language models run in Ollama, a separate app.
2. **Models:** 0.5–9 GB of weights, too big to sensibly ship inside the app.
3. **Signing:** a self-signed certificate works on the developer's own Mac, but other Macs block the app (Gatekeeper).
4. **Building:** users currently compile from source.

## Options for the engines

| | A. Bundled servers (recommended first) | B. In-process libraries | C. Apple on-device models | D. Today (Homebrew + Ollama) |
| --- | --- | --- | --- | --- |
| How | Ship `whisper-server` and `llama-server` (llama.cpp's OpenAI-compatible server) inside `Quoth.app/Contents/MacOS`, launched like whisper-server is today | Link whisper.cpp + llama.cpp as XCFrameworks, or WhisperKit (now part of `argmax-oss-swift`) + MLX Swift (`mlx-swift-lm`) | macOS 26 SpeechAnalyzer for speech, Foundation Models (~3B) for text | Unchanged |
| User installs | Nothing else | Nothing else | Nothing at all (no model download) | Homebrew, Ollama, models |
| Code changes | Small: `WhisperServerTranscriber` and `ChatCompletionsCleaner` already speak these APIs. Replace the Ollama client for local text with `llama-server`, add a model manager. | Large: replace the HTTP clients with library calls, handle memory and threading in-process | Medium: new `Transcriber` and `Cleaner` implementations behind the existing protocols | None |
| App size | ~15–30 MB + models | ~10–20 MB + models | ~5 MB | ~5 MB |
| Speed | Same as today (Metal) | Slightly faster (no HTTP hop; MLX is very fast on Apple Silicon) | Fast; tied to Apple's models | Same as today |
| Quality | Same models as today | Same or better | Unproven for cleanup and corrections; language coverage limited to Apple's | Same |
| Risks | Ship and update two C++ binaries; code-sign each | Needs Xcode to build; C++ interop; a crash takes down the app | Requires Apple Intelligence on (macOS 26, M1+, supported regions); Apple controls behaviour | Too many steps for non-developers |
| Effort | ~3–5 days | ~2–4 weeks | ~1 week to prototype, plus quality evaluation | — |

**Recommendation:** start with **A**, keep Ollama and cloud as optional providers for power users, and prototype **C** as a zero-download "Lite" mode later. Measure it with the existing Model Lab and `quoth-eval` before trusting it. Move to **B** only if bundling separate binaries becomes a maintenance burden.

## Models: download on first run

Shipping 9 GB of weights in a DMG isn't practical. Instead:

1. On first launch, an onboarding screen detects memory and recommends a bundle:
   - *Lite:* Whisper Small + Qwen 2.5 3B, ~2.5 GB, for 8 GB Macs.
   - *Standard:* Whisper Large v3 Turbo + Qwen 2.5 7B, ~5.3 GB, for 16 GB.
   - *Best:* Turbo + Qwen 2.5 14B, ~9.6 GB, for 32 GB+.
2. Downloads with a progress bar, resumable, from Hugging Face (GGUF builds for llama-server). `ModelDownloader` and the Models tab already do this for Whisper.
3. Checks SHA-256 hashes from a small signed manifest.
4. The app is usable with a cloud key while downloading.

Licences allow this: Whisper is MIT; Qwen 2.5 7B/14B are Apache-2.0; llama.cpp and whisper.cpp are MIT. The Qwen 2.5 3B licence is non-commercial (fine for a free open-source app, but check before any paid version); Qwen 3 4B (Apache-2.0) is the alternative.

## Signing and installation (free route)

| Step | Needed for | Cost |
| --- | --- | --- |
| Sign every release with the project's own, unchanging certificate | macOS keeps users' permissions (Accessibility, Microphone…) across updates; ad-hoc signing would reset them every time | Free |
| DMG with a drag-to-Applications layout, on GitHub Releases | The one-download experience | Free |
| A clear "first launch" guide (README, release notes, download page) | Getting past the one-time Gatekeeper block | Free |
| Sparkle auto-updates (EdDSA-signed appcast on GitHub) | Updates without re-downloading; Sparkle-installed updates don't trigger the Gatekeeper prompt again | Free |

**First launch for users:** macOS blocks apps that Apple hasn't notarised. Since macOS 15, right-click → Open no longer bypasses this, so the steps are:
1. Double-click Quoth; macOS refuses to open it.
2. Open System Settings → Privacy & Security, scroll to Security, and click **Open Anyway** (available for about an hour after the attempt). Confirm with your password.
3. From then on, Quoth opens normally.

**Permissions** (Microphone, Accessibility, Input Monitoring) still need approval in any case; the Setup page walks through them.

**Not available on the free route:** the Mac App Store, Homebrew's official cask repository (it requires notarised apps since Homebrew 5.0), and a warning-free first launch.

**Optional upgrade:** the Apple Developer Program ($99/year) adds Developer ID signing and notarisation, which removes the "Open Anyway" step. Nothing else in the plan changes.

## Release pipeline

Releases are built locally by the maintainer, so the signing key never leaves their Mac:

1. `scripts/release.sh`: release build, bundle the pinned `whisper-server` and `llama-server` binaries, sign with the project certificate, build the DMG.
2. `gh release create vX.Y.Z Quoth.dmg` with release notes that include the first-launch steps.
3. Update the Sparkle appcast.

GitHub Actions keeps building and testing every push, without signing.

## Other considerations

- **Name:** run a trademark search on the final name before a public launch.
- **Support burden:** a one-click app attracts non-technical users. The Setup page, `docs/getting-started.md` troubleshooting and a "Copy diagnostics" button (to add) will matter.
- **Intel Macs:** possible with llama.cpp/whisper.cpp CPU builds, but slow; recommend Apple Silicon only.

## Suggested order

1. Bundle `whisper-server` + `llama-server` in the app (option A).
2. First-run model download on the Setup page, sized to the Mac's memory.
3. `scripts/release.sh`, DMG on GitHub Releases, README download link + first-launch guide.
4. Sparkle updates; "Copy diagnostics" / report-a-problem button.
5. Beta with a few non-technical users.
6. Later, optionally: Apple notarisation ($99/year), an Apple on-device "Lite" mode (option C), and other platforms (Windows, Linux, Android), each a separate native client sharing Quoth's prompts, evals and model choices.
