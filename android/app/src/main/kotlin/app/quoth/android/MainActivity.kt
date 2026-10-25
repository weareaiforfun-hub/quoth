package app.quoth.android

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import android.provider.Settings
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import app.quoth.core.ModelFile
import kotlin.concurrent.thread

/** Setup: microphone, speech model, enabling the keyboard, and a box to try it in. */
class MainActivity : Activity() {
    private lateinit var micStep: Step
    private lateinit var modelStep: Step
    private lateinit var cleanupStep: Step
    private lateinit var enableStep: Step
    private lateinit var switchStep: Step
    private val downloading = mutableSetOf<String>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (BuildConfig.DEBUG && intent.getBooleanExtra("evals", false)) Speech.runEvals(this)
        val dp = resources.displayMetrics.density
        val pad = (20 * dp).toInt()

        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad * 2, pad, pad)
        }
        column.addView(TextView(this).apply {
            text = "Quoth"
            textSize = 30f
            setTextColor(INK)
        })
        column.addView(TextView(this).apply {
            text = "Speak, and the text appears in whatever app you're typing in. Everything runs on this phone."
            textSize = 15f
            setTextColor(MUTED)
            setPadding(0, (4 * dp).toInt(), 0, pad)
        })

        micStep = Step("1. Allow the microphone", "Allow") {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 1)
        }
        modelStep = Step("2. Download the speech model (${Speech.model.bytes / 1_000_000} MB)", "Download") {
            download(Speech.model, modelStep)
        }
        val cleanup = Speech.cleanupModel(this)
        cleanupStep = Step("3. Download the clean-up model (%.1f GB)".format(cleanup.bytes / 1e9), "Download") {
            download(cleanup, cleanupStep)
        }
        cleanupStep.detail("Optional. Removes ums, applies corrections and fixes punctuation. Best on Wi-Fi.")
        enableStep = Step("4. Turn on the Quoth keyboard", "Open settings") {
            startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
        }
        switchStep = Step("5. Switch to Quoth", "Choose keyboard") {
            getSystemService(InputMethodManager::class.java).showInputMethodPicker()
        }
        column.addView(micStep.view)
        column.addView(modelStep.view)
        column.addView(cleanupStep.view)
        column.addView(enableStep.view)
        column.addView(switchStep.view)

        column.addView(TextView(this).apply {
            text = "Try it here"
            textSize = 17f
            setTextColor(INK)
            setPadding(0, pad, 0, (8 * dp).toInt())
        })
        column.addView(EditText(this).apply {
            hint = "Tap here, then tap the microphone on the Quoth keyboard"
            minLines = 4
            gravity = Gravity.TOP
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            contentDescription = "Try it here"
            // Debug builds only: start with --ez password true to make this a password box (for automated tests).
            if (BuildConfig.DEBUG && intent.getBooleanExtra("password", false))
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        })

        setContentView(ScrollView(this).apply {
            setBackgroundColor(PAPER)
            addView(column)
        })
    }

    override fun onResume() {
        super.onResume()
        refresh()
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
        if (Speech.model.file !in downloading) modelStep.done = Speech.isModelInstalled(this)
        if (Speech.cleanupModel(this).file !in downloading) cleanupStep.done = Speech.isCleanupInstalled(this)
        enableStep.done = ours != null
        switchStep.done = ours != null && current == ours.id
    }

    private fun download(model: ModelFile, step: Step) {
        if (!downloading.add(model.file)) return
        step.button.isEnabled = false
        step.button.text = "Downloading…"
        step.progress.visibility = View.VISIBLE
        thread(name = "quoth-download") {
            val error = runCatching {
                Speech.downloader(this).download(model) { have, total ->
                    runOnUiThread { step.progress.progress = (have * 1000 / total).toInt() }
                }
            }.exceptionOrNull()
            runOnUiThread {
                downloading.remove(model.file)
                step.progress.visibility = View.GONE
                step.button.isEnabled = true
                step.button.text = if (error == null) "Download" else "Try again"
                if (error != null) step.detail("Download stopped: ${error.message}. It will continue where it left off.")
                refresh()
                if (error == null) Speech.warmUp(this)
            }
        }
    }

    /** One setup row: a label and a button that turns into a tick once the step is done. */
    private inner class Step(label: String, action: String, onClick: () -> Unit) {
        private val dp = resources.displayMetrics.density
        private val title = TextView(this@MainActivity).apply {
            text = label
            textSize = 16f
            setTextColor(INK)
        }
        private val note = TextView(this@MainActivity).apply {
            textSize = 13f
            setTextColor(MUTED)
            visibility = View.GONE
        }
        private val tick = TextView(this@MainActivity).apply {
            text = "✓"
            textSize = 22f
            setTextColor(GREEN)
            contentDescription = "Done"
        }
        val progress = ProgressBar(this@MainActivity, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 1000
            visibility = View.GONE
        }
        val button = Button(this@MainActivity).apply {
            text = action
            setOnClickListener { onClick() }
        }
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
    }

    companion object {
        private val PAPER = Color.parseColor("#F4EFE6")
        private val INK = Color.parseColor("#1F1E1C")
        private val MUTED = Color.parseColor("#6B675F")
        private val GREEN = Color.parseColor("#2F5D45")
    }
}
