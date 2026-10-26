package app.quoth.android

import app.quoth.core.Cancellable
import app.quoth.core.ChatMessage
import app.quoth.core.LLMClient
import java.io.File

/** llama.cpp on the phone's CPU, through libquoth.so: the on-device cleanup model. One instance per loaded model. */
class LlamaEngine private constructor(private var handle: Long, private val promptCache: File?) : LLMClient, Cancellable, AutoCloseable {

    /** Blocking; one completion at a time. The last message is the only one that changes between dictations. */
    @Synchronized
    override fun complete(messages: List<ChatMessage>, json: Boolean, maxTokens: Int): String {
        check(handle != 0L) { "engine closed" }
        val bytes = nativeComplete(handle, messages.map { it.role }.toTypedArray(),
            messages.map { it.content.toByteArray(Charsets.UTF_8) }.toTypedArray(), maxTokens, promptCache?.absolutePath ?: "")
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

        /**
         * [contextTokens]: 6k fits the ~1.6k-token static prompt plus a long dictation and its cleaned copy.
         * [repack]: faster weight layouts, at the cost of a full copy of the weights in RAM.
         * [promptCache]: where the decoded static prompt is saved for the next start (it's checked against the prompt).
         */
        fun load(model: File, promptCache: File? = null, contextTokens: Int = 6144, repack: Boolean = true): LlamaEngine? =
            nativeLoad(model.absolutePath, contextTokens, WhisperEngine.threads(), repack).takeIf { it != 0L }
                ?.let { LlamaEngine(it, promptCache) }

        @JvmStatic private external fun nativeLoad(path: String, nCtx: Int, threads: Int, repack: Boolean): Long
        @JvmStatic private external fun nativeFree(handle: Long)
        @JvmStatic private external fun nativeAbort(handle: Long)
        @JvmStatic private external fun nativeComplete(handle: Long, roles: Array<String>, contents: Array<ByteArray>, maxTokens: Int, cacheFile: String): ByteArray?
    }
}
