# Quoth for Android

A voice keyboard: tap the microphone, speak, and the text goes into whatever app you're typing in.
Everything runs on the phone: whisper.cpp turns speech into text, then (once its model is downloaded) a small
language model in llama.cpp cleans it up with the same prompt and rules as the Mac app. Without the cleanup
model the text is Whisper's, with the Mac app's spoken-punctuation and style rules applied.

## Layout

| Module | What |
| --- | --- |
| `core/` | Platform-neutral Kotlin (no Android): a port of the Mac's `Sources/QuothCore` cleanup (prompt, pipeline, rules, personal data) and model downloads. Tests run on the JVM; `src/eval` is the golden-eval runner |
| `app/` | The Android app: `QuothKeyboardService` (the keyboard), `MainActivity` (home: setup, try-it box, links to the screens), `PersonalScreens.kt` (History, Dictionary, Snippets, Style), `SettingsScreens.kt` (Settings, Models), `Store` (settings.json, personal.json, history.json in the app's files), `Speech` (runs the pipeline), `WhisperEngine` + `LlamaEngine` + `src/main/cpp` (JNI bridges to whisper.cpp and llama.cpp, one `libquoth.so` sharing llama.cpp's ggml) |
| `scripts/` | `fetch-engines.sh` (pinned whisper.cpp and llama.cpp sources), `e2e-emulator.sh` (end-to-end check), `eval-device.sh` (golden evals on a phone) |

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
`files/debug-input.wav` exists in the app's storage, the keyboard transcribes it instead of the microphone. The same script runs on a phone with USB debugging;
keep it unlocked with the screen on (a sleeping phone runs whisper over ten times slower).

## Evals

`core` runs the same golden cases as the Mac (`Evals/cleanup-golden.jsonl`) against any OpenAI-compatible server,
normally a `llama-server` on the Mac. To compare with the Swift version, point both at the same server:

```bash
/Applications/Quoth.app/Contents/MacOS/llama-server -m <model.gguf> --port 8190 --alias <model.gguf> -c 16384 -np 1 -ngl 999 --no-webui --reasoning off &
./gradlew :core:eval --args="--port 8190 --verbose"
(cd .. && swift run quoth-eval --builtin --port 8190 --gguf <model.gguf> --verbose)
```

## Notes

- arm64 only, Android 10 (API 29) or newer. Native code is built for `armv8.2-a+dotprod+fp16` and 16 KB pages.
- Force-stopping the app makes Android fall back to another keyboard; ordinary updates keep Quoth selected.
- Pixel 9a (Tensor G4), base model: about 2.4 s per dictation whatever its length, since whisper always encodes a
  30 s window. 4 threads is fastest; q5_1/q8_0 models are no faster, and a shortened `audio_ctx` is 3–4× faster
  but drops or garbles words, so neither is used.
- Kotlin regexes go through `Rx` (Text.kt) so `\b`, `\w` and `\s` are Unicode-aware on the JVM as on Android and the Mac.
- If `uiautomator dump` keeps failing with "null root node" on a phone, its accessibility connection is stuck (seen after an app crash during a test); restarting the phone fixes it. The e2e script stops instead of using a stale dump.
