package app.quoth.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID

// Port of Sources/QuothCore/Personal/PersonalData.swift. The JSON keys match the Mac's personal.json,
// so the data can later move between Mac and Android.

/** Seconds since 2001-01-01, the way Swift's JSONEncoder writes a Date by default. */
internal fun appleNow() = System.currentTimeMillis() / 1000.0 - 978_307_200.0

/** Dictionary entry: a spelling hint ("Kubernetes") or a replacement ("cube control" → "kubectl"). */
@Serializable
data class DictionaryEntry(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val kind: Kind,
    /** The word itself, or the spoken phrase for a replacement. */
    val phrase: String,
    /** Output for a replacement entry. */
    val replacement: String? = null,
    val starred: Boolean = false,
    val uses: Int = 0,
    val autoLearned: Boolean = false,
    val createdAt: Double = appleNow(),
) {
    @Serializable
    enum class Kind { @SerialName("word") WORD, @SerialName("replacement") REPLACEMENT }

    /** The text this entry produces (what ASR/LLM should spell). */
    val output: String get() = if (kind == Kind.WORD) phrase else replacement ?: phrase

    companion object {
        fun word(word: String, starred: Boolean = false, autoLearned: Boolean = false) =
            DictionaryEntry(kind = Kind.WORD, phrase = word, starred = starred, autoLearned = autoLearned)

        fun replacement(spoken: String, replacement: String) =
            DictionaryEntry(kind = Kind.REPLACEMENT, phrase = spoken, replacement = replacement)
    }
}

@Serializable
data class Snippet(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val trigger: String,
    val expansion: String,
)

/** A user-defined Transform prompt. */
@Serializable
data class TransformPrompt(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val name: String,
    val instruction: String,
    /** Up to 5 writing samples whose voice the output should match. */
    val samples: List<String> = emptyList(),
)

@Serializable
data class PolishRules(
    val concise: Boolean = true,
    val clarity: Boolean = true,
    val reorder: Boolean = false,
    val structure: Boolean = false,
    val maintainTone: Boolean = true,
    val clarifyMainPoint: Boolean = false,
    val impact: Boolean = false,
    /** Up to 5 custom instructions (≤50 words each). */
    val custom: List<String> = emptyList(),
)

/** Everything personal: dictionary, snippets, styles and transforms. Stored as one JSON file. */
@Serializable
data class PersonalData(
    val dictionary: List<DictionaryEntry> = emptyList(),
    val snippets: List<Snippet> = emptyList(),
    /** Words the user deleted; auto-learn never re-adds them. */
    val deletedWords: List<String> = emptyList(),
    val styles: StylePrefs = StylePrefs(),
    val polish: PolishRules = PolishRules(),
    val transforms: List<TransformPrompt> = emptyList(),
    /** Transform run on every dictation before it's inserted: "polish", "prompt", or a custom transform ID. */
    val autoApplyTransform: String? = null,
    val autoLearn: Boolean = true,
) {
    /** Words to bias ASR toward: starred first, then most used, within a character budget. */
    fun vocabulary(budget: Int = 600): List<String> {
        val sorted = dictionary.sortedWith(compareByDescending<DictionaryEntry> { it.starred }.thenByDescending { it.uses })
        val out = mutableListOf<String>()
        var used = 0
        for (e in sorted) {
            val w = e.output
            if (used + w.length + 2 > budget) break
            if (w !in out) { out += w; used += w.length + 2 }
        }
        return out
    }

    /** Counts a use for each dictionary entry that fired (Dictionary shows it, and vocabulary() ranks by it). */
    fun countingUses(fired: Collection<String>): PersonalData =
        if (fired.isEmpty()) this else copy(dictionary = dictionary.map { if (it.id in fired) it.copy(uses = it.uses + 1) else it })

    /** Adds a dictionary entry if it's valid; a word the user re-adds is no longer on the deleted list. */
    fun adding(entry: DictionaryEntry): Pair<PersonalData, ValidationError?> {
        validate(entry)?.let { return this to it }
        return copy(dictionary = dictionary + entry,
            deletedWords = deletedWords.filterNot { it.equals(entry.output, ignoreCase = true) }) to null
    }

    /** Adds auto-learned words that pass validation; returns the new data and the words actually added. */
    fun learning(words: List<String>): Pair<PersonalData, List<String>> {
        var p = this
        val added = mutableListOf<String>()
        for (w in words) {
            val (next, error) = p.adding(DictionaryEntry.word(w, autoLearned = true))
            if (error == null) { p = next; added += w }
        }
        return p to added
    }

    /** Removes an entry; deleted words are never re-added by auto-learn. */
    fun deleting(id: String): PersonalData {
        val e = dictionary.firstOrNull { it.id == id } ?: return this
        return copy(dictionary = dictionary - e, deletedWords = deletedWords + e.output)
    }

    /** Adds a snippet, with the Mac's limits; returns an error message instead when it can't. */
    fun addingSnippet(trigger: String, expansion: String): Pair<PersonalData, String?> {
        val t = trigger.trim()
        return when {
            t.isEmpty() || expansion.isBlank() -> this to "Needs a trigger and the text"
            t.length > 60 -> this to "Trigger: 60 characters at most"
            expansion.length > 4000 -> this to "Text: 4,000 characters at most"
            snippets.any { it.trigger.equals(t, ignoreCase = true) } -> this to "That trigger exists"
            else -> copy(snippets = snippets + Snippet(trigger = t, expansion = expansion)) to null
        }
    }

    enum class ValidationError(val message: String) {
        EMPTY("Can't be empty"),
        TOO_LONG("60 characters at most"),
        SYMBOLS_ONLY("Needs at least one letter or digit"),
        DUPLICATE("Already in your dictionary"),
    }

    /** Spec 2.3: ≤60 chars per field; reject empty, whitespace-only, symbol-only and duplicates. */
    fun validate(entry: DictionaryEntry): ValidationError? {
        for (field in listOfNotNull(entry.phrase, entry.replacement)) {
            val t = field.trim()
            if (t.isEmpty()) return ValidationError.EMPTY
            if (t.length > 60) return ValidationError.TOO_LONG
            if (t.none { it.isLetterOrDigit() }) return ValidationError.SYMBOLS_ONLY
        }
        if (entry.kind == DictionaryEntry.Kind.REPLACEMENT && entry.replacement.isNullOrEmpty()) return ValidationError.EMPTY
        val key = entry.phrase.lowercase().trimSpaces()
        if (dictionary.any { it.id != entry.id && it.kind == entry.kind && it.phrase.lowercase() == key }) {
            return ValidationError.DUPLICATE
        }
        return null
    }
}

object PersonalStore {
    internal val json = Json { ignoreUnknownKeys = true; prettyPrint = true; explicitNulls = false; encodeDefaults = true }

    fun load(file: File): PersonalData =
        runCatching { json.decodeFromString(PersonalData.serializer(), file.readText()) }.getOrDefault(PersonalData())

    fun save(p: PersonalData, file: File) {
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeText(json.encodeToString(PersonalData.serializer(), p))
        if (!tmp.renameTo(file)) { file.delete(); tmp.renameTo(file) }
    }
}
