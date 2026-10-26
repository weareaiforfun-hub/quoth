package app.quoth.android

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.provider.Settings
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import app.quoth.core.ModelFile

/** Home: setup until it's done, a box to try the keyboard in, and the way to the other screens. */
class MainActivity : Activity() {
    private lateinit var micStep: Step
    private lateinit var modelStep: Step
    private lateinit var cleanupStep: Step
    private lateinit var enableStep: Step
    private lateinit var switchStep: Step
    private lateinit var setup: LinearLayout
    private lateinit var ready: View
    private var unlisten: (() -> Unit)? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (BuildConfig.DEBUG && intent.getBooleanExtra("evals", false)) Speech.runEvals(this)
        val dp = resources.displayMetrics.density
        val pad = (20 * dp).toInt()

        val column = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        column.addView(Ui.text(this, "Quoth", 30f))
        column.addView(Ui.text(this, "Speak, and the text appears in whatever app you're typing in. Everything runs on this phone.",
            15f, Ui.MUTED).apply { setPadding(0, (4 * dp).toInt(), 0, pad) })

        micStep = Step("1. Allow the microphone", "Allow") {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 1)
        }
        modelStep = Step("2. Download the speech model (${Speech.model.bytes / 1_000_000} MB)", "Download") {
            Downloads.start(this, Speech.model)
        }
        cleanupStep = Step("", "Download") { Speech.cleanupModel(this)?.let { Downloads.start(this, it) } }
        enableStep = Step("4. Turn on the Quoth keyboard", "Open settings") {
            startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
        }
        switchStep = Step("5. Switch to Quoth", "Choose keyboard") {
            getSystemService(InputMethodManager::class.java).showInputMethodPicker()
        }
        setup = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            for (s in listOf(micStep, modelStep, cleanupStep, enableStep, switchStep)) addView(s.view)
        }
        ready = Ui.card(this).apply {
            addView(Ui.text(context, "✓ Quoth is ready", 17f, Ui.GREEN))
            addView(Ui.text(context, "In any app, tap the keyboard button at the bottom right and pick Quoth.", 14f, Ui.MUTED),
                Ui.gap(context, 2))
        }
        column.addView(setup)
        column.addView(ready)

        column.addView(Ui.text(this, "Try it here", 17f).apply { setPadding(0, pad, 0, (8 * dp).toInt()) })
        column.addView(EditText(this).apply {
            hint = "Tap here, then tap the microphone on the Quoth keyboard"
            minLines = 4
            gravity = Gravity.TOP
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            contentDescription = "Try it here"
            // Debug builds only, for automated tests: --ez password true makes this a password box, --ez search true
            // a one-line search box, and --ez incognito true asks keyboards not to remember (like an incognito tab).
            if (BuildConfig.DEBUG && intent.getBooleanExtra("password", false))
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            if (BuildConfig.DEBUG && intent.getBooleanExtra("search", false)) {
                inputType = InputType.TYPE_CLASS_TEXT
                imeOptions = EditorInfo.IME_ACTION_SEARCH
                minLines = 1
            }
            if (BuildConfig.DEBUG && intent.getBooleanExtra("incognito", false))
                imeOptions = imeOptions or EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
        })

        column.addView(Ui.text(this, "Make it yours", 17f).apply { setPadding(0, pad, 0, (8 * dp).toInt()) })
        for ((title, about, screen) in listOf(
            Triple("History", "Your recent dictations", HistoryScreen::class.java),
            Triple("Dictionary", "Names and words to spell your way", DictionaryScreen::class.java),
            Triple("Snippets", "Short phrases that type longer text", SnippetsScreen::class.java),
            Triple("Style", "Capitals and punctuation per kind of app", StyleScreen::class.java),
            Triple("Settings", "Clean-up, models, languages, history", SettingsScreen::class.java),
        )) {
            column.addView(Ui.card(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(LinearLayout(context).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(Ui.text(context, title))
                    addView(Ui.text(context, about, 13f, Ui.MUTED))
                }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
                addView(Ui.text(context, "›", 22f, Ui.MUTED))
                isClickable = true
                contentDescription = title
                setOnClickListener { startActivity(Intent(context, screen)) }
            }, Ui.gap(this, 8))
        }

        val scroll = ScrollView(this).apply {
            setBackgroundColor(Ui.PAPER)
            addView(column)
        }
        Ui.fitSystemBars(scroll, pad)
        setContentView(scroll)
    }

    override fun onResume() {
        super.onResume()
        unlisten = Downloads.listen { refresh() }
        refresh()
    }

    override fun onPause() {
        unlisten?.invoke()
        super.onPause()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) refresh() // the keyboard picker is a dialog: no onResume after it closes
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        refresh()
    }

    private fun refresh() {
        val imm = getSystemService(InputMethodManager::class.java)
        val ours = imm.enabledInputMethodList.firstOrNull { it.packageName == packageName }
        val current = Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
        micStep.done = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        modelStep.show(Speech.model, Speech.isModelInstalled(this))
        val cleanup = Speech.cleanupModel(this)
        cleanupStep.view.visibility = if (cleanup == null) View.GONE else View.VISIBLE
        if (cleanup != null) {
            cleanupStep.title.text = "3. Download the clean-up model (%.1f GB)".format(cleanup.bytes / 1e9)
            cleanupStep.show(cleanup, Speech.isInstalled(this, cleanup))
            if (!cleanupStep.done && Downloads.state(cleanup) == null) {
                cleanupStep.detail("Optional. Removes ums, applies corrections and fixes punctuation. Best on Wi-Fi.")
            }
        }
        enableStep.done = ours != null
        if (!enableStep.done) {
            enableStep.detail("Android warns that a keyboard may collect what you type. Quoth reads only a little text around " +
                "the cursor while you dictate, to fit the new words in, and it never leaves this phone.")
        }
        switchStep.done = ours != null && current == ours.id
        // Once everything needed is done, setup folds away (the optional clean-up step stays until it's downloaded).
        val essentials = micStep.done && modelStep.done && enableStep.done && switchStep.done
        for (s in listOf(micStep, modelStep, enableStep, switchStep)) s.view.visibility = if (essentials) View.GONE else View.VISIBLE
        if (essentials && cleanupStep.done) cleanupStep.view.visibility = View.GONE
        ready.visibility = if (essentials) View.VISIBLE else View.GONE
    }

    /** One setup row: a label and a button that turns into a tick once the step is done. */
    private inner class Step(label: String, private val action: String, onClick: () -> Unit) {
        private val dp = resources.displayMetrics.density
        val title: TextView = Ui.text(this@MainActivity, label)
        private val note = Ui.text(this@MainActivity, "", 13f, Ui.MUTED).apply { visibility = View.GONE }
        private val tick = Ui.text(this@MainActivity, "✓", 22f, Ui.GREEN).apply { contentDescription = "Done" }
        private val progress = ProgressBar(this@MainActivity, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 1000
            visibility = View.GONE
        }
        val button: Button = Ui.button(this@MainActivity, action, primary = true) { onClick() }
        val view = LinearLayout(this@MainActivity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, (8 * dp).toInt(), 0, (8 * dp).toInt())
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(title, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
                addView(button)
                addView(tick)
            })
            addView(progress)
            addView(note)
        }

        var done = false
            set(value) {
                field = value
                button.visibility = if (value) View.GONE else View.VISIBLE
                tick.visibility = if (value) View.VISIBLE else View.GONE
                if (value) note.visibility = View.GONE
            }

        fun detail(text: String) {
            note.text = text
            note.visibility = View.VISIBLE
        }

        /** Shows a model download's state: done, running (with progress), failed, or not started. */
        fun show(model: ModelFile, installed: Boolean) {
            val dl = Downloads.state(model)
            done = installed
            progress.visibility = if (dl?.running == true) View.VISIBLE else View.GONE
            if (dl?.running == true) progress.progress = (dl.have * 1000 / dl.total).toInt()
            button.isEnabled = dl?.running != true
            button.text = when {
                dl?.running == true -> "Downloading…"
                dl?.error != null -> "Try again"
                else -> action
            }
            dl?.error?.let { detail("Download stopped: $it. It will continue where it left off.") }
        }
    }
}
