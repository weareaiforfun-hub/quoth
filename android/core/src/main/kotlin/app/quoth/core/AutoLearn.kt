package app.quoth.core

// Port of Sources/QuothCore/Personal/AutoLearn.swift, plus the Android field kinds.

/** Learns words from the user's edits to a just-inserted dictation. */
object AutoLearn {
    /** Everyday acronyms that are never worth learning. */
    internal val everydayAcronyms = setOf(
        "PDF", "CEO", "CTO", "CFO", "USA", "UK", "EU", "OK", "FAQ", "URL", "API", "AI", "TV", "PM", "AM",
        "ASAP", "FYI", "ETA", "HR", "IT", "PR", "UI", "UX", "ID", "VIP", "DIY", "NYC", "LA", "SF",
    )

    /**
     * Words to add to the dictionary.
     * @param pasted what we inserted (edits elsewhere in the field are ignored).
     * @param before the field's text right after the insert; [after] is the same field later.
     * @param isCommonWord true for ordinary dictionary words (lowercased).
     */
    fun candidates(pasted: String, before: String, after: String, isCommonWord: (String) -> Boolean,
                   known: Collection<String>, deleted: Collection<String>): List<String> {
        val b = words(before)
        val a = words(after)
        if (b == a) return emptyList()
        // Isolate the changed region by trimming the common prefix and suffix.
        var p = 0
        while (p < b.size && p < a.size && b[p] == a[p]) p++
        var sfx = 0
        while (sfx < b.size - p && sfx < a.size - p && b[b.size - 1 - sfx] == a[a.size - 1 - sfx]) sfx++
        val old = b.subList(p, b.size - sfx)
        val new = a.subList(p, a.size - sfx)
        // A small, local correction, not a rewrite.
        if (old.isEmpty() || new.isEmpty() || old.size > 4 || new.size > 4) return emptyList()
        val pastedWords = words(pasted).map { it.lowercase() }.toSet()
        if (!old.all { it.lowercase() in pastedWords }) return emptyList()

        val pairs = when {
            old.size == new.size -> old.zip(new).filter { (o, n) -> o != n }
            new.size == 1 -> listOf(old.joinToString(" ") to new[0])
            else -> listOf(old.joinToString(" ") to new.joinToString(" "))
        }
        val knownLower = known.map { it.lowercase() }.toSet()
        val deletedLower = deleted.map { it.lowercase() }.toSet()
        val out = mutableListOf<String>()
        for ((o, n) in pairs) {
            if (similarity(o.lowercase(), n.lowercase()) < 0.4) continue
            if (!isLearnable(n, isCommonWord)) continue
            val key = n.lowercase()
            if (key in knownLower || key in deletedLower || n in out) continue
            out += n
        }
        return out
    }

    internal fun isLearnable(w: String, isCommonWord: (String) -> Boolean): Boolean {
        val length = w.codePointCount(0, w.length)
        if (length < 3 || length > 60 || w.none { it.isLetter() }) return false
        if (w.contains("://") || w.startsWith("www.") || w.contains("/") || w.contains("\\") || w.contains("@")) return false
        if (w.codePoints().anyMatch { it in 0x1F000..0x1FAFF || it in 0x2600..0x27BF }) return false // emoji
        if (w.all { it.isDigit() || it in ":-./" }) return false
        if (w in everydayAcronyms) return false
        // Proper noun or jargon: has a capital, or isn't an ordinary word.
        val parts = w.split(" ")
        val hasCapital = w.any { it.isUpperCase() }
        val allCommon = parts.all { isCommonWord(it.lowercase()) }
        // "Apple" → common word "apple", capitalised only at sentence start: skip.
        if (allCommon && !hasInternalCapital(w) && (!hasCapital || parts.size == 1 && isCommonWord(w.lowercase()))) return false
        return true
    }

    internal fun hasInternalCapital(w: String) = w.drop(1).any { it.isUpperCase() }

    /** Word tokens with surrounding punctuation removed ("-" and "_" are kept). */
    internal fun words(s: String): List<String> =
        s.split(Regex("\\s+")).map { it.trim { c -> isPunctuation(c) && c != '-' && c != '_' } }.filter { it.isNotEmpty() }

    private fun isPunctuation(c: Char) = when (Character.getType(c).toByte()) {
        Character.CONNECTOR_PUNCTUATION, Character.DASH_PUNCTUATION, Character.START_PUNCTUATION, Character.END_PUNCTUATION,
        Character.INITIAL_QUOTE_PUNCTUATION, Character.FINAL_QUOTE_PUNCTUATION, Character.OTHER_PUNCTUATION -> true
        else -> false
    }

    /** 1 − normalised Levenshtein distance. */
    internal fun similarity(a: String, b: String): Double {
        if (a.isEmpty() && b.isEmpty()) return 1.0
        var prev = IntArray(b.length + 1) { it }
        for (i in 1..a.length) {
            val cur = IntArray(b.length + 1).also { it[0] = i }
            for (j in 1..b.length) cur[j] = minOf(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + if (a[i - 1] == b[j - 1]) 0 else 1)
            prev = cur
        }
        return 1 - prev[b.length].toDouble() / maxOf(a.length, b.length)
    }
}

/** What kind of text field the dictation goes into, from Android's EditorInfo. The Mac always uses NORMAL. */
enum class FieldKind {
    NORMAL,
    /** A one-line field: a newline could submit it, so line breaks become spaces. */
    SINGLE_LINE,
    /** A search box or web address bar: one line, no final period. */
    SEARCH,
    /** An email subject or a title: one line, no final period. */
    SUBJECT;

    val isSingleLine get() = this != NORMAL
}

object FieldRules {
    fun apply(text: String, field: FieldKind): String {
        if (!field.isSingleLine) return text
        var s = text.re("[ \\t]*\\n+[ \\t]*", " ")
        if (field != FieldKind.SINGLE_LINE) {
            s = s.trimEnd()
            s = when {
                s.endsWith("...") -> s.dropLast(3)
                s.endsWith("…") || s.endsWith(".") -> s.dropLast(1)
                else -> s
            }
        }
        return s
    }
}

/**
 * A sorted list of ordinary words, one per line (assets/common-words-en.txt), looked up by binary search
 * on the one string, so 90,000 words cost about 2 MB instead of a set of objects.
 */
class WordList(private val text: String) {
    private val starts: IntArray = run {
        val out = ArrayList<Int>(100_000)
        var i = 0
        while (i < text.length) {
            out += i
            i = text.indexOf('\n', i).let { if (it < 0) text.length else it } + 1
        }
        out.toIntArray()
    }

    val size get() = starts.size

    operator fun contains(word: String): Boolean {
        var lo = 0
        var hi = starts.size - 1
        while (lo <= hi) {
            val mid = (lo + hi) ushr 1
            val c = compareLine(mid, word)
            when {
                c < 0 -> lo = mid + 1
                c > 0 -> hi = mid - 1
                else -> return true
            }
        }
        return false
    }

    private fun compareLine(index: Int, word: String): Int {
        val start = starts[index]
        val end = text.indexOf('\n', start).let { if (it < 0) text.length else it }
        val n = minOf(end - start, word.length)
        for (k in 0 until n) {
            val d = text[start + k] - word[k]
            if (d != 0) return d
        }
        return (end - start) - word.length
    }
}
