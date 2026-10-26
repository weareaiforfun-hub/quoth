package app.quoth.android

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import app.quoth.core.AutoLearn
import app.quoth.core.WordList
import kotlin.concurrent.thread

/**
 * Learns names from corrections. After an insert the keyboard remembers the field's text; when Quoth
 * sees that field again (it comes back after you fixed a word with your other keyboard, or you edit
 * with Quoth's own keys) it compares, and adds corrected names to the Dictionary (AutoLearn decides which).
 *
 * Android keyboards can't see a field while another keyboard is in use, so a correction followed by
 * sending the message without coming back to Quoth isn't seen. History's Edit covers that case.
 */
object AutoLearner {
    /** How long after an insert a correction still counts. */
    private const val WINDOW_MS = 10 * 60_000L

    private class Watch(val app: String?, val field: Int, val inserted: String, val before: String,
                        val language: String?, val at: Long)

    private var watch: Watch? = null

    /** Remembers an insert. [fieldText] is the field's whole text right after it. */
    @Synchronized
    fun watch(app: String?, field: Int, inserted: String, fieldText: String, language: String?) {
        watch = Watch(app, field, inserted, fieldText, language, System.currentTimeMillis())
    }

    @Synchronized
    fun forget() { watch = null }

    /**
     * Compares the field's text now with the text after the last insert. If it changed, the watch ends
     * and any learned words are passed to [learned] on the main thread.
     */
    fun check(context: Context, app: String?, field: Int, fieldText: String?, learned: (List<String>) -> Unit) {
        if (fieldText == null) return
        val w = synchronized(this) {
            val w = watch ?: return
            if (System.currentTimeMillis() - w.at > WINDOW_MS) { watch = null; return }
            if (w.app != app || w.field != field || fieldText == w.before) return
            watch = null
            w
        }
        val appContext = context.applicationContext
        thread(name = "quoth-learn") {
            val words = learnable(appContext, w.inserted, w.before, fieldText, w.language)
            if (words.isEmpty()) return@thread
            var added = emptyList<String>()
            Store.updatePersonal(appContext) { p -> p.learning(words).also { added = it.second }.first }
            Log.i(Speech.TAG, "auto-learn: ${added.size} word(s)")
            if (added.isNotEmpty()) Handler(Looper.getMainLooper()).post { learned(added) }
        }
    }

    /** AutoLearn's words for an edit from [before] to [after], or none if auto-learn is off. Not on the main thread. */
    fun learnable(context: Context, inserted: String, before: String, after: String, language: String?): List<String> {
        val personal = Store.personal(context)
        if (!personal.autoLearn) return emptyList()
        val common = commonWords(context, language)
        return AutoLearn.candidates(inserted, before, after, common, personal.dictionary.map { it.output }, personal.deletedWords)
    }

    /**
     * Ordinary words, from the bundled English list. The phone's spell checker isn't used: called from a keyboard
     * it can answer that every word is fine. For other languages every word counts as ordinary, so only words
     * with a capital inside ("iPhone", "McKenzie") are learned.
     */
    private fun commonWords(context: Context, language: String?): (String) -> Boolean {
        if (language != null && language != "en") return { true }
        val list = words ?: synchronized(this) {
            words ?: WordList(context.assets.open("common-words-en.txt").bufferedReader().use { it.readText() }).also { words = it }
        }
        return { it in list }
    }

    @Volatile private var words: WordList? = null
}
