# libquoth_whisper.so: whisper.cpp (pinned in scripts/fetch-engines.sh), linked statically,
# plus Quoth's small JNI bridge.
cmake_minimum_required(VERSION 3.22)
project(quoth_whisper C CXX)

if(NOT WHISPER_SRC OR NOT EXISTS "${WHISPER_SRC}/CMakeLists.txt")
    message(FATAL_ERROR "whisper.cpp not found at '${WHISPER_SRC}'. Run android/scripts/fetch-engines.sh first.")
endif()

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
# Baseline for arm64 phones from about 2018 on (Cortex-A55/A75 and later, incl. the Pixel 9a's Tensor G4).
set(GGML_CPU_ARM_ARCH "armv8.2-a+dotprod+fp16" CACHE STRING "" FORCE)

add_subdirectory("${WHISPER_SRC}" whisper_build)

add_library(quoth_whisper SHARED whisper_jni.cpp)
target_link_libraries(quoth_whisper PRIVATE whisper log android)
target_link_options(quoth_whisper PRIVATE "-Wl,-z,max-page-size=16384")
