package app.quoth.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import kotlin.math.abs

// Ported from Tests/QuothCoreTests/PersonalTests.swift (AutoLearn is in AutoLearnTest).

class DictionaryTest {
    private val entries = listOf(
        DictionaryEntry.replacement("cube control", "kubectl"),
        DictionaryEntry.replacement("control", "CONTROL"),
        DictionaryEntry.word("Kubernetes"),
        DictionaryEntry.replacement("can", "CAN-bus"),
    )

    private fun apply(s: String) = TextRules.applyDictionary(s, entries).first

    @Test fun replacementKeepsSavedCapitalisation() {
        assertEquals("I love kubectl.", apply("I love cube control."))
        assertEquals("kubectl rocks", apply("CUBE CONTROL rocks"))
    }

    @Test fun longestPhraseWins() {
        // "control" must not fire inside the already-replaced "cube control"
        assertEquals("kubectl and CONTROL", apply("cube control and control"))
    }

    @Test fun wholeWordsOnly() = assertEquals("remote controls", apply("remote controls"))

    @Test fun possessivesMatchContractionsDont() {
        assertEquals("kubectl's output", apply("cube control's output"))
        assertEquals("I can't go", apply("I can't go"))
    }

    @Test fun wordEntriesFixCasing() {
        val (out, fired) = TextRules.applyDictionary("deploy to kubernetes today", entries)
        assertEquals("deploy to Kubernetes today", out)
        assertEquals(1, fired.size)
        assertTrue(TextRules.applyDictionary("Kubernetes ok", entries).second.isEmpty())
    }

    @Test fun validation() {
        val p = PersonalData(dictionary = listOf(DictionaryEntry.word("Alex")))
        assertEquals(PersonalData.ValidationError.EMPTY, p.validate(DictionaryEntry.word("  ")))
        assertEquals(PersonalData.ValidationError.SYMBOLS_ONLY, p.validate(DictionaryEntry.word("!!!")))
        assertEquals(PersonalData.ValidationError.TOO_LONG, p.validate(DictionaryEntry.word("a".repeat(61))))
        assertEquals(PersonalData.ValidationError.DUPLICATE, p.validate(DictionaryEntry.word("alex")))
        assertNull(p.validate(DictionaryEntry.word("Quoth")))
    }

    @Test fun vocabularyPrefersStarredAndUsed() {
        val p = PersonalData(dictionary = listOf(
            DictionaryEntry.word("Alpha").copy(uses = 1),
            DictionaryEntry.word("Beta").copy(uses = 9),
            DictionaryEntry.word("Gamma", starred = true),
        ))
        assertEquals(listOf("Gamma", "Beta", "Alpha"), p.vocabulary())
        assertEquals(listOf("Gamma", "Beta"), p.vocabulary(budget = 14))
    }

    @Test fun persistsRoundTrip() {
        val file = Files.createTempFile("personal", ".json").toFile()
        val p = PersonalData(
            dictionary = listOf(DictionaryEntry.word("Alex")),
            snippets = listOf(Snippet(trigger = "my email", expansion = "a@b.c")),
            styles = StylePrefs().with(StyleCategory.EMAIL, StyleTone.CASUAL),
        )
        PersonalStore.save(p, file)
        assertEquals(p, PersonalStore.load(file))
        file.delete()
    }

    @Test fun readsMacPersonalJson() {
        // The shape Swift's JSONEncoder writes (sortedKeys, Date as seconds since 2001, nil keys left out).
        val mac = """{"autoLearn":true,"deletedWords":["aleks"],"dictionary":[{"autoLearned":false,"createdAt":783000000.5,
            "id":"5D2B1F7E-0C4B-4E57-9E43-2E6C4AB7F001","kind":"replacement","phrase":"cube control","replacement":"kubectl",
            "starred":true,"uses":3}],"polish":{"clarifyMainPoint":false,"clarity":true,"concise":true,"custom":[],"impact":false,
            "maintainTone":true,"reorder":false,"structure":false},"snippets":[{"expansion":"https://cal.com/a",
            "id":"5D2B1F7E-0C4B-4E57-9E43-2E6C4AB7F002","trigger":"my calendar"}],"styles":{"email":"formal","other":"formal",
            "personal":"veryCasual","work":"casual"},"transforms":[]}"""
        val file = Files.createTempFile("personal", ".json").toFile()
        file.writeText(mac)
        val p = PersonalStore.load(file)
        assertEquals("kubectl", p.dictionary.single().output)
        assertEquals(3, p.dictionary.single().uses)
        assertEquals(StyleTone.VERY_CASUAL, p.styles.personal)
        assertEquals("my calendar", p.snippets.single().trigger)
        assertEquals(listOf("aleks"), p.deletedWords)
        file.delete()
    }
}

