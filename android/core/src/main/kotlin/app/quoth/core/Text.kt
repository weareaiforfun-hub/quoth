package app.quoth.core

import java.util.concurrent.ConcurrentHashMap
import java.util.regex.Pattern

/**
 * Regexes that behave like the Mac's (ICU): `\b`, `\w`, `\s` and `\d` are Unicode-aware.
 * Android's regex engine is ICU already; the JVM needs UNICODE_CHARACTER_CLASS, which Android rejects.
 */
internal object Rx {
    private val onAndroid = System.getProperty("java.vm.name") == "Dalvik"
    private val cache = ConcurrentHashMap<Pair<String, Boolean>, Regex>()

    fun of(pattern: String, ignoreCase: Boolean = false): Regex = cache.getOrPut(pattern to ignoreCase) {
        var flags = if (onAndroid) 0 else Pattern.UNICODE_CHARACTER_CLASS
        if (ignoreCase) flags = flags or Pattern.CASE_INSENSITIVE or Pattern.UNICODE_CASE
        Pattern.compile(pattern, flags).toRegex()
    }
}

/** Replaces every match of [pattern], with `$1`-style group references in [with]. */
internal fun String.re(pattern: String, with: String, ignoreCase: Boolean = false) = Rx.of(pattern, ignoreCase).replace(this, with)

internal fun String.matches(pattern: String, ignoreCase: Boolean = false) = Rx.of(pattern, ignoreCase).containsMatchIn(this)

/** Swift's `.whitespaces`: spaces and tabs, not line breaks. */
internal fun Char.isHorizontalSpace() = isWhitespace() && this != '\n' && this != '\r'

internal fun String.trimSpaces() = trim { it.isHorizontalSpace() }

/** Swift's `split(separator: " ")`: empty pieces dropped. */
internal fun String.words(): List<String> = split(' ').filter { it.isNotEmpty() }

internal fun String.capitaliseFirst() = if (isEmpty()) this else substring(0, 1).uppercase() + substring(1)

internal fun String.lowercaseFirst() = if (isEmpty()) this else substring(0, 1).lowercase() + substring(1)
