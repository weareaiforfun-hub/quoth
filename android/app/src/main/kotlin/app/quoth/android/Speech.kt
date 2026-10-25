package app.quoth.android

import android.content.Context
import android.os.SystemClock
import android.util.Log
import app.quoth.core.AudioLevel
import app.quoth.core.ModelCatalog
import app.quoth.core.ModelDownloader
import app.quoth.core.SpokenPunctuation
import app.quoth.core.TranscriptFilter
import java.io.File
import java.util.concurrent.Executors

/** App-wide speech state: the model on disk, the loaded engine, and one background thread for transcribing. */
object Speech {
    val model = ModelCatalog.whisperBase
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "quoth-speech") }
    private var engine: WhisperEngine? = null

    fun modelDir(context: Context) = File(context.filesDir, "models")
    fun downloader(context: Context) = ModelDownloader(modelDir(context))
    fun isModelInstalled(context: Context) = downloader(context).isInstalled(model)

    /** Debug builds only: if this WAV exists, it's transcribed instead of the microphone (for automated tests). */
    fun debugInput(context: Context): File? =
        if (BuildConfig.DEBUG) File(context.filesDir, "debug-input.wav").takeIf { it.exists() } else null

    /** Transcribes on the background thread and delivers the text (or null on failure) to [done], off the main thread. */
    fun transcribe(context: Context, samples: FloatArray, done: (String?) -> Unit) {
        val appContext = context.applicationContext
        worker.execute {
            val result = runCatching {
                val t0 = SystemClock.elapsedRealtime()
                val e = engine ?: WhisperEngine.load(File(modelDir(appContext), model.file))?.also { engine = it }
                    ?: error("model failed to load")
                val t1 = SystemClock.elapsedRealtime()
                // No cleanup model yet: drop whisper's tags and silence hallucinations, then apply spoken
                // punctuation, as the Mac does when its LLM is unavailable.
                val raw = TranscriptFilter.clean(e.transcribe(samples), likelySilence = AudioLevel.rms(samples) < AudioLevel.QUIET)
                val text = if (raw.isEmpty()) raw else SpokenPunctuation.apply(raw)
                val t2 = SystemClock.elapsedRealtime()
                Log.i(TAG, "timing load=${t1 - t0}ms transcribe=${t2 - t1}ms audio=${samples.size * 1000L / Recorder.RATE}ms")
                text
            }
            result.exceptionOrNull()?.let { Log.e(TAG, "transcription failed", it) }
            done(result.getOrNull())
        }
    }

    /** Loads the model in the background so the first dictation doesn't wait for it. */
    fun warmUp(context: Context) {
        val appContext = context.applicationContext
        if (!isModelInstalled(appContext)) return
        worker.execute {
            if (engine == null) engine = WhisperEngine.load(File(modelDir(appContext), model.file))
        }
    }

    const val TAG = "Quoth"
}
