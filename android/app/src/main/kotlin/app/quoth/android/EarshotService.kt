package app.quoth.android

import android.Manifest
import android.accessibilityservice.AccessibilityService
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Rect
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import app.quoth.core.CleanupContext
import app.quoth.core.EarshotRules
import app.quoth.core.EarshotScene
import app.quoth.core.FieldKind
import app.quoth.core.FieldMerge
import app.quoth.core.Fields
import app.quoth.core.StyleCategory

/** Earshot's shared state: whether it's switched on, and whether Quoth's own keyboard is up (then Earshot hides). */
object Earshot {
    @Volatile var quothKeyboardUp = false
        set(value) { field = value; EarshotService.instance?.requestUpdate() }

    fun component(context: Context) = ComponentName(context, EarshotService::class.java)

    /** True when the accessibility service is switched on in Android's settings. */
    fun serviceOn(context: Context): Boolean {
        val on = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        val ours = component(context)
        return on.split(':').any { ComponentName.unflattenFromString(it) == ours }
    }

    /** Earshot works: the user agreed and turned it on in Quoth, and the service is on in Android's settings. */
    fun working(context: Context) = BuildConfig.EARSHOT && Store.settings(context).earshot && serviceOn(context)

    /** Turns Earshot off completely: Quoth's switch, and the accessibility service itself. */
    fun turnOff(context: Context) {
        Store.updateSettings(context) { it.copy(earshot = false) }
        EarshotService.instance?.disableSelf()
    }
}

/**
 * Earshot: a small Quoth bubble shown next to the keyboard whenever a text box has the cursor, for people who keep
 * their usual keyboard. Tap it, speak, tap again: the text goes through the same pipeline as the Quoth keyboard and
 * into the box. It's an accessibility service only to see which box has the cursor and to put text into it; it listens
 * to focus and window changes only (res/xml/earshot_service.xml), and never acts in password boxes.
 */
class EarshotService : AccessibilityService() {
    private val main = Handler(Looper.getMainLooper())
    private val recorder = Recorder()
    private lateinit var bubble: EarshotBubble
    private var state = State.IDLE
    /** The box the current dictation is for, and where it is. */
    private var target: AccessibilityNodeInfo? = null
    private var targetApp: String? = null
    private var recordStart = 0L
    private var warmed = false
    private var hinted = false
    private val update = Runnable { update() }
    private val tick = object : Runnable {
        override fun run() {
            if (state != State.RECORDING) return
            val s = (System.currentTimeMillis() - recordStart) / 1000
            bubble.show(EarshotBubble.Look.RECORDING, "%d:%02d".format(s / 60, s % 60))
            main.postDelayed(this, 500)
        }
    }

