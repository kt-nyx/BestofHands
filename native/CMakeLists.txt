# SPDX-License-Identifier: Unlicense

cmake_minimum_required(VERSION 3.28)

project(BestOfHandsNative VERSION 2.0.1 LANGUAGES CXX RC)

option(BEST_OF_HANDS_BUILD_TESTS "Build native unit tests" ON)
option(BEST_OF_HANDS_PERF_DIAGNOSTICS
    "Enable low-overhead per-roll native timing summaries" OFF)

include(CheckIPOSupported)
check_ipo_supported(RESULT BEST_OF_HANDS_IPO_SUPPORTED)

set(BUILD_SHARED_LIBS OFF)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

include(FetchContent)
set(SAFETYHOOK_BUILD_DOCS OFF CACHE BOOL "" FORCE)
set(SAFETYHOOK_BUILD_TEST OFF CACHE BOOL "" FORCE)
set(SAFETYHOOK_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SAFETYHOOK_FETCH_ZYDIS ON CACHE BOOL "" FORCE)
FetchContent_Declare(
    safetyhook
    GIT_REPOSITORY "https://github.com/cursey/safetyhook.git"
    # SafetyHook v0.7.0, pinned to the immutable commit for reproducibility.
    GIT_TAG "19223663fb8a573253ffb2e82da87cc354bf5c16"
    GIT_SHALLOW ON
    EXCLUDE_FROM_ALL
)
FetchContent_MakeAvailable(safetyhook)

set(BEST_OF_HANDS_NOTICES_PATH
    "${PROJECT_SOURCE_DIR}/../THIRD_PARTY_NOTICES.txt")
if(NOT EXISTS "${BEST_OF_HANDS_NOTICES_PATH}")
    message(FATAL_ERROR
        "Third-party notices were not found: ${BEST_OF_HANDS_NOTICES_PATH}")
endif()
configure_file(
    resources/BestofHands.rc.in
    "${CMAKE_CURRENT_BINARY_DIR}/generated/BestofHands.rc"
    @ONLY
)

add_library(BestOfHandsNative SHARED
    src/BestOfHandsNative.cpp
    "${CMAKE_CURRENT_BINARY_DIR}/generated/BestofHands.rc"
)

target_include_directories(BestOfHandsNative PRIVATE include)
target_compile_features(BestOfHandsNative PRIVATE cxx_std_23)
target_link_libraries(BestOfHandsNative PRIVATE safetyhook::safetyhook)
target_compile_definitions(BestOfHandsNative PRIVATE
    BEST_OF_HANDS_PERF_DIAGNOSTICS=$<BOOL:${BEST_OF_HANDS_PERF_DIAGNOSTICS}>
    WIN32_LEAN_AND_MEAN
    NOMINMAX
    UNICODE
    _UNICODE
)

if(MSVC)
    target_compile_options(BestOfHandsNative PRIVATE /W4 /WX /permissive- /utf-8 /EHsc)
    target_link_options(BestOfHandsNative PRIVATE /INCREMENTAL:NO)
endif()

set_target_properties(BestOfHandsNative PROPERTIES
    INTERPROCEDURAL_OPTIMIZATION_RELEASE "${BEST_OF_HANDS_IPO_SUPPORTED}"
    OUTPUT_NAME "BestofHands"
    MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin/NativeMods"
    RUNTIME_OUTPUT_DIRECTORY_DEBUG "${CMAKE_BINARY_DIR}/bin/NativeMods"
    RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CMAKE_BINARY_DIR}/bin/NativeMods"
    RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO "${CMAKE_BINARY_DIR}/bin/NativeMods"
)

if(BEST_OF_HANDS_BUILD_TESTS)
    enable_testing()
    add_executable(BestOfHandsNativeTests tests/BridgeProtocolTests.cpp)
    target_include_directories(BestOfHandsNativeTests PRIVATE include)
    target_compile_features(BestOfHandsNativeTests PRIVATE cxx_std_20)
    set_target_properties(BestOfHandsNativeTests PROPERTIES
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>"
    )
    if(MSVC)
        # Release builds define NDEBUG by default. Keep the assertion-based
        # protocol tests active in the same Release configuration we ship.
        target_compile_options(BestOfHandsNativeTests PRIVATE /UNDEBUG /W4 /WX /permissive- /utf-8 /EHsc)
    else()
        target_compile_options(BestOfHandsNativeTests PRIVATE -UNDEBUG)
    endif()
    add_test(NAME BestOfHandsNativeTests COMMAND BestOfHandsNativeTests)
endif()
