package app.quoth.core

import kotlin.math.abs
import kotlin.math.min
import kotlin.math.sqrt

// Ports of Sources/QuothCore/PostProcess, AudioLevel (DictationPipeline.swift) and AudioGain (AutoLearn.swift).
// Keep them in step with the Swift.

object TranscriptFilter {
    private val hallucinations = setOf("thank you.", "thanks for watching!", "thank you for watching.", "you", ".")

    /** Removes whisper's non-speech tags, and (for near-silent audio) its stock hallucinations. */
    fun clean(text: String, likelySilence: Boolean = false): String {
        val s = text.re("""\[[^\]]*\]|\((?:music|silence|applause|laughs?|inaudible|blank_audio|(?:speaking in )?(?:a )?foreign language)[^)]*\)""", "", ignoreCase = true)
            .re("""\s+""", " ").trim()
        if (likelySilence && s.lowercase() in hallucinations) return ""
        return s
    }
}

object AudioLevel {
    fun rms(samples: FloatArray): Float {
        if (samples.isEmpty()) return 0f
        var sum = 0f
        for (s in samples) sum += s * s
        return sqrt(sum / samples.size)
    }

    /** Below this RMS a recording is treated as silence (the same threshold as the Mac). */
    const val QUIET = 0.004f
}

object AudioGain {
    /** Whisper mode: boost quiet recordings so whispered speech reaches the model at a normal level. */
    fun normalise(samples: FloatArray, targetPeak: Float = 0.7f, maxGain: Float = 10f): FloatArray {
        var peak = 0f
        for (s in samples) peak = maxOf(peak, abs(s))
        if (peak <= 0.001f || peak >= targetPeak / 2) return samples
        val gain = min(maxGain, targetPeak / peak)
        return FloatArray(samples.size) { samples[it] * gain }
    }
}

/**
 * Deterministic spoken-punctuation handling, used for cleanup level None
 * and as the fallback when the LLM is unavailable.
 */
object SpokenPunctuation {
    // Longest phrases first so "new paragraph" wins over "new line" style overlaps.
    private val rules = listOf(
        "new paragraph" to "\n\n",
        "exclamation point" to "!",
        "exclamation mark" to "!",
        "question mark" to "?",
        "line break" to "\n",
        "next line" to "\n",
        "new line" to "\n",
        "full stop" to ".",
        "semicolon" to ";",
        "period" to ".",
        "comma" to ",",
        "colon" to ":",
    )

    fun apply(text: String): String {
        var s = text
        for ((phrase, symbol) in rules) {
            // Whisper often decorates the spoken word itself: "Comma." / ", comma," – eat that too.
            s = s.re("""[,.]?\s*\b${Regex.escape(phrase)}\b[,.!?]?""", Regex.escapeReplacement(symbol), ignoreCase = true)
        }
        return tidy(s)
    }

    /**
     * Converts only the unambiguous line-break commands, before the LLM sees the text.
     * Small models often leave "new paragraph" in the output; these phrases are almost never meant literally.
     */
    fun applyLineBreaks(text: String): String {
        var s = text
        for ((phrase, symbol) in rules.filter { it.second.startsWith("\n") }) {
            s = s.re("""[,.]?\s*\b${Regex.escape(phrase)}\b[,.]?\s*""", Regex.escapeReplacement(symbol), ignoreCase = true)
        }
        return s.trim()
    }

    /** Fix spacing around punctuation and capitalise sentence starts. */
    internal fun tidy(text: String): String {
        var s = text
        s = s.re("""[ \t]+([,.!?;:])""", "$1")
        s = s.re("""([,.!?;:])(?=[A-Za-z])""", "$1 ")
        s = s.re("""[ \t]*\n[ \t]*""", "\n")
        s = s.re("""[ \t]{2,}""", " ")
        s = s.trimSpaces()
        return capitaliseSentences(s)
    }

    internal fun capitaliseSentences(text: String): String {
        val out = StringBuilder()
        var capNext = true
        for (ch in text) {
            if (capNext && ch.isLetter()) {
                out.append(ch.uppercase())
                capNext = false
                continue
            }
            out.append(ch)
            if (ch in ".!?\n") capNext = true else if (!ch.isWhitespace()) capNext = false
        }
        return out.toString()
    }
}

