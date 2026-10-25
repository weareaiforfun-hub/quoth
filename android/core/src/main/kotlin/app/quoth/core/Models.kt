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
