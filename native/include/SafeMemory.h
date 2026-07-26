// SPDX-License-Identifier: Unlicense
#pragma once

#include <Windows.h>

#include <cstddef>
#include <cstring>
#include <type_traits>

namespace best_of_hands {

// These leaf routines deliberately contain no objects that require unwinding.
// Keeping SEH in a noinline boundary lets callers use normal C++ RAII while an
// invalid game pointer still fails closed instead of escaping into BG3.
__declspec(noinline) inline bool TryReadMemory(
    void const* source, void* destination, std::size_t size) noexcept
{
    if (source == nullptr || destination == nullptr || size == 0) {
        return false;
    }
    __try {
        std::memcpy(destination, source, size);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

__declspec(noinline) inline bool TryWriteMemory(
    void* destination, void const* source, std::size_t size) noexcept
{
    if (source == nullptr || destination == nullptr || size == 0) {
        return false;
    }
    __try {
        std::memcpy(destination, source, size);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

template <class T>
bool SafeRead(void const* source, T& value) noexcept
{
    static_assert(std::is_trivially_copyable_v<T>);
    T observed{};
    if (!TryReadMemory(source, &observed, sizeof(observed))) {
        return false;
    }
    value = observed;
    return true;
}

template <class T>
bool SafeWrite(void* destination, T const& value) noexcept
{
    static_assert(std::is_trivially_copyable_v<T>);
    return TryWriteMemory(destination, &value, sizeof(value));
}

} // namespace best_of_hands
