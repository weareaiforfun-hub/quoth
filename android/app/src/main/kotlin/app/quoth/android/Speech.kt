package app.quoth.android

import android.content.Context
import android.util.Log
import app.quoth.core.CleanupCase
import app.quoth.core.CleanupContext
import app.quoth.core.CleanupLevel
import app.quoth.core.DictationOutcome
import app.quoth.core.DictationPipeline
import app.quoth.core.HistoryEntry
import app.quoth.core.ModelBench
import app.quoth.core.ModelCatalog
import app.quoth.core.ModelDownloader
import app.quoth.core.ModelFile
import app.quoth.core.Transcriber
import app.quoth.core.TranscriptionResult
import java.io.File
import java.util.concurrent.Executors

/**
 * App-wide dictation state: the models on disk, the loaded engines, and one background thread
 * that runs the pipeline (whisper.cpp, then the llama.cpp cleanup model when one is chosen and downloaded).
 */
object Speech {
    val model = ModelCatalog.whisperBase
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "quoth-speech") }
    private var whisper: WhisperEngine? = null
    private var llama: LlamaEngine? = null
    private var llamaFile: String? = null

    /** Base cleanup timeout (s) and the extra allowed per word; on timeout the raw text is used. Measured on a Pixel 9a. */
    private const val LLM_TIMEOUT = 10.0
    private const val LLM_SECONDS_PER_WORD = 0.25

    fun modelDir(context: Context) = File(context.filesDir, "models")
    fun downloader(context: Context) = ModelDownloader(modelDir(context))
    fun isModelInstalled(context: Context) = downloader(context).isInstalled(model)
    fun isInstalled(context: Context, m: ModelFile) = downloader(context).isInstalled(m)

    /**
     * The cleanup model chosen in Settings (Qwen 3.5 2B by default), or null for none. Debug builds can
     * test another catalog model by writing its file name to files/debug-cleanup-model.
     */
    fun cleanupModel(context: Context): ModelFile? {
        if (BuildConfig.DEBUG) {
            val name = File(context.filesDir, "debug-cleanup-model").takeIf { it.exists() }?.readText()?.trim()
            ModelCatalog.cleanup.firstOrNull { it.file == name }?.let { return it }
        }
        return Store.settings(context).cleanup
    }

    fun isCleanupInstalled(context: Context) = cleanupModel(context)?.let { isInstalled(context, it) } ?: false

    /** Debug builds only: if this WAV exists, it's transcribed instead of the microphone (for automated tests). */
    fun debugInput(context: Context): File? =
        if (BuildConfig.DEBUG) File(context.filesDir, "debug-input.wav").takeIf { it.exists() } else null

    /**
     * Runs the whole pipeline on the background thread and delivers the outcome (or null on failure), off the
     * main thread. [target] says where the text goes; the user's settings and personal data are added here.
     * [keepHistory] is false where the app asked keyboards not to remember anything (incognito).
     */
    fun dictate(context: Context, samples: FloatArray, target: CleanupContext, keepHistory: Boolean = true,
                done: (DictationOutcome?) -> Unit) {
        val app = context.applicationContext
        worker.execute {
            val result = runCatching {
                val settings = Store.settings(app)
                val personal = Store.personal(app)
                val pipeline = pipeline(app, settings.languages)
                val level = if (pipeline.cleaner != null) settings.level else CleanupLevel.NONE
                val ctx = target.copy(
                    variant = settings.variant,
                    vocabulary = personal.vocabulary(),
                    textBeforeCursor = target.textBeforeCursor.takeIf { settings.contextAwareness },
                    textAfterCursor = target.textAfterCursor.takeIf { settings.contextAwareness },
                )
                // A single pinned language goes straight to whisper; a set is handled by the transcriber below.
                val pinned = settings.languages.takeIf { it.size == 1 } ?: emptyList()
                pipeline.run(samples, level, pinned, ctx, personal).also { o ->
                    Log.i(TAG, "timing asr=${o.asrMs}ms llm=${o.llmMs}ms audio=${samples.size * 1000L / Recorder.RATE}ms" +
                        " level=${level.raw} lang=${o.language}" + (o.fallbackReason?.let { r -> " fallback=$r" } ?: ""))
                    record(app, o, target.bundleID, keepHistory)
                }
            }
            result.exceptionOrNull()?.let { Log.e(TAG, "dictation failed", it) }
            done(result.getOrNull())
        }
    }

    /** Saves the dictation to History (per the retention setting) and counts dictionary uses. */
    private fun record(app: Context, o: DictationOutcome, pkg: String?, keepHistory: Boolean) {
        if (o.final.isBlank()) return
        Store.updatePersonal(app) { it.countingUses(o.firedEntries) }
        if (!keepHistory) return
        val label = pkg?.let { runCatching { app.packageManager.run { getApplicationLabel(getApplicationInfo(it, 0)).toString() } }.getOrNull() }
        Store.history(app).add(HistoryEntry(createdAt = System.currentTimeMillis(), raw = o.raw, final = o.final.trim(), app = pkg,
            appName = label, asrMs = o.asrMs, llmMs = o.llmMs, fallbackReason = o.fallbackReason), Store.settings(app).retention)
    }

    /** Loads the engines in the background so the first dictation doesn't wait, and primes the cleanup prompt cache. */
    fun warmUp(context: Context) {
        val app = context.applicationContext
        warming = true
        worker.execute {
            try {
                if (isModelInstalled(app)) {
                    runCatching { pipeline(app, emptyList()).cleaner?.clean("hello", CleanupLevel.LIGHT, CleanupContext()) }
                }
            } finally {
                warming = false
            }
        }
    }

    /** True while the engines load after a (re)start; a dictation then waits for them. */
    @Volatile var warming = false
        private set

    /** Unloads a cleanup model (before it's deleted, or when another is chosen) and waits until that's done. */
    fun release(file: String) {
        worker.submit {
            if (llamaFile == file) { llama?.close(); llama = null; llamaFile = null }
        }.get()
    }

    /** Must run on the worker thread. Loads whatever models are chosen and installed, and drops a cleanup model that was swapped. */
    private fun pipeline(context: Context, languages: List<String>): DictationPipeline {
        val w = whisper ?: WhisperEngine.load(File(modelDir(context), model.file))?.also { whisper = it }
            ?: error("speech model failed to load")
        val cm = cleanupModel(context)?.takeIf { isInstalled(context, it) }
        if (llamaFile != cm?.file) { llama?.close(); llama = null; llamaFile = null }
        if (llama == null && cm != null) {
            val t0 = System.currentTimeMillis()
            // Debug builds: files/debug-no-repack keeps the weights memory-mapped (for measuring RAM use against speed).
            val repack = !(BuildConfig.DEBUG && File(context.filesDir, "debug-no-repack").exists())
            val cache = File(context.cacheDir, "prompt-${cm.file.removeSuffix(".gguf")}.bin")
            llama = LlamaEngine.load(File(modelDir(context), cm.file), cache, repack = repack)
            llamaFile = cm.file
            Log.i(TAG, "cleanup model ${cm.name} loaded in ${System.currentTimeMillis() - t0}ms: ${llama != null}")
        }
        val asr = Transcriber { samples, language, prompt ->
            val text = w.transcribe(samples, language ?: "auto", prompt ?: "")
            val heard = w.lastLanguage
            if (language == null && languages.size > 1 && heard != null && heard !in languages) {
                // Detected a language outside the user's set: transcribe again in their first language.
                TranscriptionResult(w.transcribe(samples, languages[0], prompt ?: ""), languages[0])
            } else {
                TranscriptionResult(text, heard)
            }
        }
        return DictationPipeline(asr, llama, LLM_TIMEOUT, LLM_SECONDS_PER_WORD)
    }

    /** Debug builds only: scores the cleanup model on files/cleanup-golden.jsonl, logging the same lines as `:core:eval`. */
    fun runEvals(context: Context) {
        val app = context.applicationContext
        val file = File(app.filesDir, "cleanup-golden.jsonl")
        if (!BuildConfig.DEBUG || !file.exists()) return
        worker.execute {
            val cleaner = pipeline(app, emptyList()).cleaner ?: run { Log.i(TAG, "eval: no cleanup model"); return@execute }
            val name = cleanupModel(app)?.name ?: "?"
            // Fill the prompt cache first, without a timeout, as the keyboard's warm-up does.
            val t0 = System.currentTimeMillis()
            runCatching { cleaner.clean("hello", CleanupLevel.LIGHT, CleanupContext()) }
            Log.i(TAG, "eval warm-up ${System.currentTimeMillis() - t0}ms")
            val cases = CleanupCase.load(file.readText())
            val out = File(app.filesDir, "eval-results.log").apply { writeText("") }
            val results = ModelBench.runCleanup(cleaner, name, cases, timeout = 120.0) { r ->
                val line = "eval ${r.verdict.symbol} ${r.caseID} ${r.ms}ms ${r.verdict.problems.joinToString(", ")} | ${r.output.replace("\n", "⏎")}"
                Log.i(TAG, line)
                out.appendText(line + "\n")
            }
            val s = ModelBench.summarize(results, name)
            val summary = "eval done $name: exact ${s.exact}/${s.cases}, same words ${s.sameWords}/${s.cases}, " +
                "hard fails ${s.serious}, p50 ${s.p50ms}ms, p90 ${s.p90ms}ms, max ${results.maxOf { it.ms }}ms"
            out.appendText(summary + "\n")
            Log.i(TAG, summary)
        }
    }

    const val TAG = "Quoth"
}
