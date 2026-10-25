package app.quoth.android

import app.quoth.core.Cancellable
import app.quoth.core.ChatMessage
import app.quoth.core.LLMClient
import java.io.File

/** llama.cpp on the phone's CPU, through libquoth.so: the on-device cleanup model. One instance per loaded model. */
class LlamaEngine private constructor(private var handle: Long) : LLMClient, Cancellable, AutoCloseable {

    /** Blocking; one completion at a time. The last message is the only one that changes between dictations. */
    @Synchronized
    override fun complete(messages: List<ChatMessage>, json: Boolean, maxTokens: Int): String {
        check(handle != 0L) { "engine closed" }
        val bytes = nativeComplete(handle, messages.map { it.role }.toTypedArray(),
            messages.map { it.content.toByteArray(Charsets.UTF_8) }.toTypedArray(), maxTokens)
            ?: throw IllegalStateException("cleanup model failed or was stopped")
        return String(bytes, Charsets.UTF_8).trim()
    }

    /** Stops a running completion (it then throws); called from another thread on timeout. */
    override fun cancel() {
        if (handle != 0L) nativeAbort(handle)
    }

    @Synchronized
    override fun close() {
        nativeFree(handle)
        handle = 0
    }

    companion object {
        init { System.loadLibrary("quoth") }

        /** 6k tokens: the ~2.5k-token static prompt plus a long dictation and its cleaned copy. */
        fun load(model: File, contextTokens: Int = 6144): LlamaEngine? =
            nativeLoad(model.absolutePath, contextTokens, WhisperEngine.threads()).takeIf { it != 0L }?.let(::LlamaEngine)

        @JvmStatic private external fun nativeLoad(path: String, nCtx: Int, threads: Int): Long
        @JvmStatic private external fun nativeFree(handle: Long)
        @JvmStatic private external fun nativeAbort(handle: Long)
        @JvmStatic private external fun nativeComplete(handle: Long, roles: Array<String>, contents: Array<ByteArray>, maxTokens: Int): ByteArray?
    }
}
