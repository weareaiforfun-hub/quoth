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
- **Messages / other user-generated text:** the text around the cursor and History stay in the app's private storage on the phone.
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
| Sensitive permissions | None that need a declaration form. RECORD_AUDIO and INTERNET are ordinary runtime/normal permissions; no Accessibility service, no SMS, call log, location or "all files" access |
| Foreground service types | None used |

## Keyboard (input method) notes

- When the user turns on the keyboard, Android shows its own warning that keyboards can collect typed text. The setup screen explains, in the same place, what Quoth reads and that it stays on the phone (Google's "prominent disclosure" expectation for apps that read personal text).
- Password boxes are never processed; fields flagged `IME_FLAG_NO_PERSONALIZED_LEARNING` (incognito) are kept out of History and auto-learn.
