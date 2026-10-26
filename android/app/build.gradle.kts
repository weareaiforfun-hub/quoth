import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
}

// Release signing: the upload key lives outside the repo (never committed). The file holds storeFile,
// storePassword, keyAlias and keyPassword; see docs/android-release.md. Without it, release builds are unsigned,
// and -Pquoth.debugSign=true signs them with the debug key for local testing.
val signingFile = file(System.getenv("QUOTH_SIGNING") ?: "${System.getProperty("user.home")}/.quoth/android-signing.properties")
val signing = Properties().apply { if (signingFile.exists()) signingFile.inputStream().use { load(it) } }

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
        if (signing.containsKey("storeFile")) create("upload") {
            storeFile = file(signing.getProperty("storeFile"))
            storePassword = signing.getProperty("storePassword")
            keyAlias = signing.getProperty("keyAlias")
            keyPassword = signing.getProperty("keyPassword")
        }
    }

    buildTypes {
        // Native code is always built optimised: an unoptimised whisper.cpp is far too slow to test.
        debug { externalNativeBuild { cmake { arguments += "-DCMAKE_BUILD_TYPE=Release" } } }
        release {
            // The Kotlin code is small next to the native engines and the word list, so R8 isn't worth its risk to JNI.
            isMinifyEnabled = false
            signingConfig = when {
                signing.containsKey("storeFile") -> signingConfigs.getByName("upload")
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
