package app.quoth.android

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.inputmethodservice.InputMethodService
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.util.Log
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.WindowInsets
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import app.quoth.core.CleanupContext
import app.quoth.core.FieldKind
import app.quoth.core.StyleCategory

/**
 * The Quoth keyboard: one big microphone button. Tap to talk, tap again to finish, and the
 * transcribed text goes into whatever app has the text field. ⌨ returns to the user's normal keyboard.
 */
class QuothKeyboardService : InputMethodService() {
    private val recorder = Recorder()
    private val main = Handler(Looper.getMainLooper())
    private lateinit var status: TextView
    private lateinit var mic: Button
    private var busy = false
    private var secureField = false
    /** The app asked keyboards not to learn here (an incognito tab, for example): no History, no auto-learn. */
    private var incognito = false
    /** A short message shown instead of "Tap to speak" until the next dictation. */
    private var note: String? = null
    private val learnCheck = Runnable { checkForCorrections() }

    override fun onCreate() {
        super.onCreate()
        Speech.warmUp(this)
    }

    override fun onCreateInputView(): View {
        val dp = resources.displayMetrics.density
        status = TextView(this).apply {
            setTextColor(INK)
            textSize = 15f
            gravity = Gravity.CENTER
            contentDescription = "Quoth status"
        }
        mic = Button(this).apply {
            text = "🎙"
            textSize = 30f
            contentDescription = "Dictate"
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(GREEN) }
            setOnClickListener { toggle() }
        }
        val switchKey = keyButton("⌨", "Switch keyboard") {
            if (!switchToPreviousInputMethod()) getSystemService(InputMethodManager::class.java).showInputMethodPicker()
        }
        val backspace = keyButton("⌫", "Delete") { sendDownUpKeyEvents(KeyEvent.KEYCODE_DEL) }
        val enter = keyButton("⏎", "Enter") { sendDefaultEditorAction(true).let { if (!it) sendDownUpKeyEvents(KeyEvent.KEYCODE_ENTER) } }

        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(switchKey, LinearLayout.LayoutParams(0, (56 * dp).toInt(), 1f))
            addView(mic, LinearLayout.LayoutParams((88 * dp).toInt(), (88 * dp).toInt()).apply {
                marginStart = (16 * dp).toInt(); marginEnd = (16 * dp).toInt()
            })
            addView(backspace, LinearLayout.LayoutParams(0, (56 * dp).toInt(), 1f))
            addView(enter, LinearLayout.LayoutParams(0, (56 * dp).toInt(), 1f))
        }
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(PAPER)
            val pad = (16 * dp).toInt()
            setPadding(pad, pad / 2, pad, pad)
            // Keep the keys clear of the gesture bar / navigation buttons (keyboards draw edge to edge).
            setOnApplyWindowInsetsListener { v, insets ->
                @Suppress("DEPRECATION")
                val bottom = if (android.os.Build.VERSION.SDK_INT >= 30) insets.getInsets(WindowInsets.Type.navigationBars()).bottom
                    else insets.systemWindowInsetBottom
                v.setPadding(pad, pad / 2, pad, pad + bottom)
                insets
            }
            addView(status, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
            addView(row, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                topMargin = pad / 2
            })
        }
    }

    private fun keyButton(label: String, description: String, action: () -> Unit) = Button(this).apply {
        text = label
        textSize = 20f
        setTextColor(INK)
        contentDescription = description
        background = GradientDrawable().apply { cornerRadius = 12 * resources.displayMetrics.density; setColor(KEY) }
        setOnClickListener { action() }
    }

    override fun onStartInputView(info: EditorInfo, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        secureField = isPasswordField(info)
        incognito = info.imeOptions and EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING != 0
        refresh()
        // Back in a field after using another keyboard: see whether the last dictation was corrected.
        checkForCorrections()
    }

    override fun onUpdateSelection(oldSelStart: Int, oldSelEnd: Int, newSelStart: Int, newSelEnd: Int,
                                   candidatesStart: Int, candidatesEnd: Int) {
        super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
        // Edits made while Quoth is up (its delete key, or the app itself): check once they settle.
        main.removeCallbacks(learnCheck)
        main.postDelayed(learnCheck, 3000)
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        main.removeCallbacks(learnCheck)
        checkForCorrections()
        if (recorder.isRecording) recorder.stop()
        super.onFinishInputView(finishingInput)
        if (!busy) refresh()
    }

    private fun refresh() {
        if (!::status.isInitialized) return
        val ready = problem() == null
        status.text = problem() ?: if (recorder.isRecording) "Listening… tap to finish" else note ?: "Tap to speak"
        mic.isEnabled = ready && !busy
        mic.alpha = if (mic.isEnabled) 1f else 0.4f
        (mic.background as GradientDrawable).setColor(if (recorder.isRecording) RED else GREEN)
    }

    /** Why dictation can't run right now, in words for the user, or null if it can. */
    private fun problem(): String? = when {
        secureField -> "Quoth is off in password fields"
        checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED ->
            "Open the Quoth app to allow the microphone"
        !Speech.isModelInstalled(this) -> "Open the Quoth app to download the speech model"
        else -> null
    }

    private fun toggle() {
        if (busy || problem() != null) return
        if (!recorder.isRecording) {
            note = null
            checkForCorrections()
            if (!recorder.start()) status.text = "The microphone couldn't start"
            refresh()
            return
        }
        var samples = recorder.stop()
        Speech.debugInput(this)?.let { samples = Recorder.readWav(it); Log.i(Speech.TAG, "debug input: ${it.name}") }
        busy = true
        refresh()
        status.text = if (Speech.warming) "Getting ready… (only after a restart)" else "Writing…"
        Speech.dictate(this, samples, target(), keepHistory = !incognito) { outcome ->
            main.post {
                busy = false
                when {
                    outcome == null -> { refresh(); status.text = "Something went wrong. Try again." }
                    outcome.final.isBlank() -> { refresh(); status.text = "Didn't catch that. Try again." }
                    else -> { insert(outcome.final, outcome.language); refresh() }
                }
            }
        }
    }

    /** Where the text is going: the app (for its writing style), the kind of field, and the text around the cursor. */
    private fun target(): CleanupContext {
        val info = currentInputEditorInfo
        val app = info?.packageName
        val category = StyleCategory.detect(app, null)
        val ic = currentInputConnection
        val field = info?.let { fieldKind(it) } ?: FieldKind.NORMAL
        return CleanupContext(
            bundleID = app,
            category = category,
            tone = Store.personal(this).styles[category],
            textBeforeCursor = ic?.getTextBeforeCursor(600, 0)?.toString(),
            textAfterCursor = ic?.getTextAfterCursor(100, 0)?.toString(),
            hasSelection = !ic?.getSelectedText(0).isNullOrEmpty(),
            field = field,
            // Search boxes and address bars want plain words, not formatted prose.
            preferRawFormatting = field == FieldKind.SEARCH,
        )
    }

    /** Inserts the finished text at the cursor; the pipeline has already fitted its spacing and case to the field. */
    private fun insert(text: String, language: String?) {
        val ic = currentInputConnection ?: return
        ic.commitText(text, 1)
        Log.i(Speech.TAG, "inserted ${text.length} chars")
        val after = fieldText()
        if (!incognito && after != null && after.contains(text.trim())) {
            AutoLearner.watch(currentInputEditorInfo?.packageName, currentInputEditorInfo?.fieldId ?: 0, text, after, language)
        } else {
            AutoLearner.forget()
        }
    }

    /** The field's text around the cursor (long fields are cut a few thousand characters either side). */
    private fun fieldText(): String? {
        val ic = currentInputConnection ?: return null
        val before = ic.getTextBeforeCursor(4000, 0) ?: return null
        return before.toString() + (ic.getTextAfterCursor(4000, 0) ?: "")
    }

    private fun checkForCorrections() {
        if (secureField || incognito) return
        val info = currentInputEditorInfo ?: return
        AutoLearner.check(this, info.packageName, info.fieldId, fieldText()) { words ->
            note = "Added to your Dictionary: ${words.joinToString(", ")}"
            if (!busy && !recorder.isRecording) refresh()
        }
    }

    /** One-line fields, search boxes and subject lines, from what the app says about the field. */
    private fun fieldKind(info: EditorInfo): FieldKind {
        val type = info.inputType
        if (type and InputType.TYPE_MASK_CLASS != InputType.TYPE_CLASS_TEXT) return FieldKind.NORMAL
        val variation = type and InputType.TYPE_MASK_VARIATION
        val action = info.imeOptions and EditorInfo.IME_MASK_ACTION
        return when {
            variation == InputType.TYPE_TEXT_VARIATION_URI || variation == InputType.TYPE_TEXT_VARIATION_FILTER ||
                variation == InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS ||
                (action == EditorInfo.IME_ACTION_SEARCH || action == EditorInfo.IME_ACTION_GO) &&
                type and InputType.TYPE_TEXT_FLAG_MULTI_LINE == 0 -> FieldKind.SEARCH
            variation == InputType.TYPE_TEXT_VARIATION_EMAIL_SUBJECT -> FieldKind.SUBJECT
            type and InputType.TYPE_TEXT_FLAG_MULTI_LINE == 0 -> FieldKind.SINGLE_LINE
            else -> FieldKind.NORMAL
        }
    }

    private fun isPasswordField(info: EditorInfo): Boolean {
        val cls = info.inputType and InputType.TYPE_MASK_CLASS
        val variation = info.inputType and InputType.TYPE_MASK_VARIATION
        return when (cls) {
            InputType.TYPE_CLASS_TEXT -> variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
            InputType.TYPE_CLASS_NUMBER -> variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
            else -> false
        }
    }

    companion object {
        private val PAPER = Color.parseColor("#F4EFE6")
        private val KEY = Color.parseColor("#E6DFD2")
        private val INK = Color.parseColor("#1F1E1C")
        private val GREEN = Color.parseColor("#2F5D45")
        private val RED = Color.parseColor("#B3412E")
    }
}
