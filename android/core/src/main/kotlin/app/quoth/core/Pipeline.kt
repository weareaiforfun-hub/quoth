package app.quoth.core

import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

// Port of Sources/QuothCore/Pipeline/DictationPipeline.swift. The engines are blocking calls here
// (whisper.cpp through JNI, llama.cpp or an HTTP API), run off the main thread by the caller.

data class TranscriptionResult(val text: String, val language: String? = null)

/** Speech to text. [samples] are 16 kHz mono floats in [-1, 1]. */
fun interface Transcriber {
    fun transcribe(samples: FloatArray, language: String?, prompt: String?): TranscriptionResult
}

/** A transcriber that can detect the spoken language on its own. */
interface LanguageDetecting {
    fun detectLanguage(samples: FloatArray): String?
}

/** Cleanup of a raw transcript (an LLM). */
fun interface Cleaner {
    fun clean(raw: String, level: CleanupLevel, context: CleanupContext): String
}

class CleanupTimeoutException : Exception("Timed out")

data class DictationOutcome(
    /** What the ASR heard (after removing non-speech tags). */
    var raw: String,
    /** The text that should be inserted. */
    var final: String = "",
    var language: String? = null,
    var asrMs: Long = 0,
    var llmMs: Long = 0,
    /** True when cleanup was skipped, failed, timed out or was rejected. */
    var usedFallback: Boolean = false,
    var fallbackReason: String? = null,
    /** Dictionary entries and snippets that fired (for usage ranking). */
    var firedEntries: List<String> = emptyList(),
    var firedSnippets: List<String> = emptyList(),
    /** Set when the detected language was outside the user's pinned set. */
    var detectedOutsideSet: String? = null,
)

