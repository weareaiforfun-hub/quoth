package app.quoth.core

import com.sun.net.httpserver.HttpServer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.net.InetSocketAddress
import java.nio.file.Files
import java.security.MessageDigest
import kotlin.random.Random

class ModelDownloaderTest {
    private val payload = Random(7).nextBytes(300_000)
    private val sha = MessageDigest.getInstance("SHA-256").digest(payload).joinToString("") { "%02x".format(it) }
    private lateinit var server: HttpServer
    private lateinit var dir: File
    private val ranges = mutableListOf<String?>()
    /** When set, the server stops after this many bytes (a dropped connection). */
    @Volatile private var cutAfter: Int? = null

    @Before fun setUp() {
        dir = Files.createTempDirectory("quoth-dl").toFile()
        server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/model.bin") { ex ->
            val range = ex.requestHeaders.getFirst("Range")
            ranges += range
            val start = range?.removePrefix("bytes=")?.removeSuffix("-")?.toInt() ?: 0
            val end = cutAfter?.let { minOf(it, payload.size) } ?: payload.size
            val body = payload.copyOfRange(start, end)
            ex.sendResponseHeaders(if (start > 0) 206 else 200, 0)
            ex.responseBody.use { it.write(body) }
        }
        server.start()
    }

    @After fun tearDown() {
        server.stop(0)
        dir.deleteRecursively()
    }

    private fun model(sha256: String = sha) =
        ModelFile("model.bin", "Test", payload.size.toLong(), sha256, "http://127.0.0.1:${server.address.port}/model.bin")

    @Test fun downloadsAndVerifies() {
        val dl = ModelDownloader(dir)
        var last = 0L
        dl.download(model()) { have, _ -> last = have }
        assertArrayEquals(payload, File(dir, "model.bin").readBytes())
        assertEquals(payload.size.toLong(), last)
        assertTrue(dl.isInstalled(model()))
        assertFalse(File(dir, "model.bin.part").exists())
    }

    @Test fun resumesWithRangeAfterDroppedConnection() {
        cutAfter = 100_000
        val dl = ModelDownloader(dir, retries = 1)
        runCatching { dl.download(model()) }
        assertEquals(100_000L, File(dir, "model.bin.part").length())
        cutAfter = null
        dl.download(model())
        assertEquals("bytes=100000-", ranges.last())
        assertArrayEquals(payload, File(dir, "model.bin").readBytes())
    }

    @Test fun discardsBadChecksum() {
        val dl = ModelDownloader(dir)
        val bad = model(sha256 = "0".repeat(64))
        val error = runCatching { dl.download(bad) }.exceptionOrNull()
        assertTrue(error is ChecksumException)
        assertFalse(File(dir, "model.bin").exists())
        assertFalse(File(dir, "model.bin.part").exists())
        assertEquals(1, ranges.size) // a checksum failure is not retried
    }
}
