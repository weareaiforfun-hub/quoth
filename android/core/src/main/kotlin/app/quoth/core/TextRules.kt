package app.quoth.core

// Ports of Sources/QuothCore/Personal/TextRules.swift and DevFormatting.swift.

/**
 * Deterministic dictionary replacements and snippet expansion.
 * These run after the LLM so the model can never rewrite them.
 */
object TextRules {
    // Not a letter, digit, underscore or apostrophe-joined word part.
    private const val LEFT = """(?<![\p{L}\p{N}_])"""
    // Allow a possessive "'s" after the match, but never touch "n't"-style contractions.
    private const val RIGHT = """(?=(?:['’]s)?(?![\p{L}\p{N}_])(?!['’](?:t|ve|re|ll|d|m)\b))"""

    private fun phrasePattern(phrase: String) =
        phrase.split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString("""[\s-]+""") { Regex.escape(it) }

    /**
     * Applies replacement entries (longest phrase first) and fixes the casing of word entries.
     * Returns the new text and the IDs of entries that fired (for usage ranking).
     */
    fun applyDictionary(text: String, entries: List<DictionaryEntry>): Pair<String, List<String>> {
        var s = text
        val fired = mutableListOf<String>()
        val protected = mutableListOf<String>()
        val ordered = entries
            .filter { it.kind == DictionaryEntry.Kind.REPLACEMENT || it.phrase.any(Char::isUpperCase) }
            .sortedByDescending { it.phrase.length }
        for (e in ordered) {
            val re = Rx.of(LEFT + phrasePattern(e.phrase) + RIGHT, ignoreCase = true)
            val matches = re.findAll(s).toList()
            if (matches.isEmpty()) continue
            if (e.kind == DictionaryEntry.Kind.WORD && matches.all { it.value == e.phrase }) continue // already spelled right
            // Swap in a placeholder so shorter phrases can't match inside this output.
            val token = "${protected.size}"
            protected += e.output
            s = re.replace(s, Regex.escapeReplacement(token))
            fired += e.id
        }
        protected.forEachIndexed { i, value -> s = s.replace("$i", value) }
        return s to fired
    }

    class Shielded(val token: String, val snippet: Snippet)

    /**
     * Replaces snippet triggers with numbered tokens so the LLM can't paraphrase them.
     * Returns the protected text and the expansions keyed by token.
     */
    fun protectSnippets(text: String, snippets: List<Snippet>): Pair<String, List<Shielded>> {
        var out = text
        val tokens = mutableListOf<Shielded>()
        for (sn in snippets.sortedByDescending { it.trigger.length }) {
            val re = Rx.of("""(?<![\p{L}\p{N}_])""" + phrasePattern(sn.trigger) + """(?![\p{L}\p{N}_])""", ignoreCase = true)
            if (!re.containsMatchIn(out)) continue
            val token = "[[S${tokens.size + 1}]]"
            out = re.replace(out, Regex.escapeReplacement(token))
            tokens += Shielded(token, sn)
        }
        return out to tokens
    }

    /** Normalises for "spoken alone" comparison: case, punctuation and trailing period ignored. */
    internal fun normalised(s: String) = s.lowercase().re("""[^\p{L}\p{N}]+""", " ").trimSpaces()

    /** If the whole dictation is one snippet trigger, returns its snippet. */
    fun snippetSpokenAlone(text: String, snippets: List<Snippet>): Snippet? {
        val n = normalised(text)
        if (n.isEmpty()) return null
        return snippets.filter { normalised(it.trigger) == n }.maxByOrNull { it.trigger.length }
    }

