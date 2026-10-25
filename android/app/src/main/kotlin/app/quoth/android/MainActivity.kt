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
import kotlin.concurrent.thread

/** Setup: microphone, speech model, enabling the keyboard, and a box to try it in. */
class MainActivity : Activity() {
    private lateinit var micStep: Step
    private lateinit var modelStep: Step
    private lateinit var enableStep: Step
    private lateinit var switchStep: Step
    private lateinit var progress: ProgressBar
    @Volatile private var downloading = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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
        modelStep = Step("2. Download the speech model (${Speech.model.bytes / 1_000_000} MB)", "Download") { download() }
        progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 1000
            visibility = View.GONE
        }
        enableStep = Step("3. Turn on the Quoth keyboard", "Open settings") {
            startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
        }
        switchStep = Step("4. Switch to Quoth", "Choose keyboard") {
            getSystemService(InputMethodManager::class.java).showInputMethodPicker()
        }
        column.addView(micStep.view)
        column.addView(modelStep.view)
        column.addView(progress)
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
        if (!downloading) modelStep.done = Speech.isModelInstalled(this)
        enableStep.done = ours != null
        switchStep.done = ours != null && current == ours.id
    }

    private fun download() {
        if (downloading) return
        downloading = true
        modelStep.button.isEnabled = false
        modelStep.button.text = "Downloading…"
        progress.visibility = View.VISIBLE
        thread(name = "quoth-download") {
            val error = runCatching {
                Speech.downloader(this).download(Speech.model) { have, total ->
                    runOnUiThread { progress.progress = (have * 1000 / total).toInt() }
                }
            }.exceptionOrNull()
            runOnUiThread {
                downloading = false
                progress.visibility = View.GONE
                modelStep.button.isEnabled = true
                modelStep.button.text = if (error == null) "Download" else "Try again"
                if (error != null) modelStep.detail("Download stopped: ${error.message}. It will continue where it left off.")
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
