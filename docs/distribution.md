# Distribution: making Quoth a one-click download

*Assessment, October 2026. Nothing here is implemented yet.*

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

## Signing and installation

| Step | Needed for | Cost / owner |
| --- | --- | --- |
| Apple Developer Program | A Developer ID certificate, so other Macs trust the app | $99/year, the project owner's account |
| Developer ID signing of the app and each bundled binary, hardened runtime, microphone entitlement | Gatekeeper | Free once enrolled |
| Notarisation (`notarytool`) + stapling | No "unidentified developer" warning | Free; automated in CI |
| DMG (`create-dmg`) with a drag-to-Applications layout | The one-click experience | Free |
| Sparkle auto-updates (signed appcast on GitHub Releases) | Updates without re-downloading by hand | Free |
| Homebrew cask (`brew install --cask quoth`) | Developers | Free; a PR to homebrew-cask |

Without the Developer Program, the alternative is unsigned builds that users must right-click → Open and approve in System Settings. That's fine for early testers, not for a general audience.

**Permissions** still need user approval (Microphone, Accessibility, Input Monitoring), and macOS doesn't allow skipping that. The existing Setup page walks through it; a signed app keeps the grants across updates.

## Release pipeline (CI)

GitHub Actions on a macOS runner, on every tag:

1. Build (Xcode toolchain) and run unit tests.
2. Download pinned `whisper-server` and `llama-server` builds (or build them), and sign everything with the Developer ID certificate (stored as an encrypted secret).
3. Notarise, staple, and build the DMG.
4. Publish to GitHub Releases, update the Sparkle appcast and the Homebrew cask.

## Other considerations

- **Name:** run a trademark search on the final name before a public launch.
- **Support burden:** a one-click app attracts non-technical users. The Setup page, `docs/getting-started.md` troubleshooting and a "Copy diagnostics" button (to add) will matter.
- **Intel Macs:** possible with llama.cpp/whisper.cpp CPU builds, but slow; recommend Apple Silicon only.

## Suggested order

1. Apple Developer account, signing and notarisation in CI, DMG: the app opens anywhere.
2. Bundle whisper-server + llama-server; first-run model download screen (option A).
3. Sparkle updates and a Homebrew cask.
4. Prototype an Apple on-device "Lite" mode (option C) and compare it in the Model Lab.
