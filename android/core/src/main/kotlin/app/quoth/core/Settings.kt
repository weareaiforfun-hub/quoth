package app.quoth.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID

// The Android app's settings and dictation history. Field names follow the Mac's Settings.swift where
// the setting exists there too (cleanupLevel, languages, languageVariant, retention, contextAwareness).

@Serializable
enum class Retention(val title: String) {
    /** Keep the text of past dictations (no audio is stored on Android). */
    @SerialName("normal") NORMAL("Keep"),
    @SerialName("day") DAY("Delete after 24 hours"),
    @SerialName("never") NEVER("Never store"),
}

@Serializable
data class AppSettings(
    /** CleanupLevel.raw. Light needs the cleanup model; without it Quoth uses None. */
    val cleanupLevel: String = CleanupLevel.LIGHT.raw,
    /** The cleanup model's file name (one of ModelCatalog.cleanup), or "" for none. */
    val cleanupModel: String = ModelCatalog.qwen35_2b.file,
    /** Empty = detect any language. One = pinned (faster). Several = detect, but only among these. */
    val languages: List<String> = emptyList(),
    /** LanguageVariant.raw. */
    val languageVariant: String = LanguageVariant.NONE.raw,
    val retention: Retention = Retention.NORMAL,
    /** Use the text around the cursor to continue sentences naturally. */
    val contextAwareness: Boolean = true,
) {
    val level: CleanupLevel get() = CleanupLevel.of(cleanupLevel) ?: CleanupLevel.LIGHT
    val variant: LanguageVariant get() = LanguageVariant.of(languageVariant) ?: LanguageVariant.NONE
    val cleanup: ModelFile? get() = ModelCatalog.cleanup.firstOrNull { it.file == cleanupModel }
}

/** A JSON file holding one value, read once and written on every change (atomically). */
class JsonFile<T>(private val file: File, private val serializer: kotlinx.serialization.KSerializer<T>, private val default: () -> T) {
    private var cached: T? = null

    @get:Synchronized
    val value: T get() = cached ?: load().also { cached = it }

    private fun load(): T = runCatching { JSON.decodeFromString(serializer, file.readText()) }.getOrElse { default() }

    @Synchronized
    fun update(change: (T) -> T): T {
        val next = change(value)
        cached = next
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeText(JSON.encodeToString(serializer, next))
        if (!tmp.renameTo(file)) { file.delete(); tmp.renameTo(file) }
        return next
    }

    internal companion object {
        val JSON = Json { ignoreUnknownKeys = true; prettyPrint = true; explicitNulls = false; encodeDefaults = true }
    }
}

/** One dictation, as History shows it. Text only: no audio is kept. */
@Serializable
data class HistoryEntry(
    val id: String = UUID.randomUUID().toString(),
    /** Milliseconds since 1970. */
    val createdAt: Long,
    /** What the speech model heard. */
    val raw: String,
    /** What was inserted. */
    val final: String,
    /** The target app's package name and label. */
    val app: String? = null,
    val appName: String? = null,
    val asrMs: Long = 0,
    val llmMs: Long = 0,
    /** Why cleanup was skipped or rejected, if it was. */
    val fallbackReason: String? = null,
) {
    val words: Int get() = OutputSanitizer.wordCount(final)
}

@Serializable
private data class HistoryFile(val entries: List<HistoryEntry> = emptyList())

/** Past dictations, newest first, capped at [limit] and purged by the user's [Retention]. */
class HistoryStore(file: File, private val limit: Int = 1000) {
    private val store = JsonFile(file, HistoryFile.serializer()) { HistoryFile() }

    fun recent(): List<HistoryEntry> = store.value.entries

    fun add(entry: HistoryEntry, retention: Retention, now: Long = System.currentTimeMillis()) {
        store.update { h ->
            val kept = if (retention == Retention.NEVER) emptyList() else (listOf(entry) + h.entries).take(limit)
            HistoryFile(purged(kept, retention, now))
        }
    }

    fun delete(id: String) {
        store.update { h -> HistoryFile(h.entries.filter { it.id != id }) }
    }

    fun clear() {
        store.update { HistoryFile() }
    }

    /** Applies a (possibly just changed) retention setting to what's stored. */
    fun purge(retention: Retention, now: Long = System.currentTimeMillis()) {
        if (store.value.entries.isEmpty()) return
        store.update { h -> HistoryFile(purged(h.entries, retention, now)) }
    }

    private fun purged(entries: List<HistoryEntry>, retention: Retention, now: Long) = when (retention) {
        Retention.NORMAL -> entries
        Retention.DAY -> entries.filter { now - it.createdAt < 24 * 3_600_000L }
        Retention.NEVER -> emptyList()
    }
}

/** Languages for the picker: ISO 639-1 codes and names (the Mac's list; whisper supports ~100). */
object Languages {
    val all = listOf(
        "en" to "English", "de" to "German", "fr" to "French", "es" to "Spanish", "it" to "Italian",
        "pt" to "Portuguese", "nl" to "Dutch", "fa" to "Persian", "ar" to "Arabic", "hi" to "Hindi",
        "ur" to "Urdu", "zh" to "Chinese", "ja" to "Japanese", "ko" to "Korean", "ru" to "Russian",
        "uk" to "Ukrainian", "tr" to "Turkish", "pl" to "Polish", "sv" to "Swedish", "da" to "Danish",
        "no" to "Norwegian", "fi" to "Finnish", "cs" to "Czech", "el" to "Greek", "he" to "Hebrew",
        "id" to "Indonesian", "ms" to "Malay", "th" to "Thai", "vi" to "Vietnamese", "ro" to "Romanian",
        "hu" to "Hungarian", "bn" to "Bengali", "ta" to "Tamil", "tl" to "Tagalog", "ca" to "Catalan",
        "yue" to "Cantonese",
    )

    fun name(code: String) = all.firstOrNull { it.first == code }?.second ?: code
}
