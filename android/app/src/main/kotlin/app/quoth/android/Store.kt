package app.quoth.android

import android.content.Context
import android.os.Handler
import android.os.Looper
import app.quoth.core.AppSettings
import app.quoth.core.HistoryStore
import app.quoth.core.JsonFile
import app.quoth.core.ModelFile
import app.quoth.core.PersonalData
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.concurrent.thread

/** The app's saved state, shared by the keyboard and the app's screens (they run in one process). */
object Store {
    private var dir: File? = null
    private lateinit var settingsFile: JsonFile<AppSettings>
    private lateinit var personalFile: JsonFile<PersonalData>
    private lateinit var historyStore: HistoryStore

    @Synchronized
    private fun open(context: Context) {
        if (dir != null) return
        val d = context.applicationContext.filesDir
        settingsFile = JsonFile(File(d, "settings.json"), AppSettings.serializer()) { AppSettings() }
        // The same JSON shape as the Mac's personal.json.
        personalFile = JsonFile(File(d, "personal.json"), PersonalData.serializer()) { PersonalData() }
        historyStore = HistoryStore(File(d, "history.json"))
        dir = d
    }

    fun settings(context: Context): AppSettings { open(context); return settingsFile.value }
    fun updateSettings(context: Context, change: (AppSettings) -> AppSettings): AppSettings {
        open(context)
        return settingsFile.update(change).also { historyStore.purge(it.retention) }
    }

    fun personal(context: Context): PersonalData { open(context); return personalFile.value }
    fun updatePersonal(context: Context, change: (PersonalData) -> PersonalData): PersonalData {
        open(context)
        return personalFile.update(change)
    }

    fun history(context: Context): HistoryStore { open(context); return historyStore }
}

/**
 * Model downloads that outlive the screen that started them. Progress and results are reported to
 * listeners on the main thread. The download itself resumes and checks the SHA-256 (ModelDownloader).
 */
object Downloads {
    class State(val have: Long, val total: Long, val error: String? = null) {
        val running get() = error == null
    }

    private val states = ConcurrentHashMap<String, State>()
    private val listeners = CopyOnWriteArrayList<() -> Unit>()
    private val main = Handler(Looper.getMainLooper())

    /** The download state of [model], or null when none is running or failed. */
    fun state(model: ModelFile): State? = states[model.file]

    fun start(context: Context, model: ModelFile) {
        if (states[model.file]?.running == true) return
        val app = context.applicationContext
        states[model.file] = State(0, model.bytes)
        notifyListeners()
        thread(name = "quoth-download") {
            var lastPermille = -1L
            val error = runCatching {
                Speech.downloader(app).download(model) { have, total ->
                    val permille = have * 1000 / total
                    if (permille != lastPermille) {
                        lastPermille = permille
                        states[model.file] = State(have, total)
                        notifyListeners()
                    }
                }
            }.exceptionOrNull()
            if (error == null) {
                states.remove(model.file)
                Speech.warmUp(app)
            } else {
                states[model.file] = State(0, model.bytes, error.message ?: "Download failed")
            }
            notifyListeners()
        }
    }

    /** Adds a listener; returns the function that removes it. */
    fun listen(listener: () -> Unit): () -> Unit {
        listeners += listener
        return { listeners -= listener }
    }

    private fun notifyListeners() = main.post { listeners.forEach { it() } }
}
