// JNI bridge between WhisperEngine.kt and whisper.cpp.
#include <jni.h>
#include <android/log.h>
#include <string>
#include <thread>
#include "whisper.h"

#define LOG_TAG "QuothWhisper"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

extern "C" JNIEXPORT jlong JNICALL
Java_app_quoth_android_WhisperEngine_nativeInit(JNIEnv *env, jclass, jstring modelPath) {
    const char *path = env->GetStringUTFChars(modelPath, nullptr);
    whisper_context_params params = whisper_context_default_params();
    params.use_gpu = false;
    whisper_context *ctx = whisper_init_from_file_with_params(path, params);
    LOGI("loaded %s: %s", path, ctx ? "ok" : "failed");
    env->ReleaseStringUTFChars(modelPath, path);
    return reinterpret_cast<jlong>(ctx);
}

extern "C" JNIEXPORT void JNICALL
Java_app_quoth_android_WhisperEngine_nativeFree(JNIEnv *, jclass, jlong ctx) {
    if (ctx) whisper_free(reinterpret_cast<whisper_context *>(ctx));
}

// Transcribes 16 kHz mono float samples. language is a code like "en", or "auto".
// Returns UTF-8 bytes (not a jstring: JNI strings use modified UTF-8, which mangles emoji).
extern "C" JNIEXPORT jbyteArray JNICALL
Java_app_quoth_android_WhisperEngine_nativeTranscribe(JNIEnv *env, jclass, jlong ctxPtr, jfloatArray samples,
                                                     jstring language, jstring prompt, jint threads) {
    auto *ctx = reinterpret_cast<whisper_context *>(ctxPtr);
    if (!ctx) return nullptr;

    const char *lang = env->GetStringUTFChars(language, nullptr);
    const char *initialPrompt = env->GetStringUTFChars(prompt, nullptr);
    jsize n = env->GetArrayLength(samples);
    jfloat *pcm = env->GetFloatArrayElements(samples, nullptr);

    whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = threads;
    params.language = lang;
    params.translate = false;
    params.no_timestamps = true;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_special = false;
    params.print_timestamps = false;
    params.suppress_blank = true;
    if (initialPrompt[0] != '\0') params.initial_prompt = initialPrompt;

    std::string text;
    if (whisper_full(ctx, params, pcm, n) == 0) {
        const int segments = whisper_full_n_segments(ctx);
        for (int i = 0; i < segments; ++i) text += whisper_full_get_segment_text(ctx, i);
    }

    env->ReleaseFloatArrayElements(samples, pcm, JNI_ABORT);
    env->ReleaseStringUTFChars(language, lang);
    env->ReleaseStringUTFChars(prompt, initialPrompt);
    jbyteArray out = env->NewByteArray((jsize) text.size());
    env->SetByteArrayRegion(out, 0, (jsize) text.size(), reinterpret_cast<const jbyte *>(text.data()));
    return out;
}

// The language of the last transcription ("en", "de"…), as detected or as pinned.
extern "C" JNIEXPORT jstring JNICALL
Java_app_quoth_android_WhisperEngine_nativeLanguage(JNIEnv *env, jclass, jlong ctxPtr) {
    auto *ctx = reinterpret_cast<whisper_context *>(ctxPtr);
    const int id = ctx ? whisper_full_lang_id(ctx) : -1;
    return env->NewStringUTF(id >= 0 ? whisper_lang_str(id) : "");
}

extern "C" JNIEXPORT jstring JNICALL
Java_app_quoth_android_WhisperEngine_nativeSystemInfo(JNIEnv *env, jclass) {
    return env->NewStringUTF(whisper_print_system_info());
}
