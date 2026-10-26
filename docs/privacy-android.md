# Quoth for Android: privacy policy

*Effective 26 October 2026. Applies to the Quoth voice keyboard for Android (package `app.quoth`).*

**Short version:** Quoth turns your speech into text on your phone. Your voice and your text never leave the phone. Quoth has no accounts, no ads, no analytics and no tracking, and the developer receives no data from it.

## What Quoth uses, and why

| What | When | Why | Leaves the phone? |
| --- | --- | --- | --- |
| Microphone audio | Only from when you tap the microphone on the Quoth keyboard until you tap it again | To turn your speech into text | No. It's processed in memory and never saved |
| A little of the text around the cursor in the box you're typing in, and that app's name | When you dictate, unless you turn it off (Style → Context) | To continue sentences naturally and match the app's writing style | No |
| The box's text again after Quoth inserts text | While the box is open, if "Learn names when I correct a dictation" is on (Dictionary) | To notice a name you corrected and add it to your Dictionary | No |

Quoth never works in password boxes. Where an app asks keyboards not to remember anything (for example an incognito tab), Quoth keeps no History and learns nothing.

## What's stored on your phone

Everything is in Quoth's private app storage, which other apps can't read:

| Data | Kept |
| --- | --- |
| History: the text of your recent dictations, the app it went to, timings | Your choice in Settings: keep, 24 hours, or never. Delete any entry or all of it in History |
| Dictionary, snippets and styles you create | Until you delete them |
| Settings | Until you uninstall Quoth |
| The speech and clean-up models | Until you delete them (Settings → Clean-up model) or uninstall Quoth |

Audio is never stored. Quoth turns off Android backups, so none of this goes to a cloud backup or gets copied to a new phone. Uninstalling Quoth deletes all of it.

## What goes over the internet

Only the model downloads. When you tap **Download** in setup or on the Models screen, Quoth downloads the model file from Hugging Face (huggingface.co). Like any download, that sends your IP address and a request for the file to Hugging Face, under [Hugging Face's privacy policy](https://huggingface.co/privacy). Nothing about you or your dictations is sent. After that, Quoth works offline.

## Permissions

| Permission | Used for |
| --- | --- |
| Microphone | Recording while you dictate |
| Internet | Downloading the models, only when you ask for them |

You can turn off the microphone permission any time in Android Settings → Apps → Quoth → Permissions.

## Sharing and selling

Quoth doesn't collect your data, so it shares or sells none. There are no third-party analytics, advertising or crash-reporting services in the app.

## Children

Quoth isn't directed at children and collects no data from anyone.

## Changes

If this policy changes, the new version is published at this address with a new effective date. Quoth is open source, so you can check what it does in its code: [github.com/weareaiforfun-hub/quoth](https://github.com/weareaiforfun-hub/quoth).

## Contact

Questions about privacy: [arian.shafa.analytics@gmail.com](mailto:arian.shafa.analytics@gmail.com).
