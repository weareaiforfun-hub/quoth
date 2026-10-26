package app.quoth.android

import android.app.ActivityManager
import android.app.AlertDialog
import android.content.Intent
import android.view.Gravity
import android.widget.LinearLayout
import app.quoth.core.CleanupLevel
import app.quoth.core.LanguageVariant
import app.quoth.core.Languages
import app.quoth.core.ModelCatalog
import app.quoth.core.ModelFile
import app.quoth.core.Retention
import kotlin.concurrent.thread

class SettingsScreen : Screen() {
    override val heading = "Settings"
    override val subtitle = "How Quoth turns your speech into text. Everything runs on this phone."

    override fun onResume() {
        super.onResume()
        render() // the model may have changed on the Models screen
    }

    override fun build() {
        val s = Store.settings(this)
        val cleanup = Speech.cleanupModel(this)
        val hasCleanup = cleanup != null && Speech.isInstalled(this, cleanup)

        section("Clean-up")
        add(Ui.card(this).apply {
            val levels = CleanupLevel.entries
            addView(Ui.choices(context, listOf(
                "None" to "Whisper's text, with spoken punctuation (\"comma\", \"new line\").",
                "Light" to "Removes ums and repeats, applies corrections, fixes punctuation. Keeps your words.",
                "Medium" to "Like Light, and may also reword sentences to be clearer and shorter.",
            ), levels.indexOf(s.level)) { i -> Store.updateSettings(context) { it.copy(cleanupLevel = levels[i].raw) }; render() })
            if (s.level != CleanupLevel.NONE && !hasCleanup) {
                addView(Ui.text(context, "Light and Medium need a clean-up model. Until one is downloaded, Quoth uses None.", 13f, Ui.RED),
                    Ui.gap(context, 6))
            }
        })
        add(navRow("Clean-up model", cleanup?.name ?: "None") { startActivity(Intent(this, ModelsScreen::class.java)) })

        section("Languages")
        add(navRow("Languages", if (s.languages.isEmpty()) "Auto-detect" else s.languages.joinToString(", ") { Languages.name(it) }) {
            pickLanguages(s.languages)
        })
        add(Ui.text(this, "None chosen = detect any language. One = always that language (a little faster). " +
            "Several = detect, but only among these.", 13f, Ui.MUTED), 4)
        add(navRow("Spelling variant", s.variant.title) {
            val all = LanguageVariant.entries
            AlertDialog.Builder(this).setTitle("Spelling variant")
                .setSingleChoiceItems(all.map { it.title }.toTypedArray(), all.indexOf(s.variant)) { d, i ->
                    Store.updateSettings(this) { it.copy(languageVariant = all[i].raw) }; d.dismiss(); render()
                }.show()
        })

        section("History")
        add(Ui.card(this).apply {
            val all = Retention.entries
            addView(Ui.choices(context, all.map { it.title to null }, all.indexOf(s.retention)) { i ->
                Store.updateSettings(context) { it.copy(retention = all[i]) }; render()
            })
            addView(Ui.text(context, "Only text is kept, never audio, and it stays on this phone.", 13f, Ui.MUTED), Ui.gap(context, 4))
        })

        section("About")
        add(Ui.text(this, "Quoth ${packageManager.getPackageInfo(packageName, 0).versionName} for Android. Free and open source: " +
            "github.com/weareaiforfun-hub/quoth. Speech by whisper.cpp, clean-up by llama.cpp (both MIT).", 13f, Ui.MUTED))
    }

    private fun navRow(label: String, value: String, onClick: () -> Unit) = Ui.card(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        addView(Ui.text(context, label), LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        addView(Ui.text(context, "$value  ›", 15f, Ui.MUTED))
        isClickable = true
        setOnClickListener { onClick() }
    }

    private fun pickLanguages(current: List<String>) {
        val codes = Languages.all.map { it.first }
        val checked = BooleanArray(codes.size) { codes[it] in current }
        AlertDialog.Builder(this).setTitle("Languages you speak")
            .setMultiChoiceItems(Languages.all.map { it.second }.toTypedArray(), checked) { _, i, on -> checked[i] = on }
            .setPositiveButton("Done") { _, _ ->
                // Keep the user's order for languages already chosen; the first one is the fallback.
                val picked = codes.filterIndexed { i, _ -> checked[i] }
                val ordered = current.filter { it in picked } + picked.filter { it !in current }
                Store.updateSettings(this) { it.copy(languages = ordered) }
                render()
            }
            .setNeutralButton("Auto-detect") { _, _ -> Store.updateSettings(this) { it.copy(languages = emptyList()) }; render() }
            .setNegativeButton("Cancel", null).show()
    }
}

/** Which clean-up model to use, with downloads. The speech model is shown for completeness. */
class ModelsScreen : Screen() {
    override val heading = "Models"
    override val subtitle = "The AI models Quoth runs on this phone. They're downloaded once and work offline."
    private var unlisten: (() -> Unit)? = null

