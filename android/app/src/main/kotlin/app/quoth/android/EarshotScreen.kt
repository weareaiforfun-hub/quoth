package app.quoth.android

import android.content.Intent
import android.graphics.Typeface
import android.provider.Settings
import android.widget.LinearLayout
import android.widget.Toast

/**
 * Earshot's setup and settings. Before anything is switched on it shows the disclosure Google Play requires for apps
 * that use the Accessibility API without being accessibility tools: what Quoth reads, why, and that it stays on the
 * phone. Only "Agree and turn on" leads to Android's Accessibility settings.
 */
class EarshotScreen : Screen() {
    override val heading = "Earshot"
    override val subtitle = "Dictate with any keyboard: a small Quoth microphone floats next to the text box you're typing in."

    override fun onResume() {
        super.onResume()
        render() // back from Android's Accessibility settings
    }

    override fun build() {
        val s = Store.settings(this)
        val serviceOn = Earshot.serviceOn(this)
        when {
            !s.earshot -> disclosure()
            !serviceOn -> oneMoreStep()
            else -> turnedOn(s.earshotHiddenApps)
        }
    }

    /** The prominent disclosure, shown every time before Earshot is switched on. */
    private fun disclosure() {
        section("How it works")
        add(Ui.card(this).apply {
            addView(Ui.text(context, "Whenever a keyboard is open, a green microphone appears just above it. Tap it, speak, " +
                "and tap again: Quoth writes your words into the box, cleaned up the same way as on the Quoth keyboard. " +
                "Drag it to move it; hold it to hide it for an hour or in one app.", 15f))
        })

        section("Before you turn it on")
        add(Ui.card(this).apply {
            addView(Ui.text(context, "Quoth uses Android's Accessibility service for Earshot", 16f, bold = true))
            addView(Ui.text(context, "Quoth isn't an accessibility tool. Android only lets an app see and fill text boxes in other " +
                "apps through this setting, so Earshot needs it.", 14f, Ui.MUTED), Ui.gap(context, 4))
            for ((title, body) in listOf(
                "What Quoth reads" to "Which text box has the cursor, what kind of box it is (for example a search box), which app " +
                    "it's in, and whether a keyboard is open. When you dictate, also the box's text near the cursor, and the box's " +
                    "text again after inserting, to learn names you correct.",
                "Why" to "To show the microphone only while you're typing, to fit your words into what's already written, to " +
                    "match the app's writing style, and to put the text in.",
                "What it never does" to "It never reads or fills password boxes. It looks through the rest of the screen only to " +
                    "find the box with the cursor, and keeps none of it. It doesn't record your typing or act on its own: it " +
                    "only types when you tap the microphone.",
                "Where it goes" to "Nowhere. Everything stays on this phone and nothing is sent to the developer or anyone else. " +
                    "Your dictations are kept in History on the phone, as with the keyboard (Settings → History). Android doesn't " +
                    "tell Earshot about incognito tabs, so those dictations go to History too, unless History is set to Never store.",
            )) {
                addView(Ui.text(context, title, 15f, bold = true), Ui.gap(context, 12))
                addView(Ui.text(context, body, 14f), Ui.gap(context, 2))
            }
            addView(Ui.text(context, "You can turn Earshot off any time here or in Android's Accessibility settings.", 14f, Ui.MUTED),
                Ui.gap(context, 12))
        })
        add(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(Ui.button(context, "Not now") { if (Earshot.serviceOn(context)) Earshot.turnOff(context); finish() }.apply { contentDescription = "Not now" },
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(Ui.button(context, "Agree and turn on", primary = true) { agree() }.apply { contentDescription = "Agree and turn on" },
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1.4f).apply { marginStart = dp(10) })
        }, 16)
    }

    private fun agree() {
        Store.updateSettings(this) { it.copy(earshot = true, earshotSnoozedUntil = 0) }
        if (!Earshot.serviceOn(this)) openAccessibilitySettings() else render()
    }

    private fun openAccessibilitySettings() {
        startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        Toast.makeText(this, "Find Quoth Earshot (under Downloaded apps), switch it on, then come back", Toast.LENGTH_LONG).show()
    }

    private fun oneMoreStep() {
        section("One more step")
        add(Ui.card(this).apply {
            addView(Ui.text(context, "Switch on Quoth Earshot in Android's Accessibility settings.", 15f))
            for (line in listOf(
                "1. Tap Open settings.",
                "2. Tap Quoth Earshot (it may be under Downloaded apps or Installed apps).",
                "3. Switch on Use Quoth Earshot, then tap Allow.",
                "4. Come back here.",
            )) addView(Ui.text(context, line, 14f), Ui.gap(context, 4))
            addView(Ui.text(context, "Installed Quoth from a file rather than Google Play? On Android 13 and later, Android first " +
                "greys the switch out. Open Settings → Apps → Quoth, tap ⋮ (top right), Allow restricted settings, then try again.",
                13f, Ui.MUTED), Ui.gap(context, 10))
            addView(Ui.button(context, "Open settings", primary = true) { openAccessibilitySettings() }, Ui.gap(context, 12))
        })
        add(Ui.button(this, "Cancel") { Earshot.turnOff(this); render() }, 10)
    }

    private fun turnedOn(hidden: List<String>) {
        add(Ui.card(this).apply {
            addView(Ui.text(context, "✓ Earshot is on", 17f, Ui.GREEN))
            addView(Ui.text(context, "Open any app and tap a text box: the microphone appears above your keyboard. " +
                "It stays out of password boxes and hides while the Quoth keyboard is up.", 14f, Ui.MUTED), Ui.gap(context, 2))
        })
        val snoozed = Store.settings(this).earshotSnoozedUntil
        if (snoozed > System.currentTimeMillis()) {
            add(Ui.card(this).apply {
                addView(Ui.text(context, "Hidden until ${android.text.format.DateFormat.getTimeFormat(context).format(java.util.Date(snoozed))}", 15f))
                addView(Ui.button(context, "Show it again") {
                    Store.updateSettings(context) { it.copy(earshotSnoozedUntil = 0) }; render()
                }, Ui.gap(context, 8))
            })
        }

        section("Hidden in these apps")
        if (hidden.isEmpty()) {
            add(Ui.text(this, "None. To hide Earshot in an app, hold the microphone there and choose Not in (the app).", 14f, Ui.MUTED))
        }
        for (app in hidden) {
            add(Ui.card(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = android.view.Gravity.CENTER_VERTICAL
                val name = Apps.label(context, app)
                addView(Ui.text(context, name), LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
                addView(Ui.button(context, "Show here") {
                    Store.updateSettings(context) { it.copy(earshotHiddenApps = it.earshotHiddenApps - app) }; render()
                })
            })
        }

        section("Privacy")
        add(Ui.text(this, "Earshot reads only the text box that has the cursor, never password boxes, and nothing leaves this phone. " +
            "Android doesn't tell Earshot about incognito tabs the way it tells keyboards, so dictations from Earshot go to " +
            "History unless you set History to Never store (Settings → History).", 14f, Ui.MUTED))
        add(Ui.button(this, "Turn Earshot off") { Earshot.turnOff(this); render() }.apply { setTypeface(typeface, Typeface.BOLD) }, 16)
    }
}
