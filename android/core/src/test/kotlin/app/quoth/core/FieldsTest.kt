package app.quoth.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FieldsTest {
    private val text = InputBits.CLASS_TEXT

    @Test fun passwords() {
        assertTrue(Fields.isPassword(text or InputBits.VARIATION_PASSWORD))
        assertTrue(Fields.isPassword(text or InputBits.VARIATION_VISIBLE_PASSWORD))
        assertTrue(Fields.isPassword(text or InputBits.VARIATION_WEB_PASSWORD))
        assertTrue(Fields.isPassword(InputBits.CLASS_NUMBER or InputBits.NUMBER_VARIATION_PASSWORD))
        assertFalse(Fields.isPassword(text or InputBits.VARIATION_URI)) // same bits as the numeric PIN variation
        assertFalse(Fields.isPassword(text or InputBits.FLAG_MULTI_LINE))
        assertFalse(Fields.isPassword(0))
    }

    @Test fun kindsFromTheKeyboard() {
        assertEquals(FieldKind.NORMAL, Fields.kind(text or InputBits.FLAG_MULTI_LINE))
        assertEquals(FieldKind.SINGLE_LINE, Fields.kind(text))
        assertEquals(FieldKind.SEARCH, Fields.kind(text, action = InputBits.ACTION_SEARCH))
        assertEquals(FieldKind.SEARCH, Fields.kind(text, action = InputBits.ACTION_GO))
        assertEquals(FieldKind.NORMAL, Fields.kind(text or InputBits.FLAG_MULTI_LINE, action = InputBits.ACTION_SEARCH))
        assertEquals(FieldKind.SEARCH, Fields.kind(text or InputBits.VARIATION_URI))
        assertEquals(FieldKind.SEARCH, Fields.kind(text or InputBits.VARIATION_EMAIL_ADDRESS))
        assertEquals(FieldKind.SUBJECT, Fields.kind(text or InputBits.VARIATION_EMAIL_SUBJECT))
        assertEquals(FieldKind.SUBJECT, Fields.kind(text or InputBits.VARIATION_PERSON_NAME))
        assertEquals(FieldKind.NORMAL, Fields.kind(InputBits.CLASS_NUMBER))
    }

    @Test fun kindsFromAccessibility() {
        // No IME action: the node's multi-line flag and hint decide.
        assertEquals(FieldKind.NORMAL, Fields.kind(text, multiLine = true))
        assertEquals(FieldKind.SINGLE_LINE, Fields.kind(text or InputBits.FLAG_MULTI_LINE, multiLine = false))
        assertEquals(FieldKind.SEARCH, Fields.kind(text, multiLine = false, hint = "Search or type URL"))
        assertEquals(FieldKind.SEARCH, Fields.kind(text, multiLine = false, hint = "search messages"))
        assertEquals(FieldKind.NORMAL, Fields.kind(text, multiLine = true, hint = "Search"))
        assertEquals(FieldKind.SINGLE_LINE, Fields.kind(text, multiLine = false, hint = "Research notes"))
    }

    @Test fun mergeAtCursor() {
        assertEquals(Merged("Hello world", 11), FieldMerge.merge("Hello ", false, 6, 6, "world"))
        assertEquals(Merged("Hi Sam, there", 6), FieldMerge.merge("Hi, there", false, 2, 2, " Sam"))
        assertEquals(Merged("Hi Ann!", 6), FieldMerge.merge("Hi Bob!", false, 3, 6, "Ann"))
        // A selection made backwards (start after end) is the same selection.
        assertEquals(Merged("Hi Ann!", 6), FieldMerge.merge("Hi Bob!", false, 6, 3, "Ann"))
    }

    @Test fun mergeEdgeCases() {
        // Placeholder text isn't the field's text.
        assertEquals(Merged("Hello", 5), FieldMerge.merge("Type a message", true, 0, 0, "Hello"))
        assertEquals(Merged("Hello", 5), FieldMerge.merge(null, false, -1, -1, "Hello"))
        // Unknown cursor: the end.
        assertEquals(Merged("abc def", 7), FieldMerge.merge("abc", false, -1, -1, " def"))
        // A cursor past the end (stale) is clamped.
        assertEquals(Merged("abc def", 7), FieldMerge.merge("abc", false, 10, 12, " def"))
    }

    @Test fun textAroundCursor() {
        assertEquals("Hello " to "world", FieldMerge.around("Hello world", false, 6, 6))
        assertEquals("Hi " to "!", FieldMerge.around("Hi Bob!", false, 3, 6))
        assertEquals("" to "", FieldMerge.around("Type a message", true, 0, 0))
        assertEquals("abc" to "", FieldMerge.around("abc", false, -1, -1))
        val long = "x".repeat(1000)
        assertEquals(600, FieldMerge.around(long, false, 1000, 1000).first.length)
    }

    @Test fun whenTheBubbleShows() {
        val on = AppSettings(earshot = true)
        val typing = EarshotScene(app = "com.example.chat", password = false, keyboardUp = true, quothKeyboard = false)
        assertTrue(EarshotRules.shows(on, typing, 0))
        assertFalse("off by default", EarshotRules.shows(AppSettings(), typing, 0))
        assertFalse("no field", EarshotRules.shows(on, typing.copy(app = null), 0))
        assertFalse("password", EarshotRules.shows(on, typing.copy(password = true), 0))
        assertFalse("no keyboard", EarshotRules.shows(on, typing.copy(keyboardUp = false), 0))
        assertFalse("Quoth's own keyboard", EarshotRules.shows(on, typing.copy(quothKeyboard = true), 0))
        assertFalse("snoozed", EarshotRules.shows(on.copy(earshotSnoozedUntil = 1000), typing, 999))
        assertTrue("snooze over", EarshotRules.shows(on.copy(earshotSnoozedUntil = 1000), typing, 1000))
        assertFalse("hidden in this app", EarshotRules.shows(on.copy(earshotHiddenApps = listOf("com.example.chat")), typing, 0))
    }
}