/** audio → ASR → cleanup LLM → deterministic post-processing → final string. */
class DictationPipeline(
    val transcriber: Transcriber,
    val cleaner: Cleaner?,
    /** Base cleanup timeout (seconds); the effective timeout grows with dictation length. */
    val llmTimeout: Double,
    /**
     * Extra seconds allowed per word: the LLM must write every word back out, so a 250-word
     * dictation legitimately takes ~12 s on a local 14B model.
     */
    val llmSecondsPerWord: Double = 0.08,
) {
    fun effectiveTimeout(raw: String) = llmTimeout + OutputSanitizer.wordCount(raw) * llmSecondsPerWord

    fun run(samples: FloatArray, level: CleanupLevel, languages: List<String>, context: CleanupContext,
            personal: PersonalData = PersonalData()): DictationOutcome {
        val t0 = System.nanoTime()
        val quiet = AudioLevel.rms(samples) < AudioLevel.QUIET
        // Whisper mode: bring quiet speech up to a normal level before ASR.
        val audio = AudioGain.normalise(samples)
        // One language per dictation: pinned, or detected and constrained to the user's set.
        var language = if (languages.size == 1) languages[0] else null
        var outside: String? = null
        val detector = transcriber as? LanguageDetecting
        if (languages.size > 1 && detector != null) {
            val detected = runCatching { detector.detectLanguage(audio) }.getOrNull()
            if (detected != null && detected in languages) {
                language = detected
            } else {
                language = languages[0]
                outside = detected
            }
        }
        val bias = (context.vocabulary + context.identifiers.take(40)).joinToString(", ")
        val result = transcriber.transcribe(audio, language, bias.takeIf { it.isNotEmpty() }?.take(800))
        val raw = TranscriptFilter.clean(result.text, likelySilence = quiet)
        val outcome = DictationOutcome(raw = raw, language = language ?: result.language, asrMs = msSince(t0))
        outcome.detectedOutsideSet = outside
        if (raw.isEmpty()) return outcome
        outcome.final = process(raw, level, context.copy(language = outcome.language), personal, outcome)
        return outcome
    }

    /** Everything after ASR: cleanup + deterministic rules. Also used by retry and evals. */
    fun process(raw: String, level: CleanupLevel, context: CleanupContext, personal: PersonalData,
                outcome: DictationOutcome): String {
        // A snippet spoken on its own is inserted verbatim; no LLM needed.
        TextRules.snippetSpokenAlone(raw, personal.snippets)?.let {
            outcome.firedSnippets = listOf(it.id)
            return it.expansion
        }
        var input = raw
        if (context.isCodeEditor) {
            input = DevFormatting.spokenFilenames(input)
            input = DevFormatting.applyIdentifiers(input, context.identifiers)
        }
        // Apply replacements before the LLM too, so it sees (and keeps) the right spelling.
        val (preReplaced, preEntries) = TextRules.applyDictionary(input, personal.dictionary)
        input = preReplaced
        // Shield snippet triggers from the LLM with tokens.
        val (shielded, tokens) = TextRules.protectSnippets(input, personal.snippets)
        var text = cleanup(shielded, level, context, outcome)
        val firedSnippets = mutableListOf<String>()
        if (tokens.isNotEmpty()) {
            if (tokens.all { text.contains(it.token) }) {
                // Expanded at the very end (after style rules), so park them on private-use markers.
                tokens.forEachIndexed { i, t -> text = text.replace(t.token, "$i") }
            } else {
                // The LLM mangled a token: fall back to deterministic cleanup of the unshielded text.
                text = SpokenPunctuation.apply(input)
                outcome.usedFallback = true
                outcome.fallbackReason = "cleanup dropped a snippet"
            }
        }

        val (replaced, entries) = TextRules.applyDictionary(text, personal.dictionary)
        text = replaced
        outcome.firedEntries = (preEntries + entries).distinct()
        if (context.isCodeEditor) text = DevFormatting.applyIdentifiers(text, context.identifiers)
        val protectedWords = personal.dictionary.map { it.output }
        text = StyleRules.apply(text, context.tone, context.category, context.hasSelection, protectedWords,
            rawTarget = context.preferRawFormatting || context.isCodeEditor)
        text = Continuation.apply(text, context.textBeforeCursor, context.textAfterCursor, protectedWords)
        text = LanguageRules.apply(text, context.language, context.variant, context.isCodeEditor)
        tokens.forEachIndexed { i, t ->
            val marker = "$i"
            if (text.contains(marker)) {
                text = text.replace(marker, t.snippet.expansion)
                firedSnippets += t.snippet.id
            }
        }
        val (expanded, snippets) = TextRules.expandSnippets(text, personal.snippets)
        text = expanded
        outcome.firedSnippets = firedSnippets + snippets
        // Spec: any dictionary or snippet substitution disables file tagging for this dictation.
        if (context.isFileTaggingEditor && outcome.firedEntries.isEmpty() && outcome.firedSnippets.isEmpty()) {
            text = DevFormatting.tagFiles(text)
        }
        return text
    }

    /** LLM cleanup with timeout and safety fallbacks. */
    fun cleanup(raw: String, level: CleanupLevel, context: CleanupContext, outcome: DictationOutcome): String {
        val fallback = SpokenPunctuation.apply(raw)
        if (level == CleanupLevel.NONE || cleaner == null) {
            outcome.usedFallback = level != CleanupLevel.NONE
            outcome.fallbackReason = if (level == CleanupLevel.NONE) null else "no cleaner configured"
            return fallback
        }
        val t1 = System.nanoTime()
        val askedForLines = SpokenPunctuation.applyLineBreaks(raw).contains("\n") || ListDetector.isEnumeration(raw)
        fun attempt(ctx: CleanupContext): String {
            val out = withTimeout(effectiveTimeout(raw)) { cleaner.clean(SpokenPunctuation.applyLineBreaks(raw), level, ctx) }
            var cleaned = ListDetector.restoreLeadIn(ListDetector.repairNumbering(OutputSanitizer.sanitize(out, raw)), raw)
            if (ctx.category != StyleCategory.EMAIL) cleaned = Greeting.joinOutsideEmail(cleaned)
            if (!askedForLines && ctx.category != StyleCategory.EMAIL && cleaned.contains("\n")) {
                cleaned = ListDetector.flattenUnrequested(cleaned)
            }
            return cleaned
        }
        return try {
            var cleaned = attempt(context)
            if (cleaned.isNotEmpty() && OutputSanitizer.looksLikeAnswer(cleaned, raw, level, context.variant)) {
                // Small models sometimes carry out a dictated request. Code decides that, and asks once more.
                cleaned = attempt(context.copy(answeredBefore = true))
            }
            outcome.llmMs = msSince(t1)
            if (cleaned.isEmpty() || OutputSanitizer.looksLikeAnswer(cleaned, raw, level, context.variant)) {
                outcome.usedFallback = true
                outcome.fallbackReason = if (cleaned.isEmpty()) "empty cleanup" else "cleanup added content"
                fallback
            } else cleaned
        } catch (e: Exception) {
            outcome.llmMs = msSince(t1)
            outcome.usedFallback = true
            outcome.fallbackReason = e.message ?: e.javaClass.simpleName
            fallback
        }
    }

    private companion object {
        val pool = Executors.newCachedThreadPool { Thread(it, "quoth-cleanup").apply { isDaemon = true } }

        fun msSince(t: Long) = (System.nanoTime() - t) / 1_000_000

        fun <T> withTimeout(seconds: Double, op: () -> T): T {
            val future = pool.submit<T> { op() }
            try {
                return future.get((seconds * 1000).toLong(), TimeUnit.MILLISECONDS)
            } catch (e: TimeoutException) {
                future.cancel(true)
                throw CleanupTimeoutException()
            } catch (e: ExecutionException) {
                throw e.cause as? Exception ?: e
            }
        }
    }
}