    /** The models offered here, best first for most phones, with what they're like in plain words. Measured on a Pixel 9a. */
    private val choices = listOf(
        ModelCatalog.qwen35_2b to "Recommended. Fast: about 1.5 seconds per sentence. Good at ums and punctuation, " +
            "weaker at corrections like \"Thursday, actually Friday\".",
        ModelCatalog.qwen35_4b to "Higher quality: much better at corrections and lists, but 2 to 3 times slower. " +
            "It needs about 3.5 GB of memory while you dictate, so other apps may close. Best on phones with 12 GB of RAM or more.",
    )

    override fun onResume() {
        super.onResume()
        unlisten = Downloads.listen { render() }
        render()
    }

    override fun onPause() {
        unlisten?.invoke()
        super.onPause()
    }

    override fun build() {
        val selected = Store.settings(this).cleanupModel
        section("Clean-up model")
        add(Ui.card(this).apply {
            addView(Ui.text(context, "None"))
            addView(Ui.text(context, "Whisper's text with spoken punctuation and your style rules. Nothing to download.", 13f, Ui.MUTED),
                Ui.gap(context, 2))
            addView(if (selected.isEmpty()) Ui.text(context, "✓ In use", 15f, Ui.GREEN)
                else Ui.button(context, "Use", primary = true) { choose("") },
                LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(8) })
        })
        for ((m, about) in choices) add(modelCard(m, about, m.file == selected), 10)

        section("Speech model")
        add(Ui.card(this).apply {
            val m = Speech.model
            addView(Ui.text(context, "${m.name} · ${size(m)}"))
            addView(Ui.text(context, if (Speech.isModelInstalled(context)) "✓ Downloaded. Turns your voice into text, in about 100 languages."
                else "Not downloaded yet: use the setup steps on the home screen.", 13f, Ui.MUTED), Ui.gap(context, 2))
        })
    }

    private fun modelCard(m: ModelFile, about: String, inUse: Boolean) = Ui.card(this).apply {
        addView(Ui.text(context, "${m.name} · ${size(m)}"))
        addView(Ui.text(context, about, 13f, Ui.MUTED), Ui.gap(context, 2))
        if (m == ModelCatalog.qwen35_4b && totalRamGB() < 11) {
            addView(Ui.text(context, "This phone has %.0f GB of RAM: expect it to be slow.".format(totalRamGB()), 13f, Ui.RED), Ui.gap(context, 4))
        }
        val installed = Speech.isInstalled(context, m)
        val dl = Downloads.state(m)
        val row = LinearLayout(context).apply { gravity = Gravity.CENTER_VERTICAL }
        when {
            dl?.running == true -> row.addView(Ui.text(context, "Downloading… %d%% of %s".format(dl.have * 100 / dl.total, size(m)), 15f, Ui.MUTED))
            !installed -> {
                row.addView(Ui.button(context, if (dl?.error != null) "Try again" else "Download", primary = true) {
                    Downloads.start(context, m)
                })
                if (inUse) row.addView(Ui.text(context, "   Chosen: download it to use it", 13f, Ui.MUTED))
            }
            inUse -> row.addView(Ui.text(context, "✓ In use", 15f, Ui.GREEN))
            else -> row.addView(Ui.button(context, "Use", primary = true) { choose(m.file) })
        }
        if (installed && dl?.running != true) {
            row.addView(Ui.button(context, "Delete") { delete(m) }, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { marginStart = dp(8) })
        }
        addView(row, Ui.gap(context, 8))
        dl?.error?.let { addView(Ui.text(context, "Download stopped: $it. It continues where it left off.", 13f, Ui.RED), Ui.gap(context, 4)) }
    }

    private fun choose(file: String) {
        Store.updateSettings(this) { it.copy(cleanupModel = file) }
        Speech.warmUp(this) // loads the new model (and frees the old one) before the next dictation
        render()
    }

    private fun delete(m: ModelFile) {
        AlertDialog.Builder(this).setMessage("Delete ${m.name} (${size(m)}) from this phone? You can download it again later.")
            .setPositiveButton("Delete") { _, _ ->
                thread {
                    Speech.release(m.file)
                    java.io.File(Speech.modelDir(this), m.file).delete()
                    java.io.File(cacheDir, "prompt-${m.file.removeSuffix(".gguf")}.bin").delete()
                    runOnUiThread { render() }
                }
            }
            .setNegativeButton("Cancel", null).show()
    }

    private fun size(m: ModelFile) = if (m.bytes >= 1e9) "%.1f GB".format(m.bytes / 1e9) else "${m.bytes / 1_000_000} MB"

    private fun totalRamGB(): Double {
        val info = ActivityManager.MemoryInfo()
        getSystemService(ActivityManager::class.java).getMemoryInfo(info)
        return info.totalMem / 1e9
    }
}
