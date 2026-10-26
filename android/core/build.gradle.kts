// Platform-neutral Quoth logic (rules, prompt, pipeline). No Android dependencies,
// so its tests run on the Mac's JVM.
plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    api(libs.serialization.json)
    testImplementation(libs.junit)
}

// The golden-eval runner (src/eval): ./gradlew :core:eval --args="--port 8190"
sourceSets {
    create("eval") {
        compileClasspath += sourceSets.main.get().output + configurations.runtimeClasspath.get()
        runtimeClasspath += output + compileClasspath
    }
}

tasks.register<JavaExec>("eval") {
    description = "Scores the Kotlin cleanup pipeline on Evals/cleanup-golden.jsonl"
    classpath = sourceSets["eval"].runtimeClasspath
    mainClass = "app.quoth.core.EvalKt"
    workingDir = projectDir
    isIgnoreExitValue = true
}