    /**
     * Expands snippet triggers inside a sentence. Longest trigger wins; triggers can't touch
     * letters, digits or underscores; adjacent punctuation is fine.
     */
    fun expandSnippets(text: String, snippets: List<Snippet>): Pair<String, List<String>> {
        snippetSpokenAlone(text, snippets)?.let { return it.expansion to listOf(it.id) }
        var out = text
        val fired = mutableListOf<String>()
        val protected = mutableListOf<String>()
        for (sn in snippets.sortedByDescending { it.trigger.length }) {
            val re = Rx.of("""(?<![\p{L}\p{N}_])""" + phrasePattern(sn.trigger) + """(?![\p{L}\p{N}_])""", ignoreCase = true)
            if (!re.containsMatchIn(out)) continue
            val token = "${protected.size}"
            protected += sn.expansion
            out = re.replace(out, Regex.escapeReplacement(token))
            fired += sn.id
        }
        protected.forEachIndexed { i, value -> out = out.replace("$i", value) }
        return out to fired
    }
}

/** Developer features: spoken identifiers and @file tagging in AI IDEs (Mac apps; kept for parity with the evals). */
object DevFormatting {
    val codeEditors = setOf(
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.exafunction.windsurf",         // Windsurf
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
        "dev.zed.Zed", "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.apple.dt.Xcode",
    )
    /** IDEs whose chat attaches files via "@name". */
    val fileTaggingEditors = setOf("com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf")

    private val extensions = listOf(
        "ts", "tsx", "js", "jsx", "mjs", "py", "rb", "go", "rs", "swift", "kt", "java", "c", "h", "cpp", "hpp",
        "cs", "php", "md", "mdx", "json", "yaml", "yml", "toml", "html", "css", "scss", "sql", "sh", "txt",
        "env", "lock", "xml", "vue", "svelte", "ipynb",
    ).joinToString("|")

    /** "index dot ts" → "index.ts"; "dot env" → ".env". Applies to raw ASR text before cleanup in code editors. */
    fun spokenFilenames(text: String): String =
        text.re("""(?i)\bdot\s+env\b""", ".env")
            .re("""(?i)\b([A-Za-z0-9_-]+)\s+dot\s+($extensions)\b""", "$1.$2")

    /**
     * In Cursor/Windsurf chat, filenames become "@name.ext" so the IDE's autocomplete attaches them.
     * A leading "tag", "at" or "@" is consumed. [candidates] (open files) map multi-word names.
     */
    fun tagFiles(text: String, candidates: List<String> = emptyList()): String {
        var s = text
        // Multi-word names that match a known file: "my python script" → "@my_python_script.py"
        for (file in candidates.sortedByDescending { it.length }) {
            val base = file.substringBeforeLast('.', file)
            val spoken = base.re("([a-z])([A-Z])", "$1 $2").re("[_.-]+", " ")
            if (!spoken.contains(" ")) continue
            val pattern = """(?i)\b(?:(?:tag|at)\s+)?""" + Regex.escape(spoken).replace(" ", "\\E\\s+\\Q") + """\b"""
            s = s.re(pattern, "@" + Regex.escapeReplacement(file))
        }
        return s.re("""(?i)(?:\b(?:tag|at)\s+|@)?(?<![@\w./])((?:[A-Za-z0-9_-]+)?\.(?:$extensions))\b""", "@$1")
    }

    /** Identifiers visible in the editor: camelCase, PascalCase with a lowercase run, snake_case. */
    fun identifiers(text: String, limit: Int = 300): List<String> {
        val re = Rx.of("""\b(?:[a-z]+(?:[A-Z][a-z0-9]*)+|[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]*)+|[a-z][a-z0-9]*(?:_[a-z0-9]+)+)\b""")
        val seen = mutableListOf<String>()
        for (m in re.findAll(text)) {
            if (m.value !in seen) seen += m.value
            if (seen.size >= limit) break
        }
        return seen
    }

    /** "user id" → "userId" when `userId` is a visible identifier. */
    fun applyIdentifiers(text: String, identifiers: List<String>): String {
        var s = text
        for (id in identifiers.sortedByDescending { it.length }) {
            val parts = id.re("([a-z0-9])([A-Z])", "$1 $2").replace("_", " ").words()
            if (parts.size < 2) continue
            val pattern = """(?i)(?<![\w])""" + parts.joinToString("""[\s-]+""") { Regex.escape(it) } + """(?![\w])"""
            s = s.re(pattern, Regex.escapeReplacement(id))
        }
        return s
    }
}
