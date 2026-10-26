package app.quoth.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// Port of AutoLearnTests in Tests/QuothCoreTests/PersonalTests.swift, plus Android's field rules.
class AutoLearnTest {
    private val common: (String) -> Boolean = { it in setOf("the", "deploy", "to", "today", "apple", "with", "call", "cube", "or", "nettis") }

    @Test fun learnsCorrectedName() {
        val c = AutoLearn.candidates("Call with Aleks today.", "Notes: Call with Aleks today.",
            "Notes: Call with Alex today.", common, emptyList(), emptyList())
        assertEquals(listOf("Alex"), c)
    }

    @Test fun multiWordToOne() {
        val c = AutoLearn.candidates("deploy to cube or nettis", "deploy to cube or nettis",
            "deploy to Kubernetes", common, emptyList(), emptyList())
        assertEquals(listOf("Kubernetes"), c)
    }

    @Test fun skipsRewritesCommonWordsAndDeleted() {
        // Unrelated rewrite (low similarity)
        assertTrue(AutoLearn.candidates("call Aleks", "call Aleks", "call Bob", common, emptyList(), emptyList()).isEmpty())
        // Common word
        assertTrue(AutoLearn.candidates("an aple", "an aple", "an apple", common, emptyList(), emptyList()).isEmpty())
        // Previously deleted, or already known
        assertTrue(AutoLearn.candidates("Aleks", "Aleks", "Alex", common, emptyList(), listOf("alex")).isEmpty())
        assertTrue(AutoLearn.candidates("Aleks", "Aleks", "Alex", common, listOf("Alex"), emptyList()).isEmpty())
        // Edits outside the pasted text
        assertTrue(AutoLearn.candidates("hello", "Aleks hello", "Alex hello", common, emptyList(), emptyList()).isEmpty())
        // A rewrite of more than four words
        assertTrue(AutoLearn.candidates("a b c d e", "a b c d e", "Kubernetes Kubernetes Kubernetes Kubernetes Kubernetes",
            common, emptyList(), emptyList()).isEmpty())
        // URLs, numbers, acronyms, emoji
        assertFalse(AutoLearn.isLearnable("https://x.com", common))
        assertFalse(AutoLearn.isLearnable("12:30", common))
        assertFalse(AutoLearn.isLearnable("PDF", common))
        assertFalse(AutoLearn.isLearnable("Yay🎉", common))
        assertTrue(AutoLearn.isLearnable("iPhone") { true })
    }

    @Test fun learningAddsValidWordsOnce() {
        val (p, added) = PersonalData().learning(listOf("Alex", "alex", "Kubernetes"))
        assertEquals(listOf("Alex", "Kubernetes"), added)
        assertTrue(p.dictionary.all { it.autoLearned })
    }

    @Test fun similarityIsNormalisedLevenshtein() {
        assertEquals(1.0, AutoLearn.similarity("abc", "abc"), 1e-9)
        assertEquals(0.8, AutoLearn.similarity("aleks", "alexs"), 1e-9)
        assertEquals(0.0, AutoLearn.similarity("abc", "xyz"), 1e-9)
    }

    @Test fun fieldRules() {
        assertEquals("Milk\n- eggs", FieldRules.apply("Milk\n- eggs", FieldKind.NORMAL))
        assertEquals("Milk - eggs.", FieldRules.apply("Milk\n- eggs.", FieldKind.SINGLE_LINE))
        assertEquals(" weather in Berlin", FieldRules.apply(" weather in Berlin.", FieldKind.SEARCH))
        assertEquals("Is it ready?", FieldRules.apply("Is it ready?", FieldKind.SUBJECT))
        assertEquals("Lunch on Friday", FieldRules.apply("Lunch on Friday...", FieldKind.SUBJECT))
    }

    @Test fun pipelineAppliesFieldRules() {
        val pipeline = DictationPipeline({ _, _, _ -> TranscriptionResult("weather in berlin", "en") }, null, 10.0)
        val o = pipeline.run(FloatArray(16000) { 0.1f }, CleanupLevel.NONE, emptyList(),
            CleanupContext(field = FieldKind.SEARCH, preferRawFormatting = true))
        assertFalse(o.final, o.final.endsWith("."))
    }
}

class WordListTest {
    @Test fun findsExactLinesOnly() {
        val list = WordList("apple\napples\ncube\ndon't\nzebra\n")
        assertEquals(5, list.size)
        for (w in listOf("apple", "apples", "cube", "don't", "zebra")) assertTrue(w, w in list)
        for (w in listOf("app", "applesauce", "a", "", "zebras", "Apple")) assertFalse(w, w in list)
    }

    @Test fun bundledListKnowsOrdinaryWordsNotNames() {
        val file = java.io.File("../app/src/main/assets/common-words-en.txt")
        val list = WordList(file.readText())
        assertTrue(list.size > 50_000)
        for (w in listOf("apple", "apples", "tomorrow", "email", "running", "deploy")) assertTrue(w, w in list)
        for (w in listOf("nadiah", "kubernetes", "aleks", "raavi", "kubectl")) assertFalse(w, w in list)
        // So a corrected name is learned, and a corrected ordinary word isn't.
        assertEquals(listOf("Nadiah"), AutoLearn.candidates("Please call Nadia.", "Please call Nadia.", "Please call Nadiah.",
            { it in list }, emptyList(), emptyList()))
        assertTrue(AutoLearn.candidates("I bought apples.", "I bought apples.", "I bought apple.",
            { it in list }, emptyList(), emptyList()).isEmpty())
    }
}
