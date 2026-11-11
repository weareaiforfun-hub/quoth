# Releasing Quoth for Android (Google Play)

How a Play release is built, signed and published. The steps marked **(Arian)** need Arian's password, payment or account, so they're done by Arian, not by a script or an assistant.

## Keys, once

Play uses two keys:

- **The app signing key** is made and kept by Google (Play App Signing, the default for new apps). It signs what users install.
- **The upload key** is yours. It signs what you upload, so Google knows it's you. If it's lost or leaked, Play support can reset it, so it's less precious than the Mac's certificate, but keep it safe all the same.

**(Arian) Create the upload key** with one command in Terminal. It asks for a **new** password (at least 12 characters, used nowhere else, not your Mac's password), creates `~/.quoth/quoth-upload.jks`, and stores the password in your Mac's Keychain as "quoth-upload", where the release build finds it. No file ever holds the password. If you ran an earlier version of these steps, it offers to delete those files first.

```bash
~/Claude/quoth/android/scripts/make-upload-key.sh
```

**(Arian) Back up** `quoth-upload.jks` and its password off the Mac: for example, save the password in your password manager and attach the file to the same entry, or copy the file to an encrypted USB stick. The script opens the folder for you.

## Build

```bash
cd android && scripts/fetch-engines.sh && ./gradlew :core:test :app:lintRelease :app:bundleRelease
```

The signed bundle is `app/build/outputs/bundle/release/app-release.aab`. It contains the arm64 native library (16 KB aligned) and its symbol table, so Play shows readable native crash stacks.

Before each release, bump `versionCode` (by 1) and `versionName` in `app/build.gradle.kts`, and run the e2e test on a phone (`scripts/e2e-emulator.sh`, see `android/README.md`).

The build reads the key from `~/.quoth/quoth-upload.jks` and the password from the Keychain (`QUOTH_UPLOAD_KEY` and `QUOTH_UPLOAD_PASSWORD` override them). For a local test of a release build without the upload key: `./gradlew :app:assembleRelease -Pquoth.debugSign=true` (signed with the debug key; never upload it).

## Play Console

1. **(Arian) Developer account:** sign up at play.google.com/console as a **personal** account and pay the one-time $25. Google checks your identity and asks for a public contact email, and, as you're in the EU, whether you're a trader (DSA). Selling nothing and earning nothing from a hobby app usually means **not a trader**; read Google's wording before answering.
2. **(Arian) Create the app:** name "Quoth: Private Voice Keyboard", default language English, App, Free. Free can't later become paid.
3. **Store listing and App content:** paste from `android/store/listing.md` and `android/store/data-safety.md`; upload `android/store/icon-512.png`, `feature-graphic.png` and the screenshots.
4. **Closed test (required for new personal accounts):** Testing → Closed testing → create a track, upload the `.aab`, add testers by email (a Google Group is easiest). At least **12 testers must stay opted in for 14 days in a row** before Production unlocks; if the count drops below 12 the clock restarts. Testers install from the opt-in link Play gives you. Ask them to really use it (Google checks engagement).
5. **Production:** after the 14 days, Play Console offers "Apply for production" with a short questionnaire about the test. Then create a production release with the same `.aab` (or a newer one) and send it for review (usually a few days for a new app).

Every step that publishes something (uploading a release to a track testers can see, sending for review) waits for Arian's go.

## Updates

Upload a new `.aab` with a higher `versionCode` to the same track. Play delivers it to users; there's no in-app update code.
