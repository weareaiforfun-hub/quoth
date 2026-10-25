# libquoth.so: whisper.cpp and llama.cpp (pinned in scripts/fetch-engines.sh), linked statically
# and sharing llama.cpp's ggml, plus Quoth's small JNI bridges.
cmake_minimum_required(VERSION 3.22)
project(quoth C CXX)

foreach(src WHISPER_SRC LLAMA_SRC)
    if(NOT ${src} OR NOT EXISTS "${${src}}/CMakeLists.txt")
        message(FATAL_ERROR "${src} not found at '${${src}}'. Run android/scripts/fetch-engines.sh first.")
    endif()
endforeach()

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
# Baseline for arm64 phones from about 2018 on (Cortex-A55/A75 and later, incl. the Pixel 9a's Tensor G4).
set(GGML_CPU_ARM_ARCH "armv8.2-a+dotprod+fp16" CACHE STRING "" FORCE)

foreach(opt COMMON TESTS TOOLS EXAMPLES SERVER APP)
    set(LLAMA_BUILD_${opt} OFF CACHE BOOL "" FORCE)
endforeach()
set(LLAMA_OPENSSL OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)

# llama.cpp first: whisper.cpp reuses the ggml target when one exists.
add_subdirectory("${LLAMA_SRC}" llama_build)
add_subdirectory("${WHISPER_SRC}" whisper_build)

add_library(quoth SHARED whisper_jni.cpp llama_jni.cpp)
target_link_libraries(quoth PRIVATE whisper llama log android)
target_link_options(quoth PRIVATE "-Wl,-z,max-page-size=16384")
