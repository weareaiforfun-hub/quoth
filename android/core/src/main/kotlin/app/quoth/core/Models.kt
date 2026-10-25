package app.quoth.core

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest

/** A downloadable model file, pinned by size and SHA-256 (the same entries as the Mac's ModelCatalog). */
data class ModelFile(val file: String, val name: String, val bytes: Long, val sha256: String, val url: String)

object ModelCatalog {
    private const val WHISPER = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"

    val whisperBase = ModelFile("ggml-base.bin", "Whisper Base", 147_951_465,
        "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe", WHISPER + "ggml-base.bin")
    val whisperSmall = ModelFile("ggml-small.bin", "Whisper Small", 487_601_967,
        "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b", WHISPER + "ggml-small.bin")

    val speech = listOf(whisperBase, whisperSmall)

    private fun gguf(repo: String, file: String) = "https://huggingface.co/$repo/resolve/main/$file"

    // Cleanup models for llama.cpp (Q4_K_M, all Apache-2.0). Scores are the golden evals
    // (Evals/cleanup-golden.jsonl, 66 cases: exact / same words / hard failures), run on the Mac's llama-server.
    /** 52 / 61 / 0: the best small model tested, better than the Mac's Lite model. */
    val qwen35_4b = ModelFile("Qwen_Qwen3.5-4B-Q4_K_M.gguf", "Qwen 3.5 4B", 3_013_027_808,
        "13c16f426047e2de38cd075bdade4a7bcbc8c774384876f677740cda65f8a983", gguf("bartowski/Qwen_Qwen3.5-4B-GGUF", "Qwen_Qwen3.5-4B-Q4_K_M.gguf"))
    /** 49 / 59 / 0: the Mac's Lite model. */
    val qwen3_4b = ModelFile("Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf", "Qwen 3 4B", 2_497_280_736,
        "2fde00ce69dd4899c70d020845e2638353015bba0fdf161b3eb965f2bca4464e",
        gguf("bartowski/Qwen_Qwen3-4B-Instruct-2507-GGUF", "Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf"))
    /** 29 / 54 / 1. */
    val qwen3_1_7b = ModelFile("Qwen_Qwen3-1.7B-Q4_K_M.gguf", "Qwen 3 1.7B", 1_282_439_584,
        "72c5c3cb38fa32d5256e2fe30d03e7a64c6c79e668ad84057e3bd66e250b24fb", gguf("bartowski/Qwen_Qwen3-1.7B-GGUF", "Qwen_Qwen3-1.7B-Q4_K_M.gguf"))
    /** 25 / 47 / 0. */
    val qwen35_2b = ModelFile("Qwen_Qwen3.5-2B-Q4_K_M.gguf", "Qwen 3.5 2B", 1_396_198_496,
        "57a1085840f497d764a7fc5d346922dbde961efb54cc792ea81d694fd846a1d8", gguf("bartowski/Qwen_Qwen3.5-2B-GGUF", "Qwen_Qwen3.5-2B-Q4_K_M.gguf"))

    val cleanup = listOf(qwen35_4b, qwen3_4b, qwen3_1_7b, qwen35_2b)
}

/**
 * Downloads a model to `dir/<file>` with resume: bytes so far live in `<file>.part`, and a restart
 * continues them with an HTTP Range request. The file only appears under its real name once its size
 * and SHA-256 match, so a half-written or corrupt model is never loaded.
 */
class ModelDownloader(private val dir: File, private val retries: Int = 3) {

    fun isInstalled(model: ModelFile): Boolean = File(dir, model.file).length() == model.bytes

    /** Blocks until the model is installed. [progress] gets (bytes so far, total). Throws on failure. */
    fun download(model: ModelFile, progress: (Long, Long) -> Unit = { _, _ -> }) {
        val target = File(dir, model.file)
        if (target.length() == model.bytes) return
        dir.mkdirs()
        if (dir.usableSpace < model.bytes - partFile(model).length()) throw IOException("Not enough free space for ${model.name}")

        var lastError: IOException? = null
        repeat(retries) {
            try {
                fetch(model, progress)
                verifyAndInstall(model)
                return
            } catch (e: ChecksumException) {
                throw e
            } catch (e: IOException) {
                lastError = e
            }
        }
        throw lastError ?: IOException("Download failed")
    }

    private fun partFile(model: ModelFile) = File(dir, model.file + ".part")

    private fun fetch(model: ModelFile, progress: (Long, Long) -> Unit) {
        val part = partFile(model)
        var have = part.length()
        if (have >= model.bytes) return

        val conn = URI(model.url).toURL().openConnection() as HttpURLConnection
        conn.instanceFollowRedirects = true
        conn.connectTimeout = 15_000
        conn.readTimeout = 30_000
        if (have > 0) conn.setRequestProperty("Range", "bytes=$have-")
        try {
            when (conn.responseCode) {
                HttpURLConnection.HTTP_PARTIAL -> {}
                HttpURLConnection.HTTP_OK -> have = 0 // server ignored the range: start over
                else -> throw IOException("HTTP ${conn.responseCode} for ${model.url}")
            }
            RandomAccessFile(part, "rw").use { out ->
                out.setLength(have)
                out.seek(have)
                conn.inputStream.use { input ->
                    val buf = ByteArray(1 shl 16)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        have += n
                        progress(have, model.bytes)
                    }
                }
            }
        } finally {
            conn.disconnect()
        }
        if (have < model.bytes) throw IOException("Connection ended at $have of ${model.bytes} bytes")
    }

    private fun verifyAndInstall(model: ModelFile) {
        val part = partFile(model)
        val digest = MessageDigest.getInstance("SHA-256")
        part.inputStream().use { input ->
            val buf = ByteArray(1 shl 16)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                digest.update(buf, 0, n)
            }
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        if (part.length() != model.bytes || actual != model.sha256) {
            part.delete()
            throw ChecksumException("${model.name} failed its checksum; the download was discarded")
        }
        if (!part.renameTo(File(dir, model.file))) throw IOException("Couldn't install ${model.file}")
    }
}

class ChecksumException(message: String) : IOException(message)