    private enum class State { IDLE, RECORDING, WORKING }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        bubble = EarshotBubble(this, onTap = { tap() }, onMenu = { menu() }, onMoved = { left, lift ->
            Store.updateSettings(this) { it.copy(earshotLeft = left, earshotLift = lift) }
        })
        Log.i(Speech.TAG, "earshot: connected")
        // Switched on straight from Android's settings, without Quoth's disclosure: show it first. Earshot stays hidden
        // until the user agrees, and "Not now" switches the service off again.
        if (!Store.settings(this).earshot) {
            startActivity(Intent(this, EarshotScreen::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        requestUpdate()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Events come in bursts (a window opening sends several); look once they settle.
        requestUpdate()
    }

    fun requestUpdate() {
        main.removeCallbacks(update)
        main.postDelayed(update, 150)
    }

    override fun onInterrupt() {}

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        main.removeCallbacksAndMessages(null)
        if (recorder.isRecording) recorder.stop()
        if (::bubble.isInitialized) bubble.remove()
        Log.i(Speech.TAG, "earshot: disconnected")
        return super.onUnbind(intent)
    }

    /** Shows or hides the bubble for what's on screen now. */
    private fun update() {
        if (!::bubble.isInitialized) return
        val settings = Store.settings(this)
        // Until the user agrees to the disclosure (or after turning Earshot off in Quoth), read nothing at all.
        if (!settings.earshot || !BuildConfig.EARSHOT) { if (state == State.IDLE) bubble.hide(); return }
        val field = focusedField()
        val keyboard = runCatching { windows.firstOrNull { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD } }.getOrNull()
        val keyboardTop = keyboard?.let { Rect().also(it::getBoundsInScreen).top }
        val app = field?.packageName?.toString()
        val scene = EarshotScene(app = app, password = field?.isPassword == true || field?.let { Fields.isPassword(it.inputType) } == true,
            keyboardUp = keyboardTop != null, quothKeyboard = Earshot.quothKeyboardUp || keyboard?.root?.packageName == packageName)
        if (BuildConfig.DEBUG) {
            Log.d(Speech.TAG, "earshot: $scene")
        }
        if (field != null && !scene.password) checkForCorrections(field)
        // A dictation in progress keeps the bubble where it is until it's done.
        if (state != State.IDLE) return
        if (!EarshotRules.shows(settings, scene, System.currentTimeMillis())) { bubble.hide(); return }
        bubble.place(keyboardTop!!, settings.earshotLeft, settings.earshotLift)
        if (!warmed) { warmed = true; Speech.warmUp(this) }
        if (!hinted) {
            hinted = true
            bubble.show(EarshotBubble.Look.NOTE, "Tap to talk · hold for options")
            main.postDelayed({ if (state == State.IDLE) bubble.show(EarshotBubble.Look.IDLE) }, 3000)
        } else if (!bubble.showingNote) {
            bubble.show(EarshotBubble.Look.IDLE)
        }
    }

    /**
     * The editable box that has the cursor, if any. Some apps report input focus on a container instead of the box
     * (Contacts, a Compose app, reports its whole screen), so a non-editable focus is searched for the focused
     * editable box inside it (or the only editable one).
     */
    private fun focusedField(): AccessibilityNodeInfo? {
        // The search across all windows can land on the keyboard's own window, so look in the app's window first.
        val focus = runCatching {
            rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                ?: findFocus(AccessibilityNodeInfo.FOCUS_INPUT)?.takeIf { it.window?.type != AccessibilityWindowInfo.TYPE_INPUT_METHOD }
        }.getOrNull() ?: return null
        if (focus.isEditable) return focus
        val editable = ArrayList<AccessibilityNodeInfo>()
        val queue = ArrayDeque(listOf(focus))
        var seen = 0
        while (queue.isNotEmpty() && seen < 800) {
            val node = queue.removeFirst()
            seen++
            if (node.isEditable) { if (node.isFocused) return node; editable += node; continue }
            if (!node.isVisibleToUser) continue
            for (i in 0 until node.childCount) node.getChild(i)?.let(queue::addLast)
        }
        return editable.singleOrNull()
    }

    private fun tap() {
        when (state) {
            State.IDLE -> start()
            State.RECORDING -> finish()
            State.WORKING -> {}
        }
    }

    private fun start() {
        val problem = when {
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED -> "Open Quoth to allow the microphone"
            !Speech.isModelInstalled(this) -> "Open Quoth to download the speech model"
            else -> null
        }
        if (problem != null) {
            note(problem)
            startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return
        }
        val field = focusedField() ?: return
        if (field.isPassword || Fields.isPassword(field.inputType)) return
        checkForCorrections(field)
        if (!recorder.start()) { note("The microphone couldn't start"); return }
        target = field
        targetApp = field.packageName?.toString()
        state = State.RECORDING
        recordStart = System.currentTimeMillis()
        bubble.buzz()
        main.post(tick)
    }

    private fun finish() {
        // Android may hand an app it doesn't count as in use silence instead of the microphone: say so rather than
        // transcribe nothing.
        val silenced = recorder.silenced(this)
        var samples = recorder.stop()
        Log.i(Speech.TAG, "earshot: recorded ${samples.size * 1000L / Recorder.RATE}ms, silenced=$silenced")
        val debug = Speech.debugInput(this)
        debug?.let { samples = Recorder.readWav(it); Log.i(Speech.TAG, "debug input: ${it.name}") }
        if (silenced == true && debug == null) {
            state = State.IDLE
            note("Android kept the microphone from Quoth. Try again")
            return
        }
        state = State.WORKING
        bubble.show(EarshotBubble.Look.WORKING, if (Speech.warming) "Getting ready…" else "Writing…")
        val field = target
        val ctx = context(field)
        // Android doesn't tell accessibility services when a box asked keyboards not to learn (an incognito tab), so unlike
        // the keyboard Earshot can't leave those out of History; the disclosure and privacy policy say so.
        Speech.dictate(this, samples, ctx) { outcome ->
            main.post {
                state = State.IDLE
                when {
                    outcome == null -> note("Something went wrong. Try again.")
                    outcome.final.isBlank() -> note("Didn't catch that. Try again.")
                    else -> insert(outcome.final, outcome.language)
                }
                if (!bubble.showingNote) requestUpdate()
            }
        }
    }

    /** Where the text is going: the app (for its style), the kind of box, and the text around the cursor. */
    private fun context(field: AccessibilityNodeInfo?): CleanupContext {
        field?.refresh()
        val app = field?.packageName?.toString()
        val hint = field?.hintText?.toString()
        val kind = field?.let { Fields.kind(it.inputType, multiLine = it.isMultiLine, hint = hint) } ?: FieldKind.NORMAL
        val text = field?.text?.toString()
        val showingHint = field?.isShowingHintText == true
        val (before, after) = FieldMerge.around(text, showingHint, field?.textSelectionStart ?: -1, field?.textSelectionEnd ?: -1)
        val category = StyleCategory.detect(app, null)
        return CleanupContext(
            bundleID = app,
            category = category,
            tone = Store.personal(this).styles[category],
            textBeforeCursor = before,
            textAfterCursor = after,
            hasSelection = field != null && field.textSelectionStart >= 0 && field.textSelectionStart != field.textSelectionEnd,
            field = kind,
            preferRawFormatting = kind == FieldKind.SEARCH,
        )
    }

    /** Inserts at the cursor of the box that has it now (or the one the dictation started in). */
    private fun insert(text: String, language: String?) {
        val field = focusedField()?.takeIf { it.packageName?.toString() == targetApp }
            ?: target?.takeIf { it.refresh() && it.isEditable }
        target = null
        if (field == null || field.isPassword || Fields.isPassword(field.inputType)) {
            getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Quoth", text.trim()))
            note("No text box now. Copied: paste it")
            return
        }
        field.refresh()
        val before = field.text?.toString()
        val merged = FieldMerge.merge(before, field.isShowingHintText, field.textSelectionStart, field.textSelectionEnd, text)
        val set = field.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, merged.text)
        })
        if (!set) { paste(field, text, language); return }
        field.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, merged.cursor)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, merged.cursor)
        })
        // Some apps (Compose) update the box a moment after accepting "set text", so look again shortly: paste only if
        // the box didn't change at all, never as a second copy.
        main.postDelayed({
            field.refresh()
            val now = field.text?.toString()
            if (now == before) {
                Log.i(Speech.TAG, "earshot: set text ignored, pasting")
                paste(field, text, language)
            } else {
                Log.i(Speech.TAG, "inserted ${text.length} chars (earshot)")
                watch(field, text, language)
            }
        }, 500)
    }

    /** For boxes that ignore "set text" (some web pages and custom editors): paste, which leaves the text on the clipboard. */
    private fun paste(field: AccessibilityNodeInfo, text: String, language: String?) {
        getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Quoth", text))
        val pasted = field.performAction(AccessibilityNodeInfo.ACTION_PASTE)
        Log.i(Speech.TAG, "inserted ${text.length} chars (earshot paste: $pasted)")
        if (!pasted) { note("Couldn't type here. Copied: paste it"); return }
        main.postDelayed({ field.refresh(); watch(field, text, language) }, 400)
    }

    /** Remembers the box's text after an insert, so a name corrected in it can be learned. */
    private fun watch(field: AccessibilityNodeInfo, text: String, language: String?) {
        val after = field.text?.toString()
        if (after != null && after.contains(text.trim())) AutoLearner.watch(field.packageName?.toString(), fieldId(field), text, after, language)
        else AutoLearner.forget()
    }

    private fun fieldId(field: AccessibilityNodeInfo) = field.hashCode()

    private fun checkForCorrections(field: AccessibilityNodeInfo) {
        if (field.isShowingHintText) return
        AutoLearner.check(this, field.packageName?.toString(), fieldId(field), field.text?.toString()) { words ->
            if (state == State.IDLE) note("Added to your Dictionary: ${words.joinToString(", ")}")
        }
    }

    /** A short message in the bubble, for a few seconds. */
    private fun note(message: String) {
        bubble.show(EarshotBubble.Look.NOTE, message)
        main.postDelayed({ if (state == State.IDLE) { bubble.clearNote(); requestUpdate() } }, 3500)
    }

    /** Hold the bubble: hide it for an hour, hide it in this app, or open Earshot's settings. */
    private fun menu() {
        if (state != State.IDLE) return
        val app = focusedField()?.packageName?.toString()
        val label = app?.let { Apps.label(this, it) }
        val options = buildList<Pair<String, () -> Unit>> {
            add("Hide for an hour" to {
                Store.updateSettings(this@EarshotService) { it.copy(earshotSnoozedUntil = System.currentTimeMillis() + 3_600_000) }
            })
            if (app != null && app != packageName) add("Not in $label" to {
                Store.updateSettings(this@EarshotService) { it.copy(earshotHiddenApps = (it.earshotHiddenApps + app).distinct()) }
            })
            add("Earshot settings" to {
                startActivity(Intent(this@EarshotService, EarshotScreen::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            })
        }
        bubble.menu(options) { requestUpdate() }
    }

    companion object {
        @Volatile var instance: EarshotService? = null
            private set
    }
}
