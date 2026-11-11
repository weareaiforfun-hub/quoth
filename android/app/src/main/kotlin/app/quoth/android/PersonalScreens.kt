package app.quoth.android

import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.text.format.DateUtils
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.Switch
import android.widget.Toast
import app.quoth.core.DictionaryEntry
import kotlin.concurrent.thread
import app.quoth.core.HistoryEntry
import app.quoth.core.Retention
import app.quoth.core.StyleCategory
import app.quoth.core.StyleTone
import app.quoth.android.Ui.adopt
import app.quoth.android.Ui.clear

/** Past dictations: what was inserted, and what the speech model heard. */
class HistoryScreen : Screen() {
    override val heading = "History"
    override val subtitle = "Your recent dictations, kept on this phone only. Tap Fix to correct a name, and Quoth learns it."
    private var filter = ""
    private val search by lazy {
        Ui.field(this, "Search").apply {
            addTextChangedListener(afterChanged { filter = it; render() })
        }
    }

    override fun build() {
        val all = Store.history(this).recent()
        val retention = Store.settings(this).retention
        if (retention == Retention.NEVER) add(Ui.text(this, "History is off. You can turn it on in Settings.", 15f, Ui.MUTED))
        if (all.isEmpty()) {
            if (retention != Retention.NEVER) add(Ui.text(this, "Nothing yet. Dictate with the Quoth keyboard and it shows up here.", 15f, Ui.MUTED))
            return
        }
        content.adopt(search, Ui.gap(this, 0))
        if (filter.isNotEmpty()) search.requestFocus()
        val shown = all.filter { filter.isBlank() || it.final.contains(filter, true) || it.raw.contains(filter, true) }
        for (e in shown) add(entryCard(e), 10)
        add(Ui.button(this, "Clear history") {
            AlertDialog.Builder(this).setMessage("Delete all ${all.size} dictations from History?")
                .setPositiveButton("Delete") { _, _ -> Store.history(this).clear(); render() }
                .setNegativeButton("Cancel", null).show()
        }, 20)
    }

    private fun entryCard(e: HistoryEntry) = Ui.card(this).apply {
        val time = if (System.currentTimeMillis() - e.createdAt < 60_000) "Just now"
            else DateUtils.getRelativeDateTimeString(this@HistoryScreen, e.createdAt, DateUtils.MINUTE_IN_MILLIS, DateUtils.WEEK_IN_MILLIS, 0)
        addView(Ui.text(context, listOfNotNull(time, e.appName ?: e.app).joinToString(" · "), 13f, Ui.MUTED))
        addView(Ui.text(context, e.final).apply { setTextIsSelectable(true) }, Ui.gap(context, 4))
        if (e.raw != e.final) addView(Ui.text(context, "Heard: ${e.raw}", 13f, Ui.MUTED), Ui.gap(context, 6))
        e.fallbackReason?.let { addView(Ui.text(context, "Not cleaned up: $it", 13f, Ui.MUTED), Ui.gap(context, 2)) }
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
            addView(Ui.button(context, "Fix") { fix(e) })
            addView(Ui.button(context, "Copy") {
                getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Dictation", e.final))
                Toast.makeText(context, "Copied", Toast.LENGTH_SHORT).show()
            }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                marginStart = dp(8)
            })
            addView(Ui.button(context, "Delete") { Store.history(context).delete(e.id); render() },
                LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                    marginStart = dp(8)
                })
        }, Ui.gap(context, 8))
    }

    /** Lets the user correct a dictation; corrected names go to the Dictionary, as when correcting in the text field. */
    private fun fix(e: HistoryEntry) {
        val box = Ui.field(this, "Text", multiLine = true).apply { setText(e.final); setSelection(e.final.length) }
        val form = LinearLayout(this).apply { setPadding(dp(20), dp(8), dp(20), 0); addView(box, Ui.wide()) }
        AlertDialog.Builder(this).setTitle("Fix this dictation").setView(form)
            .setMessage(if (Store.personal(this).autoLearn) "Correct any misspelled names. Quoth adds them to your Dictionary so it gets them right next time."
                else "Correct the text. (Learning words is off in Dictionary.)")
            .setPositiveButton("Save") { _, _ ->
                val fixed = box.text.toString().trim()
                if (fixed.isEmpty() || fixed == e.final) return@setPositiveButton
                Store.history(this).edit(e.id, fixed)
                render()
                thread {
                    val words = AutoLearner.learnable(this, e.final, e.final, fixed, null)
                    var added = emptyList<String>()
                    if (words.isNotEmpty()) Store.updatePersonal(this) { p -> p.learning(words).also { added = it.second }.first }
                    runOnUiThread {
                        Toast.makeText(this, if (added.isEmpty()) "Saved" else "Added to your Dictionary: ${added.joinToString(", ")}",
                            Toast.LENGTH_LONG).show()
                    }
                }
            }
            .setNegativeButton("Cancel", null).show()
    }
}

