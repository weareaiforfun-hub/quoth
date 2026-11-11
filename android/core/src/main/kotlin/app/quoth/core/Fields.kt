package app.quoth.core

// What Quoth needs to know about a text field, from Android's input-type bits, plus Earshot's (the floating
// dictation bubble's) pure decisions. The bit values are android.text.InputType / EditorInfo's public constants,
// copied here so this module stays free of Android and testable on the JVM.

object InputBits {
    const val MASK_CLASS = 0x0000000f
    const val MASK_VARIATION = 0x00000ff0
    const val CLASS_TEXT = 0x00000001
    const val CLASS_NUMBER = 0x00000002
    const val FLAG_MULTI_LINE = 0x00020000
    const val VARIATION_URI = 0x00000010
    const val VARIATION_EMAIL_ADDRESS = 0x00000020
    const val VARIATION_EMAIL_SUBJECT = 0x00000030
    const val VARIATION_PERSON_NAME = 0x00000060
    const val VARIATION_PASSWORD = 0x00000080
    const val VARIATION_VISIBLE_PASSWORD = 0x00000090
    const val VARIATION_FILTER = 0x000000b0
    const val VARIATION_WEB_PASSWORD = 0x000000e0
    const val NUMBER_VARIATION_PASSWORD = 0x00000010
    const val ACTION_GO = 2
    const val ACTION_SEARCH = 3
}

object Fields {
    /** True for password boxes of any kind (text, visible, web, numeric PIN). */
    fun isPassword(inputType: Int): Boolean {
        val variation = inputType and InputBits.MASK_VARIATION
        return when (inputType and InputBits.MASK_CLASS) {
            InputBits.CLASS_TEXT -> variation == InputBits.VARIATION_PASSWORD || variation == InputBits.VARIATION_VISIBLE_PASSWORD ||
                variation == InputBits.VARIATION_WEB_PASSWORD
            InputBits.CLASS_NUMBER -> variation == InputBits.NUMBER_VARIATION_PASSWORD
            else -> false
        }
    }

    /**
     * One-line fields, search boxes and subject lines. [action] is the field's IME action (EditorInfo.IME_MASK_ACTION),
     * which a keyboard knows; Earshot doesn't, so it passes 0 and its [hint] (a search box's "Search…") instead.
     * [multiLine] overrides the input type's multi-line flag when the caller knows better (AccessibilityNodeInfo.isMultiLine).
     */
    fun kind(inputType: Int, action: Int = 0, multiLine: Boolean? = null, hint: String? = null): FieldKind {
        if (inputType and InputBits.MASK_CLASS != InputBits.CLASS_TEXT) return FieldKind.NORMAL
        val variation = inputType and InputBits.MASK_VARIATION
        val oneLine = !(multiLine ?: (inputType and InputBits.FLAG_MULTI_LINE != 0))
        val searchHint = hint != null && Regex("^\\s*search\\b", RegexOption.IGNORE_CASE).containsMatchIn(hint)
        return when {
            variation == InputBits.VARIATION_URI || variation == InputBits.VARIATION_FILTER ||
                variation == InputBits.VARIATION_EMAIL_ADDRESS ||
                (action == InputBits.ACTION_SEARCH || action == InputBits.ACTION_GO || searchHint) && oneLine -> FieldKind.SEARCH
            // A name box ("First name") wants the name alone, like a title: no final period.
            variation == InputBits.VARIATION_EMAIL_SUBJECT || variation == InputBits.VARIATION_PERSON_NAME -> FieldKind.SUBJECT
            oneLine -> FieldKind.SINGLE_LINE
            else -> FieldKind.NORMAL
        }
    }
}

/** A field's text after inserting at the cursor, and where the cursor goes (just after the new text). */
data class Merged(val text: String, val cursor: Int)

object FieldMerge {
    /**
     * Puts [insert] into [current] at the selection, replacing any selected text. A selection of -1 (unknown)
     * means the end of the field. [showingHint] is true when [current] is only the field's placeholder.
     */
    fun merge(current: String?, showingHint: Boolean, selStart: Int, selEnd: Int, insert: String): Merged {
        val text = if (showingHint || current == null) "" else current
        var a = if (selStart < 0) text.length else selStart.coerceAtMost(text.length)
        var b = if (selEnd < 0) a else selEnd.coerceAtMost(text.length)
        if (a > b) a = b.also { b = a }
        return Merged(text.substring(0, a) + insert + text.substring(b), a + insert.length)
    }

    /** The text before the cursor and after it, for the pipeline's context. */
    fun around(current: String?, showingHint: Boolean, selStart: Int, selEnd: Int): Pair<String, String> {
        val text = if (showingHint || current == null) "" else current
        val a = if (selStart < 0) text.length else minOf(selStart, selEnd.takeIf { it >= 0 } ?: selStart).coerceIn(0, text.length)
        val b = if (selEnd < 0) a else maxOf(selStart, selEnd).coerceIn(a, text.length)
        return text.substring(maxOf(0, a - 600), a) to text.substring(b, minOf(text.length, b + 100))
    }
}

/** Everything that decides whether Earshot shows its bubble. */
data class EarshotScene(
    /** The app whose field has input focus, or null when no editable field has it. */
    val app: String?,
    val password: Boolean,
    /** A keyboard window is on screen (Earshot shows only while you're about to type). */
    val keyboardUp: Boolean,
    /** That keyboard is Quoth's own, which has its own microphone. */
    val quothKeyboard: Boolean,
)

object EarshotRules {
    fun shows(settings: AppSettings, scene: EarshotScene, now: Long): Boolean = when {
        !settings.earshot -> false
        scene.app == null || scene.password -> false
        !scene.keyboardUp || scene.quothKeyboard -> false
        now < settings.earshotSnoozedUntil -> false
        scene.app in settings.earshotHiddenApps -> false
        else -> true
    }
}
