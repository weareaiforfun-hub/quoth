plugins {
    alias(libs.plugins.android.application)
}

// Release signing: the upload key is ~/.quoth/quoth-upload.jks (never in the repo), and its password is in the
// macOS Keychain (item "quoth-upload"), so it's never in a file. scripts/make-upload-key.sh creates both; see
// docs/android-release.md. Without the key, release builds are unsigned, and -Pquoth.debugSign=true signs them
// with the debug key for local testing. QUOTH_UPLOAD_KEY and QUOTH_UPLOAD_PASSWORD override both (tests, CI).
val uploadKey = file(System.getenv("QUOTH_UPLOAD_KEY") ?: "${System.getProperty("user.home")}/.quoth/quoth-upload.jks")
val wantsRelease = gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }
val uploadPassword: String? = System.getenv("QUOTH_UPLOAD_PASSWORD") ?: if (uploadKey.exists() && wantsRelease) {
    providers.exec {
        commandLine("security", "find-generic-password", "-s", "quoth-upload", "-a", "quoth", "-w")
        isIgnoreExitValue = true
    }.standardOutput.asText.get().trim().ifEmpty { null }
} else null

android {
    namespace = "app.quoth.android"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    defaultConfig {
        applicationId = "app.quoth"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        ndk { abiFilters += "arm64-v8a" }
        externalNativeBuild {
            cmake {
                arguments += listOf(
                    "-DWHISPER_SRC=${rootProject.file("third_party/whisper.cpp").absolutePath}",
                    "-DLLAMA_SRC=${rootProject.file("third_party/llama.cpp").absolutePath}",
                    "-DANDROID_STL=c++_static",
                )
            }
        }
    }

    signingConfigs {
        if (uploadPassword != null) create("upload") {
            storeFile = uploadKey
            storePassword = uploadPassword
            keyAlias = "quoth-upload"
            keyPassword = uploadPassword
        }
    }

    buildTypes {
        // Native code is always built optimised: an unoptimised whisper.cpp is far too slow to test.
        debug { externalNativeBuild { cmake { arguments += "-DCMAKE_BUILD_TYPE=Release" } } }
        release {
            // The Kotlin code is small next to the native engines and the word list, so R8 isn't worth its risk to JNI.
            isMinifyEnabled = false
            signingConfig = when {
                uploadPassword != null -> signingConfigs.getByName("upload")
                providers.gradleProperty("quoth.debugSign").orNull == "true" -> signingConfigs.getByName("debug")
                else -> null
            }
            // Play shows readable native crash stacks with these.
            ndk { debugSymbolLevel = "SYMBOL_TABLE" }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.31.6"
        }
    }

    buildFeatures { buildConfig = true }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(project(":core"))
}
