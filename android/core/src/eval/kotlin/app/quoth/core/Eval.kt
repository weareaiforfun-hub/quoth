// Runs the Kotlin cleanup stage over Evals/cleanup-golden.jsonl and scores it, like the Mac's quoth-eval.
// The LLM is any OpenAI-compatible server, normally a llama-server on this Mac:
//
//   ./gradlew :core:eval --args="--port 8190"                       # the model that server is serving
//   ./gradlew :core:eval --args="--port 8190 --only lists --verbose"
//   ./gradlew :core:eval --args="--base-url https://api.groq.com/openai/v1 --model llama-3.3-70b-versatile"  # key in QUOTH_API_KEY
package app.quoth.core

import java.io.File
import kotlin.system.exitProcess

fun main(argv: Array<String>) {
    val args = argv.toMutableList()
    fun flag(name: String) = args.remove(name)
    fun option(name: String): String? {
        val i = args.indexOf(name)
        if (i < 0 || i + 1 >= args.size) return null
        return args[i + 1].also { args.removeAt(i + 1); args.removeAt(i) }
    }

    val verbose = flag("--verbose")
    val only = option("--only")
    val level = CleanupLevel.of(option("--level")) ?: CleanupLevel.LIGHT
    val file = File(option("--file") ?: "../../Evals/cleanup-golden.jsonl")
    val outputs = option("--outputs")?.let(::File)
    val baseURL = option("--base-url") ?: "http://127.0.0.1:${option("--port") ?: "8179"}/v1"
    val model = option("--model") ?: ChatCompletionsClient.servedModels(baseURL).firstOrNull()
        ?: run { println("No model is being served at $baseURL: start llama-server first"); exitProcess(1) }
    val client = ChatCompletionsClient(baseURL, model, System.getenv("QUOTH_API_KEY"))
    val label = "$model at $baseURL"

    if (!file.exists()) { println("cannot read $file"); exitProcess(1) }
    val cases = CleanupCase.load(file.readText()).filter { only == null || it.category == only || it.id == only }
    println("Evaluating ${cases.size} cases with $label, level ${level.raw}\n")
    val results = ModelBench.runCleanup(client, label, cases, level) { r ->
        val v = r.verdict
        val c = cases.first { it.id == r.caseID }
        println("${v.symbol} ${r.caseID.padEnd(18)} ${"%5d".format(r.ms)} ms  ${v.problems.joinToString(", ")}")
        if (verbose || !v.sameWords || v.serious) {
            println("    raw:      ${c.raw.replace("\n", "⏎")}")
            println("    expected: ${c.expected.replace("\n", "⏎")}")
            println("    got:      ${r.output.replace("\n", "⏎")}")
        }
    }
    outputs?.writeText(results.joinToString("") { "${it.caseID}\t${it.output.replace("\n", "⏎")}\n" })
    val sum = ModelBench.summarize(results, label)
    val byCategory = sortedMapOf<String, Pair<Int, Int>>()
    for (r in results) {
        val c = cases.first { it.id == r.caseID }
        val (ok, n) = byCategory[c.category] ?: (0 to 0)
        byCategory[c.category] = (ok + if (r.verdict.sameWords && !r.verdict.serious) 1 else 0) to n + 1
    }
    println("""

        Legend: ✓ exact  ≈ same words (punctuation/case differ)  · different  ✗ hard failure

        Exact:       ${sum.exact}/${sum.cases}
        Same words:  ${sum.sameWords}/${sum.cases}
        Hard fails:  ${sum.serious}   (answered, added content, or fell back)
        Latency:     p50 ${sum.p50ms} ms   p90 ${sum.p90ms} ms   max ${results.maxOfOrNull { it.ms } ?: 0} ms

        By category (same words, no hard failure):
    """.trimIndent())
    for ((k, v) in byCategory) println("  ${k.padEnd(20)} ${v.first}/${v.second}")
    exitProcess(if (sum.serious == 0) 0 else 1)
}