/** Words to spell your way, and spoken phrases to replace. */
class DictionaryScreen : Screen() {
    override val heading = "Dictionary"
    override val subtitle = "Words Quoth should spell your way, and phrases to replace. Words also steer the speech model."
    private val word by lazy { Ui.field(this, "Word or name (e.g. Kubernetes)") }
    private val spoken by lazy { Ui.field(this, "When I say…") }
    private val replacement by lazy { Ui.field(this, "…write") }
    private var error: String? = null

    override fun build() {
        section("Add")
        add(Ui.card(this).apply {
            adopt(word)
            addView(Ui.button(context, "Add word", primary = true) { addEntry(DictionaryEntry.word(word.text.toString().trim())) { word.clear() } },
                Ui.gap(context, 6))
            adopt(spoken, Ui.gap(context, 16))
            adopt(replacement)
            addView(Ui.button(context, "Add replacement", primary = true) {
                addEntry(DictionaryEntry.replacement(spoken.text.toString().trim(), replacement.text.toString().trim())) {
                    spoken.clear(); replacement.clear()
                }
            }, Ui.gap(context, 6))
            error?.let { addView(Ui.text(context, it, 14f, Ui.RED), Ui.gap(context, 6)) }
        })
        add(Ui.card(this).apply {
            addView(Switch(context).apply {
                text = "Learn names when I correct a dictation"
                textSize = 16f
                setTextColor(Ui.INK)
                isChecked = Store.personal(context).autoLearn
                setOnCheckedChangeListener { _, on -> Store.updatePersonal(context) { it.copy(autoLearn = on) } }
            })
            addView(Ui.text(context, "When you fix a name Quoth got wrong, then come back to the Quoth keyboard (or use Fix in History), " +
                "Quoth adds the right spelling here. Ordinary words are never added, and words you delete stay deleted.",
                13f, Ui.MUTED), Ui.gap(context, 4))
        }, 12)
        val entries = Store.personal(this).dictionary.sortedBy { it.phrase.lowercase() }
        section(if (entries.size == 1) "1 entry" else "${entries.size} entries")
        if (entries.isEmpty()) add(Ui.text(this, "Add names, products and jargon you use often.", 15f, Ui.MUTED))
        for (e in entries) add(entryRow(e), 6)
    }

    private fun addEntry(e: DictionaryEntry, clear: () -> Unit) {
        val (next, err) = Store.personal(this).adding(e)
        error = err?.message
        if (err == null) { Store.updatePersonal(this) { next }; clear() }
        render()
    }

    private fun entryRow(e: DictionaryEntry) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        addView(Ui.button(context, if (e.starred) "★" else "☆") {
            Store.updatePersonal(context) { p -> p.copy(dictionary = p.dictionary.map { if (it.id == e.id) it.copy(starred = !it.starred) else it }) }
            render()
        }.apply {
            background = null
            setTextColor(if (e.starred) Ui.GREEN else Ui.MUTED)
            contentDescription = if (e.starred) "Starred: always sent to the speech model" else "Star: always send to the speech model"
        })
        val label = if (e.kind == DictionaryEntry.Kind.WORD) e.phrase else "${e.phrase}  →  ${e.replacement}"
        addView(Ui.text(context, label + (if (e.autoLearned) "   · learned" else "") + if (e.uses > 0) "   ${e.uses}×" else ""),
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        addView(Ui.button(context, "Delete") { Store.updatePersonal(context) { it.deleting(e.id) }; render() })
    }
}

/** Trigger phrases that expand to saved text. */
class SnippetsScreen : Screen() {
    override val heading = "Snippets"
    override val subtitle = "Say a trigger phrase and Quoth types the full text, exactly as saved."
    private val trigger by lazy { Ui.field(this, "Trigger (e.g. my calendar link)") }
    private val expansion by lazy { Ui.field(this, "The text to type", multiLine = true) }
    private var error: String? = null

