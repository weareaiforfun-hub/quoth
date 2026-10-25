// Platform-neutral Quoth logic (rules, prompt, pipeline). No Android dependencies,
// so its tests run on the Mac's JVM.
plugins {
    alias(libs.plugins.kotlin.jvm)
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    testImplementation(libs.junit)
}
