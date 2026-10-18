# Security policy

Quoth reads your microphone, the text field you're typing in, and (for meeting notes) your computer's audio, so security issues matter.

## Reporting a vulnerability

Please **don't** open a public issue. Use GitHub's private vulnerability reporting (Security → Report a vulnerability) on this repository. Include steps to reproduce and the impact. You'll get a response within a week.

## Scope

In scope, for example:

- Text being typed into a secure (password) field.
- Context being read from a denylisted app.
- Data leaving the Mac without the user choosing a cloud provider.
- The MCP server exposing more than meeting and Scratchpad notes.
- The debug hooks being reachable when they're disabled.
- Keychain or file-permission mistakes.

Out of scope: issues in whisper.cpp, Ollama, llama.cpp or the models themselves (report those upstream), and attacks that need an already-compromised user account.

## Notes for users

- The debug hooks (`defaults write app.quoth debugHooks -bool true`) let any local process trigger dictations. Only enable them for development.
- Cloud mode sends audio and/or text to the provider you configured.
