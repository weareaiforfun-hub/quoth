# Google Play listing (draft)

Paste these into Play Console → Grow → Store presence → Main store listing. Limits are Play's.

**App name** (30 max): Quoth: Private Voice Keyboard

**Short description** (80 max):
Speak and it types, in any app. Private: speech and clean-up run on your phone.

**Full description** (4,000 max):

Quoth is a voice keyboard. Tap the microphone, speak, and your words appear in whatever app you're typing in: messages, email, notes, search.

Everything runs on your phone. Your voice and your text are never sent anywhere. There are no accounts, no ads and no tracking, and it works offline once the models are downloaded.

WHAT IT DOES
• Turns speech into text with Whisper, in about 100 languages
• Cleans it up with a small AI model on your phone: removes ums and repeats and fixes punctuation, while keeping your words. The larger optional model also reliably applies spoken corrections like "Thursday, actually Friday"
• Fits the app: casual in chats, proper punctuation in email, no full stop in a search box
• Continues your sentence naturally, using a little of the text around the cursor
• Dictionary: names and words spelled your way, plus replacements ("cube control" → "kubectl")
• Learns a name when you correct it
• Snippets: say a short phrase and Quoth types a longer saved text
• History of recent dictations, kept on your phone only, or not at all if you prefer

HOW TO USE IT
Quoth sits next to your usual keyboard. When you want to dictate, switch to Quoth with the keyboard button, speak, then switch back with one tap.

Or keep your keyboard and turn on Earshot: a small Quoth microphone that floats above any keyboard while you type. Tap it, speak, and the text goes into the box. Earshot is optional and off until you turn it on. It uses Android's Accessibility service only to find the text box you're typing in and put your words into it; Quoth isn't an accessibility tool, it never reads password boxes, and nothing leaves your phone.

PRIVATE BY DESIGN
• Audio is processed in memory and never saved
• Quoth never works in password boxes, and the keyboard keeps nothing from incognito tabs
• The only internet use is downloading the AI models, when you ask for them

Free and open source: github.com/weareaiforfun-hub/quoth

Needs a 64-bit phone with Android 10 or later. The speech model is a 148 MB download; the optional clean-up model is 1.4 GB (Wi-Fi recommended) and works best on phones with 8 GB of memory or more.

**Category:** Productivity. **Tags:** Keyboard, Voice, Productivity (pick what Play offers).
**Contact email** (shown publicly): Arian's choice. The Mac app uses arian.shafa.analytics@gmail.com.
**Website:** https://arian-shafa.xyz/quoth/
**Privacy policy URL:** https://github.com/weareaiforfun-hub/quoth/blob/main/docs/privacy-android.md (live once this branch is merged to main)

If the first release ships without Earshot (the keyboard-only build, see `docs/android-release.md`), leave out the Earshot paragraph until the update that adds it.

**Graphics** (in this folder): `icon-512.png` (app icon), `feature-graphic.png` (1024×500), `screenshots/` (phone, 1080×2160).
