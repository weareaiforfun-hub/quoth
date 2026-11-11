# Play Console answers (draft)

Answers for the forms under Play Console → Policy → App content, matching what the app does (checked against the code on this branch) and [the privacy policy](../../docs/privacy-android.md).

## Data safety

Google counts data as "collected" only when it's sent off the phone. Quoth processes the microphone and the text box only on the phone, so:

| Question | Answer |
| --- | --- |
| Does your app collect or share any of the required user data types? | **No** |
| (Shown on the listing as) | "No data collected", "No data shared with third parties" |

Why each data type is "no":
- **Audio (voice recordings):** recorded into memory while you dictate, turned into text on the phone, then dropped. Never written to storage, never sent.
- **Messages / other user-generated text:** the text around the cursor and History stay in the app's private storage on the phone. The same holds for Earshot, which reads the focused text box through the Accessibility API: what it reads is used on the phone and never sent.
- **App activity:** History stores which app a dictation went to, only on the phone.
- **Device IDs, location, contacts, crash logs, analytics:** none. There's no analytics or crash-reporting library.
- **Model downloads:** Quoth fetches files from Hugging Face. That's the app downloading content, not sending user data; Hugging Face sees an IP address like for any download.

## Other declarations

| Form | Answer |
| --- | --- |
| Privacy policy | https://github.com/weareaiforfun-hub/quoth/blob/main/docs/privacy-android.md (live once merged to main) |
| Ads | No ads |
| App access | All functionality is available without an account or login |
| Content rating (IARC questionnaire) | Category "Utility, productivity, communication". No violence, sexuality, gambling or drugs. Users don't interact with or share content with other users through the app. No location sharing. No purchases |
| Target audience | 18 and over (keeps the app out of the Families programme; nothing is aimed at children) |
| News app | No |
| Government app | No |
| Financial features | None |
| Health | None |
| COVID-19 contact tracing | No |
| Data deletion | Not required (no accounts, nothing collected). Users delete History in the app or by uninstalling |
| Sensitive permissions | **First release (keyboard-only build): none.** From the update that adds Earshot: **Accessibility API**, with the declaration below. RECORD_AUDIO and INTERNET are ordinary runtime/normal permissions; no SMS, call log, location or "all files" access, and no SYSTEM_ALERT_WINDOW (Earshot's bubble is an accessibility overlay) |
| Foreground service types | None used |

## Keyboard (input method) notes

- When the user turns on the keyboard, Android shows its own warning that keyboards can collect typed text. The setup screen explains, in the same place, what Quoth reads and that it stays on the phone (Google's "prominent disclosure" expectation for apps that read personal text).
- Password boxes are never processed; fields flagged `IME_FLAG_NO_PERSONALIZED_LEARNING` (incognito) are kept out of History and auto-learn.

## Accessibility API declaration (Earshot)

*For the later update that adds Earshot; the closed test and first release are keyboard-only and don't include the service.*

Play Console → Policy → App content → **Sensitive permissions and APIs** → Accessibility API. Google reviews this by hand and can reject an app, or later remove it, if the use doesn't match the declaration, so the answers must match what the app does. The service is declared with `android:isAccessibilityTool="false"` (`app/src/main/res/xml/earshot_service.xml`).

| Question | Answer |
| --- | --- |
| Is your app an accessibility tool (designed to help people with disabilities)? | **No** |
| Feature that uses the Accessibility API | Earshot, an optional floating dictation button ("Quoth Earshot") |
| Is it core functionality? | Yes: dictating into other apps is what Quoth does. Earshot is the way to do it without switching keyboards; it's off by default |
| Why the API is needed | To dictate into any app while keeping the user's own keyboard, Quoth has to know which text box has the cursor (and that it isn't a password box), show its button next to the keyboard, and put the transcribed text into that box. Android offers no other way for an app that isn't the current keyboard to do this |
| Data accessed | The focused editable text box (its kind, its text near the cursor when the user dictates, and its text after inserting, for learning corrected names), the package name of the app it's in, and whether a keyboard window is open. The service subscribes only to focus and window-change events (`typeViewFocused`, `typeWindowStateChanged`, `typeWindowsChanged`); it doesn't request key events, gestures, screenshots or touch exploration |
| Is the data collected or shared? | No. Everything is processed on the device. The app has no analytics, no accounts and no network use except downloading AI models from Hugging Face on request |
| Does it act without the user? | No. It inserts text only after the user taps the button and speaks. It never changes settings, never taps other apps' controls, and never acts in password fields |
| Prominent disclosure and consent | `EarshotScreen` ("Before you turn it on"): shown every time before the user is sent to Android's Accessibility settings, from Settings → Earshot or the home screen's Earshot card, with "Agree and turn on" / "Not now". If the user switches the service on directly in Android's settings, Quoth opens the same disclosure and the button stays hidden until they agree; "Not now" switches the service off again |
| Video | Required: a YouTube link (unlisted is fine) showing the disclosure, the consent tap, enabling Quoth Earshot in Accessibility settings, and one dictation into another app with Gboard. **To record on the Pixel before submitting** (screen recorder in Quick Settings) |

### Wording for the "Describe how your app uses the Accessibility API" box

> Quoth is an on-device voice dictation app. Its optional "Earshot" feature lets users dictate into any app while keeping their usual keyboard: when a text field has focus and a keyboard is open, Earshot shows a small microphone button above the keyboard. When the user taps it and speaks, Quoth transcribes the speech on the device and inserts the text into the focused field with ACTION_SET_TEXT (or paste). The AccessibilityService is used only to detect the focused editable field and whether a keyboard is open, to read the field's text near the cursor when the user dictates (so the new text fits in), to show the button as an accessibility overlay, and to insert the text. It never acts in password fields, never acts without a tap from the user, and no data leaves the device. Quoth is not an accessibility tool; it shows a prominent in-app disclosure and asks for consent before the user is sent to the Accessibility settings.

### Before submitting (risks)

- Google has rejected and removed apps for using the Accessibility API for non-accessibility features. Apps such as voice-typing tools do ship with this declaration, so it's possible, but review may ask for changes or more video.
- Chosen route (2026-11-11): the closed test and first release are the keyboard-only build (`-Pquoth.earshot=false`); Earshot follows in an update with this declaration, so a rejection only holds up that update.
- Sideloaded installs on Android 13+ need "Allow restricted settings" (App info → ⋮) before the service can be switched on; Play installs don't.
