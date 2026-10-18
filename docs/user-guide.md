# User guide

Everything Quoth does, and how to use it. New here? Start with [Getting started](getting-started.md). The same overview is inside the app: Quoth window → **Features**.

- [Dictation](#dictation)
- [What cleanup does](#what-cleanup-does)
- [Personalisation](#personalisation): dictionary, snippets, style, context, languages
- [Command Mode](#command-mode)
- [Transforms](#transforms)
- [For developers](#for-developers)
- [Scratchpad](#scratchpad)
- [Meeting notes](#meeting-notes)
- [Insights](#insights)
- [History](#history)
- [AI apps (MCP)](#ai-apps-mcp)
- [All shortcuts](#all-shortcuts)

## Dictation

| Action | How |
| --- | --- |
| Dictate | **Hold** the hotkey, speak, release |
| Hands-free | **Double-tap** the hotkey; tap again or click ■ on the Earshot pill to stop |
| Cancel | **Esc** while recording, or ✕ on the Earshot pill |
| Paste last dictation again | **⌃⌘V** |
| Undo the AI's changes | Menu bar → Undo AI Edit (puts back what you literally said) |

Pick the hotkey in **Settings → Hotkey**: Fn (🌐), Right Option or Right Command. Pressing another key with the hotkey in the first second cancels (so shortcuts like Fn+Arrow keep working). A dictation can be up to 20 minutes; you get a warning at 19.

The **Earshot pill** is the small pill at the bottom of your screen. You can drag it, and right-click it to hide it for an hour. Settings can also keep it out of screen recordings.

Quoth pastes into the field that had focus when you **started** speaking, then restores your clipboard. It never types into password fields. In terminals, long text is pasted in pieces so tools like Claude Code don't collapse it.

## What cleanup does

Settings → Auto Cleanup:

- **None:** your exact words; only spoken punctuation is converted.
- **Light (default):** removes fillers, fixes grammar, punctuation and capitalisation.
- **Medium:** may also reword for clarity and brevity.

In Light and Medium:

| You say | You get |
| --- | --- |
| "um so let's meet at two actually three" | So let's meet at 3. |
| "send it to John no wait to Mary" | Send it to Mary. |
| "I actually enjoyed it" | I actually enjoyed it. *("actually" kept when it isn't a correction)* |
| "what's the capital of France" | What's the capital of France? *(never answered)* |
| "goals number one ship it number two rest" | Goals:<br>1. Ship it<br>2. Rest |
| "ideas bullet point a podcast bullet point a newsletter" | Ideas:<br>- A podcast<br>- A newsletter |
| "hi Tom new paragraph thanks best Alex" *(in email)* | Hi Tom,<br><br>Thanks.<br><br>Best,<br>Alex |
| "comma", "period", "question mark", "new line", "new paragraph" | , . ? and line breaks |

If the language model is slow or fails, Quoth pastes your words with basic punctuation instead (History shows "Cleanup skipped"). Long dictations automatically get more time.

## Personalisation

### Dictionary

Quoth → **Dictionary**.

- **Words:** names and terms to spell your way (e.g. *Kubernetes*, *Siobhan*). They also steer the speech model. Star the important ones.
- **Replacements:** "when I say *cube control*, write *kubectl*". Whole words only, case-insensitive, and possessives work ("cube control's").
- **Auto-learn:** if you fix a misheard name within a few seconds of dictating, Quoth adds it and tells you ("Learned: Siobhan"). It never learns common words, URLs, numbers or anything you deleted from the dictionary.

### Snippets

Quoth → **Snippets**. Say the trigger, get the text exactly as saved (up to 4,000 characters). Said on its own ("my calendar link"), the snippet replaces the whole dictation; inside a sentence it replaces just the trigger. The AI never sees or rewrites snippet text.

### Style

Quoth → **Style**. For each kind of app, choose how text looks. This changes capitalisation and punctuation only, never your words.

| App type | Examples | Options |
| --- | --- | --- |
| Personal messages | Messages, WhatsApp, Telegram, Discord, Signal | Formal · Casual · Very casual · Excited |
| Work messages | Slack, Teams, LinkedIn | Formal · Casual · Excited |
| Email | Mail, Outlook, Gmail in a browser | Formal · Casual · Excited |
| Everything else | Docs, Notes, ChatGPT… | Formal · Casual |

Casual drops the final period, Very casual also drops capitals, and Excited adds "!" where natural.

### Context

With **Style → Use the text around the cursor** on, Quoth reads the focused field when you start speaking:

- It continues sentences naturally (lowercase mid-sentence, correct spacing).
- It knows which app you're in.
- In code editors it recognises identifiers.

It reads through macOS Accessibility only. It never takes screenshots and never reads password fields or password managers. See [Privacy](privacy.md).

### Languages

**Settings → Languages:**

- **No language selected:** Quoth detects any of ~100 languages.
- **One language:** pinned; about 0.5 s faster.
- **Several languages:** Quoth detects among just those, and suggests adding a language if it hears one outside your set (at most once a day).

**Variant** adds UK/Canadian spelling, Swiss German (ss for ß), Hinglish (Hindi in Latin script) or Chinese Simplified/Traditional. French gets proper spacing before `? ! : ;` automatically.

Whispering works too: quiet recordings are boosted before recognition.

## Command Mode

Hold **hotkey + Control** (the Earshot pill turns orange) and say an instruction:

| Say | What happens |
| --- | --- |
| "make this more concise" / "translate to German" / "turn this into bullets" *(with text selected)* | The selection is replaced |
| "fix the grammar of this" *(nothing selected)* | The whole field is rewritten (short fields only) |
| "write a reply saying I'll be 10 minutes late" | A draft is typed at the cursor, using the field as context |
| "what does this mean?" / "how many days in a leap year" | The answer appears in a popup; nothing is typed |
| "search for the best ramen in Berlin" | Opens a Perplexity search |

Turn it off, or choose its model, in Settings / Models.

## Transforms

Select text and press:

| Key | Transform |
| --- | --- |
| **⌥1** | **Polish:** concise, clear, readable. Choose the rules in Quoth → Transforms. |
| **⌥2** | **Prompt Engineer:** turns a rambling request into a structured AI prompt, adding nothing you didn't say. |
| **⌥3–⌥9** | Your own transforms: an instruction plus up to 5 writing samples whose voice it should match. |
| **⌥O** | Show what the last transform changed. |

With nothing selected, a transform uses the whole field, or your last dictation if it was within the past minute. **Auto-apply** runs one transform on every dictation. Turn off the ⌥ shortcuts in Transforms if you need ⌥-characters (¡ ™ £ …).

## For developers

- **Cursor and Windsurf:** "check index dot ts" becomes `@index.ts`, so the IDE attaches the file. "dot env" becomes `.env`.
- **Code editors** (Cursor, Windsurf, VS Code, Zed, JetBrains, Xcode): spoken names match identifiers in the open file ("user id" → `userId`). For VS Code-based editors, enable the editor's "Screen Reader Optimized" mode so it exposes its text.
- **Terminals** (Terminal, iTerm, Warp, Ghostty, kitty, Alacritty): minimal formatting and chunked pasting.

## Scratchpad

**⌥S**, or the menu bar → Scratchpad, opens a floating notepad:

- Rich text (⌘B / ⌘I / ⌘U), multiple notes in the sidebar, autosave.
- Version history: the clock button restores an earlier version.
- Dictation works inside it like in any app.

## Meeting notes

Menu bar → **Start Meeting Notes**, or Quoth → Meetings → Start. Quoth suggests it when Zoom, Teams, Webex or FaceTime opens.

- Records two local tracks: your mic ("Me") and the computer's audio ("Others"). No bot joins the call. Let participants know you're taking notes.
- After you stop, it transcribes both tracks, merges them in time order (removing your mic's echo of the others), and writes notes: summary, topics, decisions, action items with owners, and a follow-up draft.
- **Ask across meetings:** "what did we decide about pricing?" gives an answer citing the meeting and timestamp.
- Audio is kept 14 days, so you can reprocess a meeting; transcripts and notes stay until you delete them.

Needs the Screen & System Audio Recording permission.

## Insights

Quoth → **Insights**:

- Words dictated, words per minute, and time saved compared with typing at 40 WPM.
- Current and longest streak, a 16-week activity heatmap, and the apps you dictate in most.
- **Your Voice** (after 2,000 words): your habits, plus an AI-written description of your style.

Only counts are stored for insights, never text.

## History

Quoth → **History** shows every dictation with its app, timing and latency. From there you can:

- Copy the cleaned or raw text, or show the raw version.
- Play the audio.
- Retry a failed dictation (the result goes to your clipboard).
- Delete one entry or everything.

**Settings → Privacy** controls retention: keep (audio for 14 days), delete after 24 hours, or never store. A dictation interrupted by a crash or quit is recovered on the next launch.

## AI apps (MCP)

Quoth includes `quoth-mcp`, a small server that gives AI apps like Claude Desktop read-only access to your meeting notes and Scratchpad notes. Dictations are never shared.

Copy the snippet from Quoth → Settings → AI apps into Claude Desktop's `claude_desktop_config.json` under `"mcpServers"`, then restart Claude. Turn access off with the same toggle.

## All shortcuts

| Shortcut | Action |
| --- | --- |
| Hold hotkey | Dictate |
| Double-tap hotkey | Hands-free dictation |
| Hotkey + Control | Command Mode |
| Esc | Cancel while recording |
| ⌃⌘V | Paste last dictation |
| ⌥1 … ⌥9 | Transforms |
| ⌥O | Show last transform diff |
| ⌥S | Scratchpad |
| Mouse button (optional) | Dictate or Enter (Settings → Mouse) |