object OutputSanitizer {
    /** Strips artefacts small LLMs add around the cleaned text. */
    fun sanitize(output: String, raw: String): String {
        var s = output.trim().re("</?transcript>", "")
        // Drop a preamble line such as "Here is the cleaned text:".
        val first = s.substringBefore("\n")
        if (first.matches("""^(here('s| is)|sure|cleaned( text| transcript)?|output)\b.*:\s*$""", ignoreCase = true)) {
            s = s.substring(first.length)
        }
        s = s.trim()
        // Unwrap quotes the speaker did not dictate.
        for ((o, c) in listOf("\"" to "\"", "“" to "”", "'" to "'")) {
            if (s.length > 2 && s.startsWith(o) && s.endsWith(c)) {
                val inner = s.substring(1, s.length - 1)
                if (!inner.contains(o) && !raw.lowercase().contains("quote")) s = inner
            }
        }
        // Spec: never insert em dashes automatically.
        if (!raw.lowercase().contains("dash")) s = s.re("""\s*—\s*""", ", ")
        return s.trim()
    }

    /**
     * Heuristic for "the model answered or embellished instead of cleaning".
     * Cleanup only removes or rearranges words, so a much longer output is suspicious,
     * and so is one made mostly of words the speaker never said: a short answer such as
     * a joke is no longer than the request, but shares almost none of its words.
     */
    fun looksLikeAnswer(output: String, raw: String, level: CleanupLevel = CleanupLevel.LIGHT,
                        variant: LanguageVariant = LanguageVariant.NONE): Boolean {
        val rawWords = wordCount(raw)
        val outWords = wordCount(output)
        if (outWords > (rawWords * 1.4).toInt() + 6) return true
        // Word overlap means nothing when cleanup is asked to change the script (Devanagari → Latin,
        // Traditional ↔ Simplified) or did so anyway.
        if (variant in setOf(LanguageVariant.HINGLISH, LanguageVariant.ZH_HANS, LanguageVariant.ZH_HANT) ||
            dominantScript(raw) != dominantScript(output)) return false
        val said = tokens(raw)
        val saidSet = said.toSet()
        val saidJoined = said.joinToString("")
        // Digits come from spoken numbers; substring matches cover joined words and unspaced scripts.
        val words = tokens(output).filterNot { w -> w.all { it.isDigit() } }
        if (words.size < 4) return false
        val unsaid = words.count { it !in saidSet && !saidJoined.contains(it) }
        // Medium may reword, so only output that is almost entirely new counts as an answer.
        return if (level == CleanupLevel.MEDIUM) unsaid * 4 > words.size * 3 else unsaid * 2 > words.size
    }

    /** Lowercased runs of letters (with their combining marks) and digits. */
    internal fun tokens(s: String): List<String> {
        val out = mutableListOf<String>()
        val cur = StringBuilder()
        s.lowercase().replace("ß", "ss").codePoints().forEach { cp ->
            val type = Character.getType(cp)
            val keep = Character.isLetter(cp) || Character.isDigit(cp) || type == Character.NON_SPACING_MARK.toInt() ||
                type == Character.COMBINING_SPACING_MARK.toInt() || type == Character.ENCLOSING_MARK.toInt()
            if (keep) cur.appendCodePoint(cp) else if (cur.isNotEmpty()) { out += cur.toString(); cur.clear() }
        }
        if (cur.isNotEmpty()) out += cur.toString()
        return out
    }

    private val scripts = listOf(
        Character.UnicodeScript.LATIN, Character.UnicodeScript.HAN, Character.UnicodeScript.DEVANAGARI,
        Character.UnicodeScript.CYRILLIC, Character.UnicodeScript.ARABIC, Character.UnicodeScript.HIRAGANA,
        Character.UnicodeScript.KATAKANA, Character.UnicodeScript.HANGUL, Character.UnicodeScript.GREEK,
        Character.UnicodeScript.HEBREW, Character.UnicodeScript.THAI,
    )

    /** The script most of the characters are written in, or null when there are none. */
    internal fun dominantScript(s: String): Character.UnicodeScript? {
        val counts = s.codePoints().toArray().toList().groupingBy { Character.UnicodeScript.of(it) }.eachCount()
        val best = scripts.maxByOrNull { counts[it] ?: 0 } ?: return null
        return if ((counts[best] ?: 0) > 0) best else null
    }

    fun wordCount(s: String): Int = s.split(Regex("\\s+")).count { it.isNotEmpty() }
}
