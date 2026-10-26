package app.quoth.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

class StorageTest {
    private fun tmp() = Files.createTempDirectory("quoth").toFile()

    @Test fun settingsRoundTripAndDefaults() {
        val dir = tmp()
        val store = JsonFile(java.io.File(dir, "settings.json"), AppSettings.serializer()) { AppSettings() }
        assertEquals(CleanupLevel.LIGHT, store.value.level)
        assertEquals(ModelCatalog.qwen35_2b, store.value.cleanup)
        store.update { it.copy(languages = listOf("en", "de"), retention = Retention.DAY, cleanupModel = "") }
        val again = JsonFile(java.io.File(dir, "settings.json"), AppSettings.serializer()) { AppSettings() }
        assertEquals(listOf("en", "de"), again.value.languages)
        assertEquals(Retention.DAY, again.value.retention)
        assertNull(again.value.cleanup)
        // Unknown and missing keys are fine (older or newer app versions).
        java.io.File(dir, "s2.json").writeText("""{"retention":"never","future":1}""")
        val partial = JsonFile(java.io.File(dir, "s2.json"), AppSettings.serializer()) { AppSettings() }.value
        assertEquals(Retention.NEVER, partial.retention)
        assertEquals(CleanupLevel.LIGHT, partial.level)
        dir.deleteRecursively()
    }

    @Test fun historyNewestFirstWithRetention() {
        val dir = tmp()
        val h = HistoryStore(java.io.File(dir, "history.json"), limit = 3)
        val now = 10 * 86_400_000L
        for (i in 1..4) h.add(HistoryEntry(createdAt = now - (5 - i) * 3_600_000L, raw = "r$i", final = "F$i."), Retention.NORMAL, now)
        assertEquals(listOf("F4.", "F3.", "F2."), h.recent().map { it.final }) // capped at 3
        h.add(HistoryEntry(createdAt = now - 30 * 3_600_000L, raw = "old", final = "Old."), Retention.NORMAL, now)
        assertEquals(3, h.recent().size)
        h.purge(Retention.DAY, now)
        assertTrue(h.recent().none { it.final == "Old." })
        h.delete(h.recent().first().id)
        assertEquals(1, HistoryStore(java.io.File(dir, "history.json")).recent().size)
        h.add(HistoryEntry(createdAt = now, raw = "x", final = "X."), Retention.NEVER, now)
        assertTrue(h.recent().isEmpty())
        dir.deleteRecursively()
    }

    @Test fun personalEdits() {
        var p = PersonalData()
        val (p1, err) = p.adding(DictionaryEntry.word("Kubernetes"))
        assertNull(err)
        p = p1
        assertEquals(PersonalData.ValidationError.DUPLICATE, p.adding(DictionaryEntry.word("kubernetes")).second)
        val id = p.dictionary.single().id
        p = p.countingUses(listOf(id)).countingUses(listOf(id))
        assertEquals(2, p.dictionary.single().uses)
        p = p.deleting(id)
        assertEquals(listOf("Kubernetes"), p.deletedWords)
        p = p.adding(DictionaryEntry.word("Kubernetes")).first
        assertTrue(p.deletedWords.isEmpty())
        val (p2, e2) = p.addingSnippet(" my link ", "https://x.y")
        assertNull(e2)
        assertEquals("my link", p2.snippets.single().trigger)
        assertEquals("That trigger exists", p2.addingSnippet("MY LINK", "z").second)
        assertEquals("Trigger: 60 characters at most", p2.addingSnippet("a".repeat(61), "z").second)
    }
}
