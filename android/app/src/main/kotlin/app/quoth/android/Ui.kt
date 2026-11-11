package app.quoth.android

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.TextView

/** Quoth's look on Android: paper, ink and one green, the same palette as the keyboard. */
object Ui {
    val PAPER = Color.parseColor("#F4EFE6")
    val CARD = Color.parseColor("#FBF8F2")
    val KEY = Color.parseColor("#E6DFD2")
    val INK = Color.parseColor("#1F1E1C")
    val MUTED = Color.parseColor("#6B675F")
    val GREEN = Color.parseColor("#2F5D45")
    val RED = Color.parseColor("#B3412E")

    fun Context.dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    fun text(context: Context, s: CharSequence, size: Float = 16f, color: Int = INK, bold: Boolean = false) = TextView(context).apply {
        text = s
        textSize = size
        setTextColor(color)
        if (bold) typeface = Typeface.DEFAULT_BOLD
    }

    fun button(context: Context, label: String, primary: Boolean = false, onClick: () -> Unit) = Button(context).apply {
        text = label
        isAllCaps = false
        textSize = 15f
        setTextColor(if (primary) Color.WHITE else INK)
        background = GradientDrawable().apply { cornerRadius = context.dp(10).toFloat(); setColor(if (primary) GREEN else KEY) }
        setPadding(context.dp(16), 0, context.dp(16), 0)
        minimumHeight = context.dp(44)
        minHeight = context.dp(44)
        setOnClickListener { onClick() }
    }

    fun field(context: Context, hint: String, multiLine: Boolean = false) = EditText(context).apply {
        this.hint = hint
        textSize = 16f
        setTextColor(INK)
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES or
            (if (multiLine) InputType.TYPE_TEXT_FLAG_MULTI_LINE else 0)
        if (multiLine) { minLines = 2; gravity = Gravity.TOP }
    }

    /** A rounded card that groups related rows. */
    fun card(context: Context) = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        background = GradientDrawable().apply { cornerRadius = context.dp(14).toFloat(); setColor(CARD) }
        val p = context.dp(14)
        setPadding(p, p, p, p)
    }

    /** One choice out of several, each with an optional explanation under it. */
    fun choices(context: Context, options: List<Pair<String, String?>>, selected: Int, onChoose: (Int) -> Unit) =
        RadioGroup(context).apply {
            options.forEachIndexed { i, (label, detail) ->
                addView(RadioButton(context).apply {
                    id = View.generateViewId()
                    text = if (detail == null) label else "$label\n$detail"
                    textSize = 15f
                    setTextColor(INK)
                    isChecked = i == selected
                    setPadding(paddingLeft, context.dp(6), paddingRight, context.dp(6))
                    setOnClickListener { onChoose(i) }
                })
            }
        }

    fun wide() = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)

    /** Empties a text field and tells the keyboard, so it doesn't carry a half-typed word over. */
    fun EditText.clear() {
        setText("")
        context.getSystemService(android.view.inputmethod.InputMethodManager::class.java).restartInput(this)
    }

    /** Adds a view that may still sit in a previous render's layout (text fields keep what's typed across renders). */
    fun ViewGroup.adopt(child: View, params: ViewGroup.LayoutParams = wide()) {
        (child.parent as? ViewGroup)?.removeView(child)
        addView(child, params)
    }

    fun gap(context: Context, top: Int) = wide().apply { topMargin = context.dp(top) }

    /** Pads a full-screen view clear of the status bar, the navigation bar and the on-screen keyboard. */
    fun fitSystemBars(view: View, base: Int) {
        // Android 10 draws below the bars and may never call the listener, so start with the plain margin.
        view.setPadding(base, base, base, base)
        view.setOnApplyWindowInsetsListener { v, insets ->
            if (android.os.Build.VERSION.SDK_INT >= 30) {
                val bars = insets.getInsets(WindowInsets.Type.systemBars())
                val ime = insets.getInsets(WindowInsets.Type.ime())
                v.setPadding(base + bars.left, base + bars.top, base + bars.right, base + maxOf(bars.bottom, ime.bottom))
            } else {
                // Android 10: no inset types yet (and adjustResize already makes room for the keyboard).
                @Suppress("DEPRECATION")
                v.setPadding(base + insets.systemWindowInsetLeft, base + insets.systemWindowInsetTop,
                    base + insets.systemWindowInsetRight, base + insets.systemWindowInsetBottom)
            }
            insets
        }
    }
}

/**
 * One of the app's screens: a header with a back button, then content that [render] rebuilds
 * whenever the data changes (the lists are short, so rebuilding is simpler than diffing).
 */
abstract class Screen : Activity() {
    protected abstract val heading: String
    protected abstract val subtitle: String
    protected lateinit var content: LinearLayout

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pad = dp(20)
        content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val page = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(Ui.button(this@Screen, "← Back") { finish() }.apply {
                background = null
                setPadding(0, 0, 0, 0)
                contentDescription = "Back"
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(Ui.text(this@Screen, heading, 28f))
            addView(Ui.text(this@Screen, subtitle, 15f, Ui.MUTED).apply { setPadding(0, dp(4), 0, dp(16)) })
            addView(content, Ui.wide())
        }
        val scroll = ScrollView(this).apply {
            setBackgroundColor(Ui.PAPER)
            isFillViewport = true
            addView(page)
        }
        Ui.fitSystemBars(scroll, pad)
        setContentView(scroll)
        render()
    }

    protected fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    /** Rebuilds [content] from the current data. */
    protected fun render() {
        content.removeAllViews()
        build()
    }

    protected abstract fun build()

    protected fun section(title: String) {
        content.addView(Ui.text(this, title, 13f, Ui.MUTED, bold = true).apply {
            text = title.uppercase()
            letterSpacing = 0.06f
        }, Ui.gap(this, 18))
    }

    protected fun add(view: View, top: Int = 8) = content.addView(view, Ui.gap(this, top))
}