    override fun build() {
        section("New snippet")
        add(Ui.card(this).apply {
            adopt(trigger)
            adopt(expansion)
            addView(Ui.button(context, "Add snippet", primary = true) {
                val (next, err) = Store.personal(context).addingSnippet(trigger.text.toString(), expansion.text.toString())
                error = err
                if (err == null) { Store.updatePersonal(context) { next }; trigger.clear(); expansion.clear() }
                render()
            }, Ui.gap(context, 6))
            error?.let { addView(Ui.text(context, it, 14f, Ui.RED), Ui.gap(context, 6)) }
        })
        val snippets = Store.personal(this).snippets
        section(if (snippets.size == 1) "1 snippet" else "${snippets.size} snippets")
        for (sn in snippets) add(Ui.card(this).apply {
            addView(Ui.text(context, sn.trigger, bold = true))
            addView(Ui.text(context, sn.expansion, 15f, Ui.MUTED), Ui.gap(context, 4))
            addView(LinearLayout(context).apply {
                gravity = Gravity.END
                addView(Ui.button(context, "Edit") { edit(sn.id, sn.trigger, sn.expansion) })
                addView(Ui.button(context, "Delete") {
                    Store.updatePersonal(context) { p -> p.copy(snippets = p.snippets.filter { it.id != sn.id }) }
                    render()
                }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                    marginStart = dp(8)
                })
            }, Ui.gap(context, 8))
        }, 8)
    }

    private fun edit(id: String, oldTrigger: String, oldText: String) {
        val t = Ui.field(this, "Trigger").apply { setText(oldTrigger) }
        val x = Ui.field(this, "Text", multiLine = true).apply { setText(oldText) }
        val form = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(8), dp(20), 0)
            addView(t); addView(x)
        }
        AlertDialog.Builder(this).setTitle("Edit snippet").setView(form)
            .setPositiveButton("Save") { _, _ ->
                val trig = t.text.toString().trim()
                if (trig.isNotEmpty() && trig.length <= 60 && x.text.isNotBlank()) {
                    Store.updatePersonal(this) { p ->
                        p.copy(snippets = p.snippets.map { if (it.id == id) it.copy(trigger = trig, expansion = x.text.toString()) else it })
                    }
                    render()
                }
            }
            .setNegativeButton("Cancel", null).show()
    }
}

/** Capitalisation and punctuation per kind of app. */
class StyleScreen : Screen() {
    override val heading = "Style"
    override val subtitle = "How capitalisation and punctuation look in each kind of app. Your words never change."

    override fun build() {
        val styles = Store.personal(this).styles
        for (cat in StyleCategory.entries) {
            section(cat.title)
            val tones = cat.allowedTones
            val current = styles[cat] ?: StyleTone.FORMAL
            add(Ui.card(this).apply {
                addView(Ui.choices(context, tones.map { it.title to null }, tones.indexOf(current)) { i ->
                    Store.updatePersonal(context) { p -> p.copy(styles = p.styles.with(cat, tones[i])) }
                    render()
                })
                addView(Ui.text(context, current.example, 14f, Ui.MUTED), Ui.gap(context, 4))
            })
        }
        add(Ui.text(this, apps(), 13f, Ui.MUTED), 8)
        section("Context")
        add(Ui.card(this).apply {
            addView(Switch(context).apply {
                text = "Use the text around the cursor"
                textSize = 16f
                setTextColor(Ui.INK)
                isChecked = Store.settings(context).contextAwareness
                setOnCheckedChangeListener { _, on -> Store.updateSettings(context) { it.copy(contextAwareness = on) } }
            })
            addView(Ui.text(context, "Quoth reads a little of the text field (never password fields) to continue sentences naturally. " +
                "It never leaves this phone.", 13f, Ui.MUTED), Ui.gap(context, 4))
        })
    }

    private fun apps() = "Personal messages: WhatsApp, Signal, Telegram, Messages and more. Work: Slack, Teams, LinkedIn. " +
        "Email: Gmail, Outlook, Proton Mail and more. Everything else uses the last style."
}

/** A TextWatcher that only cares about the text after a change. */
fun afterChanged(onChange: (String) -> Unit) = object : android.text.TextWatcher {
    override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
    override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
    override fun afterTextChanged(s: android.text.Editable?) = onChange(s?.toString().orEmpty())
}
