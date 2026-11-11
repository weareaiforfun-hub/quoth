package app.quoth.android

import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.abs

/**
 * Earshot's bubble: a green circle with a microphone that sits just above the keyboard, on the side you drag it to.
 * While you speak it turns red and counts the seconds; while Quoth writes it says so. It's an accessibility overlay
 * (TYPE_ACCESSIBILITY_OVERLAY), so it needs no "draw over other apps" permission, and it never takes the keyboard's focus.
 */
@SuppressLint("ClickableViewAccessibility")
class EarshotBubble(
    private val context: Context,
    private val onTap: () -> Unit,
    private val onMenu: () -> Unit,
    /** The user dragged the bubble: the side it snapped to and its height above the keyboard (dp). */
    private val onMoved: (left: Boolean, lift: Int) -> Unit,
) {
    enum class Look { IDLE, RECORDING, WORKING, NOTE }

    private val wm = context.getSystemService(WindowManager::class.java)
    private val density = context.resources.displayMetrics.density
    private fun dp(v: Int) = (v * density).toInt()
    private val main = Handler(Looper.getMainLooper())

    private val icon = ImageView(context).apply { setImageResource(R.drawable.ic_earshot_mic) }
    private val label = TextView(context).apply {
        textSize = 14f
        setTextColor(Ui.PAPER)
        maxLines = 1
        visibility = View.GONE
    }
    private val fill = GradientDrawable().apply { cornerRadius = dp(24).toFloat(); setColor(Ui.GREEN); setStroke(dp(2), Ui.PAPER) }
    private val pill = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER
        background = fill
        elevation = dp(4).toFloat()
        minimumWidth = dp(PILL)
        setPadding(dp(12), 0, dp(12), 0)
        addView(icon, LinearLayout.LayoutParams(dp(24), dp(24)))
        addView(label, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            marginStart = dp(8)
        })
        contentDescription = "Quoth Earshot: tap to dictate, hold for options"
    }
    private val root = FrameLayout(context).apply {
        val m = dp(MARGIN)
        setPadding(m, m, m, m)
        clipToPadding = false
        addView(pill, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, dp(PILL)))
    }
    private val params = WindowManager.LayoutParams(
        WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT,
        WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
        PixelFormat.TRANSLUCENT,
    ).apply { title = "Earshot"; gravity = Gravity.TOP or Gravity.END }

    private var attached = false
    private var menuView: View? = null
    private var pulse: ObjectAnimator? = null
    private var keyboardTop = 0
    var showingNote = false
        private set

    /** Puts the bubble above a keyboard whose top edge is at [keyboardTop] (screen pixels). */
    fun place(keyboardTop: Int, left: Boolean, lift: Int) {
        this.keyboardTop = keyboardTop
        if (dragging) return
        params.gravity = Gravity.TOP or if (left) Gravity.START else Gravity.END
        params.x = 0
        params.y = (keyboardTop - dp(lift) - dp(PILL + 2 * MARGIN)).coerceAtLeast(0)
        if (attached) wm.updateViewLayout(root, params)
    }

    fun show(look: Look, text: String? = null) {
        showingNote = look == Look.NOTE
        fill.setColor(when (look) { Look.RECORDING -> Ui.RED; Look.NOTE -> Ui.INK; else -> Ui.GREEN })
        label.text = text
        label.visibility = if (text == null) View.GONE else View.VISIBLE
        icon.visibility = if (look == Look.NOTE) View.GONE else View.VISIBLE
        pill.contentDescription = when (look) {
            Look.IDLE -> "Quoth Earshot: tap to dictate, hold for options"
            Look.RECORDING -> "Listening. Tap to finish"
            else -> text
        }
        if (look == Look.RECORDING || look == Look.WORKING) {
            if (pulse == null) pulse = ObjectAnimator.ofFloat(icon, View.ALPHA, 1f, 0.35f).apply {
                duration = 700; repeatMode = ValueAnimator.REVERSE; repeatCount = ValueAnimator.INFINITE; start()
            }
        } else {
            pulse?.cancel(); pulse = null; icon.alpha = 1f
        }
        if (!attached) {
            runCatching { wm.addView(root, params) }.onSuccess { attached = true }
        }
    }

    fun clearNote() { showingNote = false }

    fun hide() {
        closeMenu()
        showingNote = false
        if (attached) { runCatching { wm.removeView(root) }; attached = false }
    }

    fun remove() { hide(); pulse?.cancel() }

    fun buzz() { pill.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY) }

    // Tap, hold, or drag. A drag snaps to the nearer side and remembers the height above the keyboard.
    private var dragging = false
    private var downX = 0f
    private var downY = 0f
    private var startX = 0
    private var startY = 0
    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    private val hold = Runnable { held = true; buzz(); onMenu() }
    private var held = false

    init {
        pill.setOnTouchListener { _, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = e.rawX; downY = e.rawY; dragging = false; held = false
                    val loc = IntArray(2).also(root::getLocationOnScreen)
                    startX = loc[0]; startY = loc[1]
                    main.postDelayed(hold, ViewConfiguration.getLongPressTimeout().toLong())
                }
                MotionEvent.ACTION_MOVE -> {
                    if (!dragging && !held && (abs(e.rawX - downX) > slop || abs(e.rawY - downY) > slop)) {
                        dragging = true
                        main.removeCallbacks(hold)
                        closeMenu()
                        params.gravity = Gravity.TOP or Gravity.START
                    }
                    if (dragging) {
                        params.x = (startX + (e.rawX - downX)).toInt()
                        params.y = (startY + (e.rawY - downY)).toInt().coerceIn(0, maxOf(0, keyboardTop - dp(PILL + 2 * MARGIN)))
                        if (attached) wm.updateViewLayout(root, params)
                    }
                }
                MotionEvent.ACTION_UP -> {
                    main.removeCallbacks(hold)
                    if (dragging) {
                        dragging = false
                        val width = context.resources.displayMetrics.widthPixels
                        val left = e.rawX < width / 2
                        val lift = ((keyboardTop - params.y - dp(PILL + 2 * MARGIN)) / density).toInt().coerceAtLeast(0)
                        onMoved(left, lift)
                        place(keyboardTop, left, lift)
                    } else if (!held) {
                        pill.performClick()
                        onTap()
                    }
                }
                MotionEvent.ACTION_CANCEL -> { main.removeCallbacks(hold); dragging = false }
            }
            true
        }
    }

    /** A small card of choices above the bubble; a tap outside closes it. */
    fun menu(options: List<Pair<String, () -> Unit>>, closed: () -> Unit) {
        closeMenu()
        val card = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply { cornerRadius = dp(14).toFloat(); setColor(Ui.CARD); setStroke(dp(1), Ui.KEY) }
            elevation = dp(6).toFloat()
            setPadding(dp(6), dp(6), dp(6), dp(6))
            for ((text, action) in options) addView(TextView(context).apply {
                this.text = text
                textSize = 15f
                setTextColor(Ui.INK)
                setPadding(dp(14), dp(12), dp(14), dp(12))
                isClickable = true
                setOnClickListener { closeMenu(); action(); closed() }
            })
        }
        val frame = FrameLayout(context).apply {
            setPadding(dp(8), dp(8), dp(8), dp(8))
            addView(card)
            setOnTouchListener { _, e ->
                if (e.actionMasked == MotionEvent.ACTION_OUTSIDE) { closeMenu(); closed() }
                false
            }
        }
        val p = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            title = "Earshot menu"
            gravity = Gravity.BOTTOM or (params.gravity and Gravity.HORIZONTAL_GRAVITY_MASK)
            val screen = context.resources.displayMetrics.heightPixels
            y = (screen - params.y).coerceAtLeast(0)
        }
        runCatching { wm.addView(frame, p) }.onSuccess { menuView = frame }
    }

    private fun closeMenu() {
        menuView?.let { runCatching { wm.removeView(it) } }
        menuView = null
    }

    companion object {
        /** The pill's height (and the idle circle's size), and the clear space around it for its shadow, in dp. */
        const val PILL = 48
        const val MARGIN = 6
    }
}
