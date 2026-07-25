# SPDX-License-Identifier: Unlicense

cmake_minimum_required(VERSION 3.28)

project(BestOfHandsNative VERSION 2.0.0 LANGUAGES CXX)

option(BEST_OF_HANDS_BUILD_TESTS "Build native unit tests" ON)

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
    GIT_TAG "v0.7.0"
    GIT_SHALLOW ON
    EXCLUDE_FROM_ALL
)
FetchContent_MakeAvailable(safetyhook)

add_library(BestOfHandsNative SHARED
    src/BestOfHandsNative.cpp
)

target_include_directories(BestOfHandsNative PRIVATE include)
target_compile_features(BestOfHandsNative PRIVATE cxx_std_23)
target_link_libraries(BestOfHandsNative PRIVATE safetyhook::safetyhook)
target_compile_definitions(BestOfHandsNative PRIVATE
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
    OUTPUT_NAME "BestOfHandsNative"
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
        target_compile_options(BestOfHandsNativeTests PRIVATE /W4 /WX /permissive- /utf-8 /EHsc)
    endif()
    add_test(NAME BestOfHandsNativeTests COMMAND BestOfHandsNativeTests)
endif()
