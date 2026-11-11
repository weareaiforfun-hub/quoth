package app.quoth.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI

// Port of the OpenAI-compatible client in Sources/QuothCore/Cleanup/Cleaner.swift (ChatCompletionsCleaner).
// It serves the cloud option, and the Mac's llama-server in the JVM evals.

/** A chat model. Cleanup (and later Command Mode and Transforms) go through this. */
interface LLMClient : Cleaner {
    fun complete(messages: List<ChatMessage>, json: Boolean, maxTokens: Int): String

    override fun clean(raw: String, level: CleanupLevel, context: CleanupContext): String =
        complete(CleanupPrompt.messages(raw, level, context), json = false, maxTokens = maxTokens(raw))
}

/** Cleanup output is never much longer than the input; cap generation so a runaway answer is cut short. */
internal fun maxTokens(raw: String) = maxOf(64, OutputSanitizer.wordCount(raw) * 3 + 32)

class HttpException(val code: Int, body: String) : IOException("HTTP $code: ${body.take(200)}")

/** `/chat/completions` on any OpenAI-compatible API (Groq, OpenAI, OpenRouter, llama-server…). */
class ChatCompletionsClient(
    private val baseURL: String,
    val model: String,
    private val apiKey: String? = null,
    private val timeoutMs: Int = 300_000,
) : LLMClient {

    @Serializable
    private class Request(
        val model: String,
        val messages: List<ChatMessage>,
        val temperature: Double = 0.0,
        val max_tokens: Int,
        val stream: Boolean = false,
        val response_format: Format? = null,
    )

    @Serializable
    private class Format(val type: String = "json_object")

    @Serializable
    private class Response(val choices: List<Choice>) {
        @Serializable class Choice(val message: Message)
        @Serializable class Message(val content: String? = null)
    }

    override fun complete(messages: List<ChatMessage>, json: Boolean, maxTokens: Int): String {
        val body = JSON.encodeToString(Request.serializer(),
            Request(model, messages, max_tokens = maxTokens, response_format = if (json) Format() else null))
        val conn = URI(baseURL.trimEnd('/') + "/chat/completions").toURL().openConnection() as HttpURLConnection
        try {
            conn.requestMethod = "POST"
            conn.connectTimeout = 10_000
            conn.readTimeout = timeoutMs
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            if (!apiKey.isNullOrEmpty()) conn.setRequestProperty("Authorization", "Bearer $apiKey")
            conn.outputStream.use { it.write(body.toByteArray()) }
            val code = conn.responseCode
            val text = (if (code in 200..299) conn.inputStream else conn.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
            if (code !in 200..299) throw HttpException(code, text)
            val content = runCatching { JSON.decodeFromString(Response.serializer(), text).choices.firstOrNull()?.message?.content }
                .getOrNull() ?: throw IOException("Unexpected response: ${text.take(200)}")
            return content
        } finally {
            conn.disconnect()
        }
    }

    companion object {
        private val JSON = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true }

        /** The model a llama-server (or other OpenAI-compatible server) is serving: `/models` → {"data":[{"id":"…"}]}. */
        fun servedModels(baseURL: String): List<String> {
            val conn = URI(baseURL.trimEnd('/') + "/models").toURL().openConnection() as HttpURLConnection
            conn.connectTimeout = 2_000
            conn.readTimeout = 5_000
            return try {
                JSON.decodeFromString(ModelList.serializer(), conn.inputStream.bufferedReader().use { it.readText() }).data.map { it.id }
            } catch (e: IOException) {
                emptyList()
            } finally {
                conn.disconnect()
            }
        }
    }
}

@Serializable
private class ModelList(val data: List<Entry>) {
    @Serializable class Entry(val id: String)
}
