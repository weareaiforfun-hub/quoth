package app.quoth.android

import android.content.Context
import android.util.Log
import app.quoth.core.CleanupCase
import app.quoth.core.CleanupContext
import app.quoth.core.CleanupLevel
import app.quoth.core.DictationOutcome
import app.quoth.core.DictationPipeline
import app.quoth.core.ModelBench
import app.quoth.core.ModelCatalog
import app.quoth.core.ModelDownloader
import app.quoth.core.ModelFile
import app.quoth.core.PersonalData
import app.quoth.core.Transcriber
import app.quoth.core.TranscriptionResult
import java.io.File
import java.util.concurrent.Executors

/**
 * App-wide dictation state: the models on disk, the loaded engines, and one background thread
 * that runs the pipeline (whisper.cpp, then the llama.cpp cleanup model when it's downloaded).
 */
object Speech {
    val model = ModelCatalog.whisperBase
    val defaultCleanupModel = ModelCatalog.qwen35_4b
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

    /** The cleanup model in use. Debug builds can pick another catalog model by writing its file name to files/debug-cleanup-model. */
    fun cleanupModel(context: Context): ModelFile {
        if (BuildConfig.DEBUG) {
            val name = File(context.filesDir, "debug-cleanup-model").takeIf { it.exists() }?.readText()?.trim()
            ModelCatalog.cleanup.firstOrNull { it.file == name }?.let { return it }
        }
        return defaultCleanupModel
    }

    fun isCleanupInstalled(context: Context) = downloader(context).isInstalled(cleanupModel(context))

    /** Debug builds only: if this WAV exists, it's transcribed instead of the microphone (for automated tests). */
    fun debugInput(context: Context): File? =
        if (BuildConfig.DEBUG) File(context.filesDir, "debug-input.wav").takeIf { it.exists() } else null

    /** Runs the whole pipeline on the background thread and delivers the outcome (or null on failure), off the main thread. */
    fun dictate(context: Context, samples: FloatArray, target: CleanupContext, done: (DictationOutcome?) -> Unit) {
        val appContext = context.applicationContext
        worker.execute {
            val result = runCatching {
                val pipeline = pipeline(appContext)
                val level = if (pipeline.cleaner != null) CleanupLevel.LIGHT else CleanupLevel.NONE
                pipeline.run(samples, level, emptyList(), target, PersonalData()).also {
                    Log.i(TAG, "timing asr=${it.asrMs}ms llm=${it.llmMs}ms audio=${samples.size * 1000L / Recorder.RATE}ms" +
                        " level=${level.raw}" + (it.fallbackReason?.let { r -> " fallback=$r" } ?: ""))
                }
            }
            result.exceptionOrNull()?.let { Log.e(TAG, "dictation failed", it) }
            done(result.getOrNull())
        }
    }

    /** Loads the engines in the background so the first dictation doesn't wait, and primes the cleanup prompt cache. */
    fun warmUp(context: Context) {
        val appContext = context.applicationContext
        worker.execute {
            if (!isModelInstalled(appContext)) return@execute
            runCatching { pipeline(appContext).cleaner?.clean("hello", CleanupLevel.LIGHT, CleanupContext()) }
        }
    }

    /** Must run on the worker thread. Loads whatever models are installed, and drops a cleanup model that was swapped. */
    private fun pipeline(context: Context): DictationPipeline {
        val w = whisper ?: WhisperEngine.load(File(modelDir(context), model.file))?.also { whisper = it }
            ?: error("speech model failed to load")
        val cm = cleanupModel(context)
        if (llamaFile != cm.file) { llama?.close(); llama = null; llamaFile = null }
        if (llama == null && downloader(context).isInstalled(cm)) {
            val t0 = System.currentTimeMillis()
            llama = LlamaEngine.load(File(modelDir(context), cm.file))
            llamaFile = cm.file
            Log.i(TAG, "cleanup model ${cm.name} loaded in ${System.currentTimeMillis() - t0}ms: ${llama != null}")
        }
        val asr = Transcriber { samples, language, prompt ->
            TranscriptionResult(w.transcribe(samples, language ?: "auto", prompt ?: ""))
        }
        return DictationPipeline(asr, llama, LLM_TIMEOUT, LLM_SECONDS_PER_WORD)
    }

    /** Debug builds only: scores the cleanup model on files/cleanup-golden.jsonl, logging the same lines as `:core:eval`. */
    fun runEvals(context: Context) {
        val appContext = context.applicationContext
        val file = File(appContext.filesDir, "cleanup-golden.jsonl")
        if (!BuildConfig.DEBUG || !file.exists()) return
        worker.execute {
            val cleaner = pipeline(appContext).cleaner ?: run { Log.i(TAG, "eval: no cleanup model"); return@execute }
            val name = cleanupModel(appContext).name
            val cases = CleanupCase.load(file.readText())
            val results = ModelBench.runCleanup(cleaner, name, cases, timeout = 120.0) { r ->
                Log.i(TAG, "eval ${r.verdict.symbol} ${r.caseID} ${r.ms}ms ${r.verdict.problems.joinToString(", ")} | ${r.output.replace("\n", "⏎")}")
            }
            val s = ModelBench.summarize(results, name)
            Log.i(TAG, "eval done $name: exact ${s.exact}/${s.cases}, same words ${s.sameWords}/${s.cases}, " +
                "hard fails ${s.serious}, p50 ${s.p50ms}ms, p90 ${s.p90ms}ms, max ${results.maxOf { it.ms }}ms")
        }
    }

    const val TAG = "Quoth"
}
