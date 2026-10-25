package app.quoth.core

import kotlin.math.sqrt

// Ports of Sources/QuothCore/PostProcess and AudioLevel (DictationPipeline.swift). Keep them in step with the Swift.

object TranscriptFilter {
    private val tags = Regex("""\[[^\]]*\]|\((?:music|silence|applause|laughs?|inaudible|blank_audio)[^)]*\)""", RegexOption.IGNORE_CASE)
    private val hallucinations = setOf("thank you.", "thanks for watching!", "thank you for watching.", "you", ".")

    /** Removes whisper's non-speech tags, and (for near-silent audio) its stock hallucinations. */
    fun clean(text: String, likelySilence: Boolean = false): String {
        val s = text.replace(tags, "").replace(Regex("""\s+"""), " ").trim()
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
            val re = Regex("""[,.]?\s*\b${Regex.escape(phrase)}\b[,.!?]?""", RegexOption.IGNORE_CASE)
            s = s.replace(re, Regex.escapeReplacement(symbol))
        }
        return tidy(s)
    }

    /** Converts only the unambiguous line-break commands, before the LLM sees the text. */
    fun applyLineBreaks(text: String): String {
        var s = text
        for ((phrase, symbol) in rules.filter { it.second.startsWith("\n") }) {
            val re = Regex("""[,.]?\s*\b${Regex.escape(phrase)}\b[,.]?\s*""", RegexOption.IGNORE_CASE)
            s = s.replace(re, Regex.escapeReplacement(symbol))
        }
        return s.trim()
    }

    /** Fix spacing around punctuation and capitalise sentence starts. */
    internal fun tidy(text: String): String {
        var s = text
        s = s.replace(Regex("""[ \t]+([,.!?;:])"""), "$1")
        s = s.replace(Regex("""([,.!?;:])(?=[A-Za-z])"""), "$1 ")
        s = s.replace(Regex("""[ \t]*\n[ \t]*"""), "\n")
        s = s.replace(Regex("""[ \t]{2,}"""), " ")
        s = s.trim(' ', '\t')
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
    private val preamble = Regex("""^(here('s| is)|sure|cleaned( text| transcript)?|output)\b.*:\s*$""", RegexOption.IGNORE_CASE)

    /** Strips artefacts small LLMs add around the cleaned text. */
    fun sanitize(output: String, raw: String): String {
        var s = output.trim().replace(Regex("</?transcript>"), "")
        // Drop a preamble line such as "Here is the cleaned text:".
        val first = s.split("\n", limit = 2).first()
        if (preamble.containsMatchIn(first)) s = s.substring(first.length)
        s = s.trim()
        // Unwrap quotes the speaker did not dictate.
        for ((o, c) in listOf("\"" to "\"", "“" to "”", "'" to "'")) {
            if (s.length > 2 && s.startsWith(o) && s.endsWith(c)) {
                val inner = s.substring(1, s.length - 1)
                if (!inner.contains(o) && !raw.lowercase().contains("quote")) s = inner
            }
        }
        // Spec: never insert em dashes automatically.
        if (!raw.lowercase().contains("dash")) s = s.replace(Regex("""\s*—\s*"""), ", ")
        return s.trim()
    }
}
