# Development

## Build

You need Apple Silicon, macOS 14+, the Xcode Command Line Tools and Homebrew. Full Xcode isn't required.

```bash
scripts/setup.sh            # one-time: engines, models, signing certificate
swift build                 # debug build of everything
scripts/build-app.sh        # release build → build/Quoth.app → ~/Applications
scripts/build-app.sh --open # …and launch it
```

`build-app.sh` assembles the `.app` by hand (binary, `quoth-mcp`, Info.plist, icon, Model Lab resources) and signs it with the local "Quoth Dev" certificate. Signing with a stable identity matters: ad-hoc signatures change on every build, and macOS would drop the app's Accessibility and Input Monitoring permissions each time.

The icon is generated from code: `scripts/icon/render-icons.swift` draws the concepts and `scripts/icon/make-icns.sh` builds `AppIcon.icns`.

## Tests

```bash
scripts/test.sh             # 85 unit tests (Swift Testing)
```

Without Xcode, Swift Testing lives inside the Command Line Tools; `test.sh` adds the framework paths `swift test` needs. With Xcode installed, plain `swift test` works too.

## Evals: measuring model and prompt quality

```bash
swift run quoth-eval                                   # cleanup test set with your configured model
swift run quoth-eval --model qwen2.5:7b-instruct       # another Ollama model
swift run quoth-eval --cloud                           # the cloud model (key from the app or QUOTH_API_KEY)
swift run quoth-eval --only lists --verbose            # one category, show every output
swift run quoth-eval --commands                        # Command Mode routing (Evals/command-golden.jsonl)
swift run quoth-eval --transforms                      # sample Transform outputs
swift run quoth-eval --audio clip.wav --language en    # full pipeline on a 16 kHz WAV (needs whisper-server)
swift run quoth-eval --meeting me.wav others.wav       # meeting pipeline on two tracks
```

The cleanup set is `Evals/cleanup-golden.jsonl`, one case per line:

```json
{"id":"backtrack-1","category":"backtrack","raw":"let's meet at 4 actually 5 pm","expected":"Let's meet at 5 pm."}
```

Optional fields:

| Field | Purpose |
| --- | --- |
| `alt` | Other acceptable answers |
| `must_not_contain`, `max_words` | Hard checks (e.g. the model must not answer the question) |
| `bundle`, `window`, `tone`, `before` | Context for the case |
| `vocab`, `replacements`, `snippets`, `identifiers` | Personalisation for the case |

**Scoring:** ✓ exact, ≈ same words, · different, ✗ serious (answered, added content, or fell back). The exit code is non-zero if anything is serious.

**Workflow for quality fixes:**

1. Add the failing case.
2. Run `--only <category>`.
3. Prefer a deterministic rule in `QuothCore` over prompt changes.
4. Run the full set to catch regressions.

Prompt changes have side effects on small models; every change in this repo was checked against the full set.

## End-to-end tests in the real app

`scripts/dev/e2e.sh` drives the installed app with synthetic speech (macOS `say`) into a throwaway text window it creates (`scripts/dev/e2e-target.swift`), and checks what lands in the field. It covers:

- Lists, continuation, dictionary, snippets, corrections and clipboard restore
- Auto-learn
- Command Mode and Transforms

```bash
defaults write app.quoth debugHooks -bool true   # enable the test hooks, then restart Quoth
scripts/dev/e2e.sh                                      # 12 checks; backs up and restores personal.json
defaults delete app.quoth debugHooks             # turn them off again
```

Debug hooks let any local process trigger dictations, so they're off by default. Available hooks (`swift scripts/dev/post.swift <hook> [arg]`):

| Hook | Argument | Effect |
| --- | --- | --- |
| `dictate` | WAV path | As if dictated into the frontmost app |
| `command` | WAV path | As a Command Mode instruction |
| `transform` | N | Runs transform ⌥N on the frontmost app |
| `scratchpad` | | Toggles the Scratchpad |
| `meeting` | | Starts/stops meeting notes |
| `lab` | `cleanup\|tag1,tag2`, `speech\|file1,file2` or `download\|file` | Runs a Model Lab comparison and writes `lab-report.json` |

## Debugging

```bash
log stream --predicate 'subsystem == "app.quoth"'   # per-dictation latency and fallbacks
tail -f ~/Library/Application\ Support/Quoth/whisper-server.log
ollama ps                                                  # is the language model loaded?
```

The History tab shows per-dictation latency and why cleanup was skipped.

## Project conventions

- Logic goes in `QuothCore` with unit tests; the app target is OS glue and UI.
- Settings and personal data decode tolerantly (`decodeIfPresent ?? default`), so old files keep working. Add migrations next to `LegacyKeys`.
- No third-party dependencies without a strong reason.
- Behaviour visible to users needs a test or eval case.

## Shell gotchas

Some Macs alias `cp`, `ls` or `cat` (e.g. to `eza`/`bat`, or `cp -i`). The scripts use `cp -f` and run in plain `bash`, so they're unaffected, but keep that in mind when copying commands from them.
