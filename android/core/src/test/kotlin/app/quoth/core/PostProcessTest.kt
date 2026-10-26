package app.quoth.core

import org.junit.Assert.assertEquals
import org.junit.Test

// Ported from Tests/QuothCoreTests/CoreTests.swift (SpokenPunctuationTests, SanitizerTests).

class SpokenPunctuationTest {
    @Test fun basicSymbols() {
        assertEquals("Hello, how are you?", SpokenPunctuation.apply("hello comma how are you question mark"))
        assertEquals("Done. Next thing!", SpokenPunctuation.apply("done period next thing exclamation point"))
    }

    @Test fun lineBreaks() {
        assertEquals("Hi\nThere\n\nBye", SpokenPunctuation.apply("hi new line there new paragraph bye"))
    }

    @Test fun whisperDecoratedWords() {
        // whisper sometimes writes the spoken word with its own punctuation
        assertEquals("Hello, world.", SpokenPunctuation.apply("Hello, comma, world. Period."))
    }

    @Test fun leavesOtherWordsAlone() {
        assertEquals("The colonel and the periodic table", SpokenPunctuation.apply("the colonel and the periodic table"))
    }
}

class SanitizerTest {
    @Test fun stripsPreambleAndTags() {
        assertEquals("Hello there.", OutputSanitizer.sanitize("Here is the cleaned text:\n<transcript>\nHello there.\n</transcript>", raw = "hello there"))
    }

    @Test fun unwrapsUndictatedQuotes() {
        assertEquals("Hello there.", OutputSanitizer.sanitize("\"Hello there.\"", raw = "hello there"))
        assertEquals("\"Hi\"", OutputSanitizer.sanitize("\"Hi\"", raw = "quote hi end quote"))
    }

    @Test fun replacesEmDashes() {
        assertEquals("Wait, really?", OutputSanitizer.sanitize("Wait — really?", raw = "wait really"))
        assertEquals("A — B", OutputSanitizer.sanitize("A — B", raw = "a dash b"))
    }

    @Test fun transcriptFilter() {
        assertEquals("", TranscriptFilter.clean("[BLANK_AUDIO]"))
        assertEquals("hello world", TranscriptFilter.clean(" hello [Music] world "))
        assertEquals("", TranscriptFilter.clean("Thank you.", likelySilence = true))
        assertEquals("Thank you.", TranscriptFilter.clean("Thank you."))
        // Whisper's note when it's forced into a language the speaker isn't using.
        assertEquals("", TranscriptFilter.clean("(speaking in foreign language)"))
    }

    @Test fun audioLevel() {
        assertEquals(0f, AudioLevel.rms(FloatArray(0)))
        assertEquals(0.5f, AudioLevel.rms(floatArrayOf(0.5f, -0.5f)), 1e-6f)
    }
}
