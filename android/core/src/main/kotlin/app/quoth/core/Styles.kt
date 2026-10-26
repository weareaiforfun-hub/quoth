package app.quoth.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// Port of Sources/QuothCore/Personal/Styles.swift, plus Android package names for the categories.

enum class StyleCategory(val raw: String, val title: String) {
    PERSONAL("personal", "Personal messages"),
    WORK("work", "Work messages"),
    EMAIL("email", "Email"),
    OTHER("other", "Everything else");

    val allowedTones: List<StyleTone>
        get() = when (this) {
            PERSONAL -> listOf(StyleTone.FORMAL, StyleTone.CASUAL, StyleTone.VERY_CASUAL, StyleTone.EXCITED)
            WORK, EMAIL -> listOf(StyleTone.FORMAL, StyleTone.CASUAL, StyleTone.EXCITED)
            OTHER -> listOf(StyleTone.FORMAL, StyleTone.CASUAL)
        }

    internal val isMessaging: Boolean get() = this == PERSONAL || this == WORK

    companion object {
        private val apps = mapOf(
            // Mac bundle IDs (the same as the Mac app, so the shared evals mean the same thing).
            "com.apple.MobileSMS" to PERSONAL, "net.whatsapp.WhatsApp" to PERSONAL, "ru.keepcoder.Telegram" to PERSONAL,
            "org.telegram.desktop" to PERSONAL, "com.hnc.Discord" to PERSONAL, "org.whispersystems.signal-desktop" to PERSONAL,
            "com.facebook.archon" to PERSONAL, "com.facebook.archon.developerID" to PERSONAL,
            "com.tinyspeck.slackmacgap" to WORK, "com.microsoft.teams2" to WORK, "com.microsoft.teams" to WORK,
            "com.apple.mail" to EMAIL, "com.microsoft.Outlook" to EMAIL, "com.superhuman.electron" to EMAIL,
            "com.readdle.smartemail-Mac" to EMAIL, "it.bloop.airmail2" to EMAIL,
            // Android package names.
            "com.whatsapp" to PERSONAL, "org.telegram.messenger" to PERSONAL, "org.thoughtcrime.securesms" to PERSONAL,
            "com.discord" to PERSONAL, "com.facebook.orca" to PERSONAL, "com.google.android.apps.messaging" to PERSONAL,
            "com.instagram.android" to PERSONAL, "com.samsung.android.messaging" to PERSONAL,
            "com.Slack" to WORK, "com.linkedin.android" to WORK, "com.whatsapp.w4b" to WORK,
            "com.google.android.gm" to EMAIL, "com.microsoft.office.outlook" to EMAIL, "ch.protonmail.android" to EMAIL,
            "com.samsung.android.email.provider" to EMAIL, "com.fsck.k9" to EMAIL, "net.thunderbird.android" to EMAIL,
        )

        private val browserTitles = listOf(
            "gmail" to EMAIL, "outlook" to EMAIL, "inbox" to EMAIL, "superhuman" to EMAIL,
            "slack" to WORK, "linkedin" to WORK, "teams" to WORK,
            "whatsapp" to PERSONAL, "messenger" to PERSONAL, "instagram" to PERSONAL,
            "discord" to PERSONAL, "telegram" to PERSONAL,
        )

        private val browsers = setOf(
            "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox",
            "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        )

        /** Picks the category from the app, or for browsers from the window title. */
        fun detect(bundleID: String?, windowTitle: String?): StyleCategory {
            apps[bundleID]?.let { return it }
            if (bundleID in browsers && windowTitle != null) {
                val t = windowTitle.lowercase()
                for ((key, c) in browserTitles) if (t.contains(key)) return c
            }
            return OTHER
        }
    }
}

@Serializable
enum class StyleTone(val title: String, val example: String) {
    @SerialName("formal") FORMAL("Formal", "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you."),
    @SerialName("casual") CASUAL("Casual", "Hey are you free for lunch tomorrow? Let's do 12 if that works for you"),
    @SerialName("veryCasual") VERY_CASUAL("Very casual", "hey are you free for lunch tomorrow? let's do 12 if that works for you"),
    @SerialName("excited") EXCITED("Excited", "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you!");

    companion object {
        fun of(raw: String?) = when (raw) {
            "formal" -> FORMAL; "casual" -> CASUAL; "veryCasual" -> VERY_CASUAL; "excited" -> EXCITED; else -> null
        }
    }
}

@Serializable
data class StylePrefs(
    val personal: StyleTone? = StyleTone.CASUAL,
    val work: StyleTone? = StyleTone.CASUAL,
    val email: StyleTone? = StyleTone.FORMAL,
    val other: StyleTone? = StyleTone.FORMAL,
) {
    operator fun get(c: StyleCategory): StyleTone? = when (c) {
        StyleCategory.PERSONAL -> personal; StyleCategory.WORK -> work; StyleCategory.EMAIL -> email; StyleCategory.OTHER -> other
    }

    fun with(c: StyleCategory, tone: StyleTone?): StylePrefs = when (c) {
        StyleCategory.PERSONAL -> copy(personal = tone); StyleCategory.WORK -> copy(work = tone)
        StyleCategory.EMAIL -> copy(email = tone); StyleCategory.OTHER -> copy(other = tone)
    }
}

/**
 * Style = capitalisation, punctuation and spacing only, never word choice.
 * Done deterministically because LLMs follow these rules with low precision.
 */
object StyleRules {
    fun apply(text: String, tone: StyleTone?, category: StyleCategory, hasSelection: Boolean,
              protectedWords: List<String> = emptyList(), rawTarget: Boolean = false): String {
        if (hasSelection || text.isEmpty()) return text
        var s = text
        // Formal prose always ends with punctuation (models and ASR sometimes drop the final period).
        if ((tone == StyleTone.FORMAL || (tone == null && !category.isMessaging)) && !rawTarget &&
            s.last().isLetterOrDigit() && s.words().size >= 3 && !s.contains("\n")) {
            s += "."
        }
        val sentences = sentenceCount(s)
        val isMultiline = s.contains("\n")

        if (tone == StyleTone.VERY_CASUAL) s = lowercaseSentenceStarts(s, protectedWords)
        val stripLimit = when (tone) {
            StyleTone.FORMAL -> 0
            StyleTone.CASUAL -> 10
            StyleTone.VERY_CASUAL -> Int.MAX_VALUE
            StyleTone.EXCITED, null -> if (category.isMessaging) 2 else 0
        }
        if (stripLimit > 0 && sentences <= stripLimit && !isMultiline) s = stripTrailingPeriod(s)
        return s
    }