class SnippetTest {
    private val snippets = listOf(
        Snippet(trigger = "my calendar", expansion = "https://cal.com/alex"),
        Snippet(trigger = "my calendar link", expansion = "LINK"),
        Snippet(trigger = "sig", expansion = "Best,\nAlex"),
    )

    @Test fun spokenAloneIgnoresCaseAndPunctuation() {
        assertEquals("https://cal.com/alex", TextRules.expandSnippets("My calendar.", snippets).first)
        assertEquals("LINK", TextRules.snippetSpokenAlone("MY CALENDAR LINK!", snippets)?.expansion)
    }

    @Test fun insideSentence() {
        assertEquals("Here is LINK, enjoy.", TextRules.expandSnippets("Here is my calendar link, enjoy.", snippets).first)
        assertEquals("Book via https://cal.com/alex.", TextRules.expandSnippets("Book via my calendar.", snippets).first)
    }

    @Test fun cannotTouchLetters() = assertEquals("design signals", TextRules.expandSnippets("design signals", snippets).first)
}

class StyleTest {
    private fun style(s: String, tone: StyleTone?, category: StyleCategory, hasSelection: Boolean = false,
                      protectedWords: List<String> = emptyList(), rawTarget: Boolean = false) =
        StyleRules.apply(s, tone, category, hasSelection, protectedWords, rawTarget)

    @Test fun categories() {
        assertEquals(StyleCategory.WORK, StyleCategory.detect("com.tinyspeck.slackmacgap", null))
        assertEquals(StyleCategory.EMAIL, StyleCategory.detect("com.google.Chrome", "Inbox (3) - Gmail"))
        assertEquals(StyleCategory.OTHER, StyleCategory.detect("com.google.Chrome", "Hacker News"))
        assertEquals(StyleCategory.PERSONAL, StyleCategory.detect("com.apple.MobileSMS", null))
        // Android apps
        assertEquals(StyleCategory.PERSONAL, StyleCategory.detect("com.whatsapp", null))
        assertEquals(StyleCategory.EMAIL, StyleCategory.detect("com.google.android.gm", null))
        assertEquals(StyleCategory.OTHER, StyleCategory.detect("com.android.chrome", null))
    }

    @Test fun formalAddsMissingPeriod() {
        assertEquals("Send it to Alex.", style("Send it to Alex", StyleTone.FORMAL, StyleCategory.OTHER))
        assertEquals("Send it to Alex", style("Send it to Alex", StyleTone.FORMAL, StyleCategory.OTHER, rawTarget = true))
        assertEquals("Ok", style("Ok", StyleTone.FORMAL, StyleCategory.OTHER))
        assertEquals("1. A\n2. B", style("1. A\n2. B", StyleTone.FORMAL, StyleCategory.OTHER))
    }

    @Test fun formalKeepsPeriods() = assertEquals("See you soon.", style("See you soon.", StyleTone.FORMAL, StyleCategory.PERSONAL))

    @Test fun casualStripsFinalPeriod() {
        assertEquals("See you soon. Bring snacks", style("See you soon. Bring snacks.", StyleTone.CASUAL, StyleCategory.WORK))
        assertEquals("Really?", style("Really?", StyleTone.CASUAL, StyleCategory.WORK))
        assertEquals("Wait", style("Wait...", StyleTone.CASUAL, StyleCategory.WORK))
    }

    @Test fun veryCasualLowercases() {
        assertEquals("hey Sam. I think NASA is cool. Alex agrees",
            style("Hey Sam. I think NASA is cool. Alex agrees.", StyleTone.VERY_CASUAL, StyleCategory.PERSONAL, protectedWords = listOf("Alex")))
    }

    @Test fun excitedOnlyStripsShortMessages() {
        assertEquals("On my way", style("On my way.", StyleTone.EXCITED, StyleCategory.PERSONAL))
        assertEquals("On my way.", style("On my way.", StyleTone.EXCITED, StyleCategory.EMAIL))
        assertEquals("A. B. C.", style("A. B. C.", null, StyleCategory.WORK))
    }

    @Test fun neverWhenSelectionOrMultiline() {
        assertEquals("Done.", style("Done.", StyleTone.CASUAL, StyleCategory.WORK, hasSelection = true))
        assertEquals("1. A\n2. B.", style("1. A\n2. B.", StyleTone.CASUAL, StyleCategory.WORK))
    }
}

class ContinuationTest {
    @Test fun midSentenceLowercasesAndSpaces() {
        assertEquals(" then we ship.", Continuation.apply("Then we ship.", "First we test,", null))
        assertEquals("Then we ship.", Continuation.apply("Then we ship.", "Done. ", null))
        assertEquals(" I agree.", Continuation.apply("I agree.", "and", null))
        assertEquals("hello ", Continuation.apply("hello", null, "world"))
    }
}

