package app.quoth.android

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

/** Records 16 kHz mono 16-bit audio from the microphone into memory, as whisper.cpp expects. */
class Recorder {
    private var record: AudioRecord? = null
    private var worker: Thread? = null
    private val chunks = ArrayList<ShortArray>()
    @Volatile private var running = false

    val isRecording get() = running

    /** Starts recording. Needs the RECORD_AUDIO permission. Returns false if the mic couldn't start. */
    @SuppressLint("MissingPermission")
    fun start(): Boolean {
        if (running) return true
        val minBuf = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val rec = runCatching {
            AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, maxOf(minBuf, RATE / 2 * 2))
        }.getOrNull() ?: return false
        if (rec.state != AudioRecord.STATE_INITIALIZED) { rec.release(); return false }
        synchronized(chunks) { chunks.clear() }
        rec.startRecording()
        record = rec
        running = true
        worker = thread(name = "quoth-recorder") {
            val buf = ShortArray(RATE / 10)
            while (running) {
                val n = rec.read(buf, 0, buf.size)
                if (n > 0) synchronized(chunks) { chunks += buf.copyOf(n) }
            }
        }
        return true
    }

    /** Stops and returns the recording as floats in [-1, 1]. */
    fun stop(): FloatArray {
        running = false
        worker?.join(1000)
        record?.run { runCatching { stop() }; release() }
        record = null
        val all = synchronized(chunks) { chunks.toList().also { chunks.clear() } }
        val out = FloatArray(all.sumOf { it.size })
        var i = 0
        for (c in all) for (s in c) out[i++] = s / 32768f
        return out
    }

    companion object {
        const val RATE = 16_000

        /** Reads a 16 kHz mono 16-bit PCM WAV (the debug test input). Skips to the "data" chunk. */
        fun readWav(file: File): FloatArray {
            val bytes = ByteBuffer.wrap(file.readBytes()).order(ByteOrder.LITTLE_ENDIAN)
            var pos = 12
            while (pos + 8 <= bytes.limit()) {
                val id = String(ByteArray(4) { bytes.get(pos + it) }, Charsets.US_ASCII)
                val size = bytes.getInt(pos + 4)
                if (id == "data") {
                    val n = minOf(size, bytes.limit() - pos - 8) / 2
                    return FloatArray(n) { bytes.getShort(pos + 8 + it * 2) / 32768f }
                }
                pos += 8 + size + (size and 1)
            }
            return FloatArray(0)
        }
    }
}
