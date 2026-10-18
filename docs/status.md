# Status & roadmap

Version 0.2 (October 2026).

## What's built

| Feature | Status | Verified by |
| --- | --- | --- |
| Push-to-talk, hands-free, Esc/cancel rules, re-entry guard | ✅ | Daily use |
| Earshot pill (non-activating, draggable, follows the screen, hide, capture exclusion) | ✅ | Daily use |
| Paste anywhere with clipboard restore, terminal chunking, per-app overrides, password-field refusal | ✅ | e2e |
| Mic ranking + fallback, no-sound warning, 20-min cap, crash recovery | ✅ | Unit + manual |
| Dock + menu bar, Hub window, onboarding | ✅ | Manual |
| Speech recognition (whisper.cpp, local) + cloud option | ✅ | Evals, e2e |
| Cleanup levels, corrections, lists, spoken punctuation, emails, never-answer guard | ✅ | 66-case eval: 0 serious failures |
| Length-scaled timeout with fallback, undo AI edit, paste last | ✅ | Unit, e2e |
| History, retry, audio playback, retention | ✅ | Unit + manual |
| Context awareness (Accessibility only) | ✅ | e2e |
| Styles per app category | ✅ | Unit + eval |
| Dictionary, replacements, auto-learn | ✅ | e2e |
| Snippets (protected from the LLM) | ✅ | Unit + e2e |
| Languages (auto, pinned, constrained set, variants), whisper mode | ✅ | Unit + real ASR |
| Command Mode (edit, draft, answer, search) | ✅ | 10/10 eval + e2e |
| Transforms (Polish, Prompt Engineer, custom, diff, auto-apply) | ✅ | e2e |
| Developer features (@file tagging, identifiers, terminal mode) | ✅ | Unit + eval |
| Thumb Talk (dictate by holding a middle/side mouse button) | ✅ | ⚠️ Not yet tried with a physical mouse |
| Scratchpad (rich text, notes, versions) | ✅ | Unit + e2e |
| Privacy controls | ✅ | |
| Insights + Your Voice | ✅ | Unit |
| Meeting notes (two-track capture, transcript, summary, Q&A) | ✅ | Live capture tested (system audio + mic, played through speakers); a real two-person call not yet |
| MCP server | ✅ | Unit + stdio test |
| Model choice per job, downloads, Model Lab | ✅ | Unit + in-app runs |
| Features tab (every feature, how to use it, where to configure it) | ✅ | Manual |

## Out of scope (for now)

| Area | Why |
| --- | --- |
| Windows, iOS, Android | Quoth is a native Mac app; each platform would be a separate client. |
| Accounts, billing, teams, SSO, admin portal | Only needed for a hosted business. |
| Streaming speech recognition while you talk | whisper.cpp transcribes after you release the key; long dictations wait for the whole clip. |
| Rich-text (HTML) paste of formatted lists and snippets | Lists paste as plain text with line breaks. |

## Known limitations

- **Speed:** about 1.5 s from key-up to text on an M1 Max with the defaults; longer for long dictations (the language model rewrites every word). Cloud voice keyboards running on datacenter GPUs reach about 0.7 s. A smaller model or a cloud API is faster.
- **Small models:** 7B and smaller models occasionally answer a dictated question or garble a correction. Guards catch the worst cases; the 14B default is much more reliable.
- **Accessibility gaps:** some apps (certain Electron/Java apps) expose little text, so context and auto-learn are weaker there. VS Code-based editors need "Screen Reader Optimized" mode for identifiers.
- **Meeting speakers** are only "Me" and "Others"; individual names aren't recognised yet.
- **Synthetic tests:** speech tests use macOS `say` voices, which are cleaner than real speech.

## Roadmap

1. **One-download app:** bundle the engines and download models on first run ([Distribution](distribution.md)).
2. **Streaming recognition**, so long dictations finish as fast as short ones.
3. **Rich-text paste** (HTML) for lists, bold snippets and links.
4. **Speaker names** in meetings, from calendar invites and voice profiles.
5. **Calendar-based meeting detection.**
6. **Learning from corrections:** use your post-paste edits to tune cleanup (spec 1.3).

## Still to do (maintainer)

- [x] Live meeting capture (tested after granting Screen & System Audio Recording).
- [ ] Try Thumb Talk: Settings → Mouse button to dictate → pick a side or middle button, then hold it and speak.
- [ ] Try a real call with meeting notes on.
- [ ] Look over the Quoth window's tabs (screenshots weren't possible in automated testing).
- [ ] Create the GitHub repository and push (see the [README](../README.md)).
- [ ] Decide on distribution: an Apple Developer account for signed, notarised downloads ([Distribution](distribution.md)).
- [ ] Choose the final name and run a trademark search before a public launch.