class AudioGainTest {
    @Test fun gainBoostsQuietAudioOnly() {
        assertTrue(abs(AudioGain.normalise(floatArrayOf(0.1f, -0.1f, 0.02f))[0] - 0.7f) < 0.001f)
        assertTrue(abs(AudioGain.normalise(floatArrayOf(0.01f, 0f))[0] - 0.1f) < 0.001f) // gain capped at 10x
        val loud = floatArrayOf(0.6f, -0.5f)
        assertArrayEquals(loud, AudioGain.normalise(loud), 0f)
    }
}

class DevFormattingTest {
    @Test fun filenames() {
        assertEquals("check index.ts please", DevFormatting.spokenFilenames("check index dot ts please"))
        assertEquals("open the .env file", DevFormatting.spokenFilenames("open the dot env file"))
    }

    @Test fun tagging() {
        assertEquals("Check @index.ts for bugs.", DevFormatting.tagFiles("Check index.ts for bugs."))
        assertEquals("Look @main.py and @utils.ts.", DevFormatting.tagFiles("Look at main.py and tag utils.ts."))
        assertEquals("@my_python_script.py", DevFormatting.tagFiles("Tag my python script", listOf("my_python_script.py")))
        assertEquals("Already @index.ts", DevFormatting.tagFiles("Already @index.ts"))
    }

    @Test fun identifiers() {
        val ids = DevFormatting.identifiers("let userId = fetch_user(); class HttpClient {} normal words")
        assertEquals(listOf("userId", "fetch_user", "HttpClient"), ids)
        assertEquals("pass the userId to fetch_user", DevFormatting.applyIdentifiers("pass the user ID to fetch user", ids))
    }
}

class ProcessTest {
    private fun pipe(cleaner: Cleaner) = DictationPipeline(stubTranscriber(""), cleaner, llmTimeout = 1.0)

    @Test fun fullDeterministicChain() {
        val p = PersonalData(
            dictionary = listOf(DictionaryEntry.replacement("cube control", "kubectl")),
            snippets = listOf(Snippet(trigger = "my link", expansion = "https://x.y")),
        )
        val o = DictationOutcome(raw = "")
        val ctx = CleanupContext(category = StyleCategory.WORK, tone = StyleTone.CASUAL)
        val out = pipe { raw, _, _ -> raw }.process("I use cube control, see my link.", CleanupLevel.LIGHT, ctx, p, o)
        assertEquals("I use kubectl, see https://x.y", out)
        assertTrue(o.firedEntries.size == 1 && o.firedSnippets.size == 1)
    }

    @Test fun snippetTriggersAreShieldedFromLLM() {
        // An LLM that paraphrases everything except placeholder tokens.
        val paraphraser = Cleaner { raw, _, _ -> raw.replace("you can book", "Feel free to book") }
        val p = PersonalData(snippets = listOf(Snippet(trigger = "my calendar link", expansion = "https://cal.com/a")))
        val o = DictationOutcome(raw = "")
        val out = pipe(paraphraser).process("you can book here my calendar link", CleanupLevel.LIGHT, CleanupContext(), p, o)
        assertEquals("Feel free to book here https://cal.com/a", out)
        assertEquals(listOf(p.snippets[0].id), o.firedSnippets)
    }

    @Test fun droppedTokenFallsBack() {
        val p = PersonalData(snippets = listOf(Snippet(trigger = "my calendar link", expansion = "https://cal.com/a")))
        val o = DictationOutcome(raw = "")
        val out = pipe(stubCleaner("Book here.")).process("book here my calendar link", CleanupLevel.LIGHT, CleanupContext(), p, o)
        assertEquals("Book here https://cal.com/a.", out)
        assertEquals("cleanup dropped a snippet", o.fallbackReason)
    }

    @Test fun greetingJoinedOutsideEmail() {
        val pipe = pipe(stubCleaner("Hey Sam,\n\nAre you free?"))
        val o = DictationOutcome(raw = "")
        assertEquals("Hey Sam, are you free?",
            pipe.process("hey sam are you free", CleanupLevel.LIGHT, CleanupContext(category = StyleCategory.PERSONAL), PersonalData(), o))
        assertEquals("Hey Sam,\n\nAre you free?",
            pipe.process("hey sam are you free", CleanupLevel.LIGHT, CleanupContext(category = StyleCategory.EMAIL), PersonalData(), o))
    }

    @Test fun snippetAloneSkipsLLM() {
        val p = PersonalData(snippets = listOf(Snippet(trigger = "sig", expansion = "Best,\nAlex")))
        assertEquals("Best,\nAlex", pipe(stubCleaner("WRONG")).process("Sig.", CleanupLevel.LIGHT, CleanupContext(), p, DictationOutcome(raw = "")))
    }
}