    internal fun sentenceCount(s: String) = maxOf(1, s.split('.', '!', '?').count { it.trimSpaces().isNotEmpty() })

    /** Removes a final "." or "…"/"...", keeping "!" and "?". */
    internal fun stripTrailingPeriod(s: String): String {
        val t = s.trimSpaces()
        return when {
            t.endsWith("...") -> t.dropLast(3)
            t.endsWith("…") || t.endsWith(".") -> t.dropLast(1)
            else -> t
        }
    }

    /** "Very casual": no capitals at sentence starts, except "I", acronyms and dictionary words. */
    internal fun lowercaseSentenceStarts(s: String, protected: List<String>, firstOnly: Boolean = false): String {
        val keep = protected.toSet()
        val out = StringBuilder()
        var atStart = true
        val word = StringBuilder()
        fun flush() {
            if (word.isEmpty()) return
            var w = word.toString()
            if (atStart) {
                val isAcronym = w.length > 1 && w == w.uppercase() && w.any { it.isLetter() }
                val isI = w == "I" || w.startsWith("I'") || w.startsWith("I’")
                if (!isAcronym && !isI && w !in keep) w = w.lowercaseFirst()
            }
            out.append(w)
            atStart = false
            word.clear()
        }
        for (ch in s) {
            if (ch.isLetterOrDigit() || ch == '\'' || ch == '’') {
                word.append(ch)
            } else {
                flush()
                out.append(ch)
                if (ch in ".!?\n" && !firstOnly) atStart = true
            }
        }
        flush()
        return out.toString()
    }
}

/** Email layout only belongs in email: "Hey Sam,\n\nI was…" → "Hey Sam, I was…". */
object Greeting {
    private val openers = setOf("are", "is", "can", "could", "would", "will", "do", "did", "does", "have", "has",
        "how", "what", "when", "where", "why", "just", "thanks", "thank", "so", "quick",
        "hope", "let's", "we", "you", "it", "the", "this", "that", "sorry", "great", "good")

    fun joinOutsideEmail(input: String): String {
        val joined = input.re("""^((?:hi|hey|hello|dear|yo|hiya|morning|good morning)\b[^\n]{0,30},)\n+(?=\S)""", "$1 ", ignoreCase = true)
        if (joined == input) return input
        val comma = joined.indexOf(',')
        if (comma < 0) return input
        // "Hey Sam, Are you free?" → "Hey Sam, are you free?" for ordinary sentence openers.
        val rest = joined.substring(comma + 1).trimStart(' ')
        val firstWord = rest.takeWhile { it.isLetter() || it == '\'' }
        return if (firstWord.lowercase() in openers) {
            joined.substring(0, comma + 1) + " " + firstWord.lowercase() + rest.substring(firstWord.length)
        } else joined
    }
}

/** Deterministic language variants. */
object LanguageRules {
    fun apply(text: String, language: String?, variant: LanguageVariant, isCodeEditor: Boolean): String {
        var s = text
        if (variant == LanguageVariant.DE_CH) s = s.replace("ß", "ss").replace("ẞ", "SS")
        if (language == "fr" && !isCodeEditor) {
            // French typography: narrow no-break space before ; : ! ? and inside « ».
            s = s.re("""\s*([;:!?»])""", " $1").re("""«\s*""", "« ")
            // …but not inside URLs/times like "https://" or "12:30".
            s = s.re("""(\w) (:)(?=//|\d)""", "$1$2")
        }
        return s
    }
}

/**
 * Makes the dictation fit where the cursor is: mid-sentence continuation
 * starts lowercase, and spacing joins cleanly with the surrounding text.
 */
object Continuation {
    fun apply(text: String, before: String?, after: String?, protectedWords: List<String> = emptyList()): String {
        if (text.isEmpty()) return text
        var s = text
        if (!before.isNullOrEmpty()) {
            val trimmed = before.trimSpaces()
            val midSentence = trimmed.lastOrNull()?.let { it !in ".!?:\n" } ?: false
            if (midSentence && !s.contains("\n")) {
                s = StyleRules.lowercaseSentenceStarts(s, protectedWords, firstOnly = true)
            }
            val b = before.last()
            val f = s.first()
            if (!b.isWhitespace() && b !in "(\"'“‘/" && f.isLetterOrDigit()) s = " $s"
        }
        val a = after?.firstOrNull()
        if (a != null && a.isLetterOrDigit() && !s.last().isWhitespace()) s += " "
        return s
    }
}
