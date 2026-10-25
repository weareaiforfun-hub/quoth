# Quoth for Android

A voice keyboard: tap the microphone, speak, and the text goes into whatever app you're typing in.
Speech recognition runs on the phone with whisper.cpp. **Work in progress:** there's no cleanup model yet,
so the text is Whisper's, with the Mac app's spoken-punctuation rules applied.

## Layout

| Module | What |
| --- | --- |
| `core/` | Platform-neutral Kotlin (no Android): model downloads, and ports of the Mac's rules from `Sources/QuothCore`. Tests run on the JVM |
| `app/` | The Android app: `QuothKeyboardService` (the keyboard), `MainActivity` (setup), `WhisperEngine` + `src/main/cpp` (JNI bridge to whisper.cpp) |
| `scripts/` | `fetch-engines.sh` (pinned whisper.cpp source), `e2e-emulator.sh` (end-to-end check) |

## Build and test (macOS)

```bash
brew install openjdk@17 && brew install --cask android-commandlinetools
export JAVA_HOME=/opt/homebrew/opt/openjdk@17 ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.0.0" "ndk;28.2.13676358" "cmake;3.31.6" "emulator" "system-images;android-37.0;google_apis;arm64-v8a"
cd android
scripts/fetch-engines.sh
./gradlew :core:test :app:assembleDebug
```

End to end, on a headless emulator (no window opens):

```bash
avdmanager create avd -n quoth-test -k "system-images;android-37.0;google_apis;arm64-v8a" -d pixel_9a
$ANDROID_HOME/emulator/emulator -avd quoth-test -no-window -no-audio &
scripts/e2e-emulator.sh
```

The script dictates `say`-generated speech through a debug-only hook: in debug builds, if
`files/debug-input.wav` exists in the app's storage, the keyboard transcribes it instead of the microphone.

## Notes

- arm64 only, Android 10 (API 29) or newer. Native code is built for `armv8.2-a+dotprod+fp16` and 16 KB pages.
- Force-stopping the app makes Android fall back to another keyboard; ordinary updates keep Quoth selected.
