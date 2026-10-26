package app.quoth.android

import java.io.File

/** whisper.cpp on the phone's CPU, through libquoth.so. One instance per loaded model. */
class WhisperEngine private constructor(private var ctx: Long) : AutoCloseable {

    /** Transcribes 16 kHz mono samples in [-1, 1]. Blocking: call it off the main thread. */
    @Synchronized
    fun transcribe(samples: FloatArray, language: String = "auto", prompt: String = ""): String {
        check(ctx != 0L) { "engine closed" }
        val bytes = nativeTranscribe(ctx, samples, language, prompt, threads())
        lastLanguage = nativeLanguage(ctx).takeIf { it.isNotEmpty() }
        return bytes?.let { String(it, Charsets.UTF_8).trim() } ?: ""
    }

    /** The language of the last transcription, as detected (language "auto") or pinned. */
    var lastLanguage: String? = null
        private set

    @Synchronized
    override fun close() {
        nativeFree(ctx)
        ctx = 0
    }

    companion object {
        init { System.loadLibrary("quoth") }

        fun load(model: File): WhisperEngine? = nativeInit(model.absolutePath).takeIf { it != 0L }?.let(::WhisperEngine)

        val systemInfo: String get() = nativeSystemInfo()

        /** Big cores only: phones have 2–4 fast cores, and spreading onto the slow ones makes whisper slower. */
        fun threads() = Runtime.getRuntime().availableProcessors().coerceIn(2, 4)

        @JvmStatic private external fun nativeInit(modelPath: String): Long
        @JvmStatic private external fun nativeFree(ctx: Long)
        @JvmStatic private external fun nativeTranscribe(ctx: Long, samples: FloatArray, language: String, prompt: String, threads: Int): ByteArray?
        @JvmStatic private external fun nativeSystemInfo(): String
        @JvmStatic private external fun nativeLanguage(ctx: Long): String
    }
}
