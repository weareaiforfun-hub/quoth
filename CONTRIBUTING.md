# Contributing to Quoth

Thanks for helping! Quoth is a small, dependency-free Swift project, so contributions are easy to review when they stay focused.

## Ways to help

- **Report a bug:** open an issue with steps, what you expected, what happened, your Mac/macOS, and the relevant lines from `log show --last 5m --predicate 'subsystem == "app.quoth"'`.
- **Report a bad cleanup:** the most useful contribution. Include the raw transcript (History → Show raw) and the text you expected; even better, add it as a case to `Evals/cleanup-golden.jsonl`.
- **Fix or build something:** check [docs/status.md](docs/status.md) for the roadmap, and open an issue first for anything large.

## Development setup

See [docs/development.md](docs/development.md). In short:

```bash
scripts/setup.sh
scripts/build-app.sh --open
scripts/test.sh
```

## Pull requests

- Keep logic in `QuothCore` with unit tests; the `Quoth` target is OS glue and UI.
- For anything that changes what gets typed, run `swift run quoth-eval` before and after, and include both summaries in the PR. **No new serious failures.**
- Prefer deterministic rules over prompt changes for formatting behaviour (see [docs/architecture.md](docs/architecture.md)).
- No new third-party dependencies without discussion.
- Match the surrounding style; settings must decode tolerantly so existing users' files keep working.
- One topic per PR, with a clear description of the user-visible change.

## Privacy rules for contributions

Quoth must never send data anywhere the user didn't choose. No analytics, no telemetry, no network calls except to the user-configured engines and model downloads. Never read secure fields or password managers. See [docs/privacy.md](docs/privacy.md).

By contributing you agree your work is released under the [MIT License](LICENSE) and that you follow the [Code of Conduct](CODE_OF_CONDUCT.md).
