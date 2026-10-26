package app.quoth.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

// Port of the cleanup scoring in Sources/QuothCore/Models/ModelBench.swift: the golden evals
// (Evals/cleanup-golden.jsonl) and, later, the in-app model comparison.

@Serializable
data class CleanupCase(
    val id: String,
    val category: String,
    val raw: String,
    val expected: String,
    val must_not_contain: List<String>? = null,
    val max_words: Int? = null,
    val alt: List<String>? = null,
    // Optional context
    val bundle: String? = null,
    val window: String? = null,
    val tone: String? = null,
    val before: String? = null,
    val vocab: List<String>? = null,
    val identifiers: List<String>? = null,
    val replacements: Map<String, String>? = null,
    val snippets: Map<String, String>? = null,
) {
    val accepted: List<String> get() = listOf(expected) + (alt ?: emptyList())

    val context: CleanupContext
        get() = CleanupContext(bundleID = bundle, windowTitle = window, category = StyleCategory.detect(bundle, window),
            tone = StyleTone.of(tone), textBeforeCursor = before, vocabulary = vocab ?: emptyList(),
            identifiers = identifiers ?: emptyList())

    val personal: PersonalData
        get() = PersonalData(
            dictionary = (vocab ?: emptyList()).map { DictionaryEntry.word(it) } +
                (replacements ?: emptyMap()).toSortedMap().map { (k, v) -> DictionaryEntry.replacement(k, v) },
            snippets = (snippets ?: emptyMap()).toSortedMap().map { (k, v) -> Snippet(trigger = k, expansion = v) },
        )

    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        fun load(jsonl: String): List<CleanupCase> =
            jsonl.lines().filter { it.isNotBlank() }.mapNotNull { runCatching { json.decodeFromString(serializer(), it) }.getOrNull() }
    }
}

data class CleanupVerdict(
    /** Identical apart from spacing. */
    val exact: Boolean,
    /** Same words; punctuation or case may differ. */
    val sameWords: Boolean,
    /** Answered, added content, dropped protected text, or fell back. */
    val problems: List<String>,
) {
    val serious: Boolean get() = problems.isNotEmpty()
    val symbol: String get() = if (serious) "✗" else if (exact) "✓" else if (sameWords) "≈" else "·"
}

data class CleanupResult(val caseID: String, val model: String, val output: String, val ms: Long, val verdict: CleanupVerdict)

data class CleanupSummary(val model: String, val cases: Int, val exact: Int, val sameWords: Int, val serious: Int,
                          val p50ms: Long, val p90ms: Long)

object ModelBench {
    internal fun strict(s: String) = s.re("[ \\t]+", " ").trim()

    internal fun loose(s: String) = s.lowercase().re("""[^\p{L}\p{N}]+""", " ").trimSpaces()

    fun score(output: String, c: CleanupCase, outcome: DictationOutcome): CleanupVerdict {
        val problems = mutableListOf<String>()
        for (bad in c.must_not_contain ?: emptyList()) if (output.lowercase().contains(bad.lowercase())) problems += "contains \"$bad\""
        c.max_words?.let { if (OutputSanitizer.wordCount(output) > it) problems += "too long" }
        if (outcome.usedFallback) problems += "fallback: ${outcome.fallbackReason ?: "?"}"
        return CleanupVerdict(exact = c.accepted.any { strict(output) == strict(it) },
            sameWords = c.accepted.any { loose(output) == loose(it) }, problems = problems)
    }

    /** Runs the cleanup stage of the real pipeline (same rules as the app) for one model. */
    fun runCleanup(cleaner: Cleaner, model: String, cases: List<CleanupCase>, level: CleanupLevel = CleanupLevel.LIGHT,
                   timeout: Double = 60.0, onResult: (CleanupResult) -> Unit = {}): List<CleanupResult> {
        val pipeline = DictationPipeline({ _, _, _ -> TranscriptionResult("") }, cleaner, llmTimeout = timeout)
        return cases.map { c ->
            val outcome = DictationOutcome(raw = c.raw)
            val text = runCatching { pipeline.process(c.raw, level, c.context, c.personal, outcome) }.getOrDefault("")
            CleanupResult(c.id, model, text, outcome.llmMs, score(text, c, outcome)).also(onResult)
        }
    }

    fun summarize(results: List<CleanupResult>, model: String): CleanupSummary {
        val mine = results.filter { it.model == model }
        val ms = mine.map { it.ms }.sorted()
        fun pct(p: Double) = if (ms.isEmpty()) 0 else ms[minOf(ms.size - 1, (ms.size * p).toInt())]
        return CleanupSummary(model, mine.size, mine.count { it.verdict.exact }, mine.count { it.verdict.sameWords },
            mine.count { it.verdict.serious }, pct(0.5), pct(0.9))
    }
}
