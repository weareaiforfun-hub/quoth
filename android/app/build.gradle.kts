plugins {
    alias(libs.plugins.android.application)
}

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

    buildTypes {
        // Native code is always built optimised: an unoptimised whisper.cpp is far too slow to test.
        debug { externalNativeBuild { cmake { arguments += "-DCMAKE_BUILD_TYPE=Release" } } }
        release { isMinifyEnabled = false }
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
