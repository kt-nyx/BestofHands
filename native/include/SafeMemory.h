// SPDX-License-Identifier: Unlicense
#pragma once

#include <Windows.h>

#include <cstddef>
#include <cstdint>
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

// Invoke the build-validated ecl::InputController::SetRunningTask routine
// without allowing a game-side access violation to unwind through the native
// mod. The routine's ABI is bool(controller, task, forceClear).
__declspec(noinline) inline bool TryInvokeSetRunningTask(
    std::uintptr_t procedure,
    void* controller,
    void* task,
    bool forceClear,
    bool& started) noexcept
{
    if (procedure == 0 || controller == nullptr || task == nullptr) {
        return false;
    }
    __try {
        using Proc = bool (*)(void*, void*, bool);
        started = reinterpret_cast<Proc>(procedure)(
            controller, task, forceClear);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        started = false;
        return false;
    }
}

// Invoke ecl::InputController::GetCharacterTask through the controller's
// validated virtual method. The caller obtains the method from a real native
// controller and verifies that it belongs to the selected game image.
__declspec(noinline) inline bool TryGetCharacterTask(
    std::uintptr_t procedure,
    void* controller,
    std::uint32_t taskType,
    void*& task) noexcept
{
    if (procedure == 0 || controller == nullptr) {
        return false;
    }
    __try {
        using Proc = void* (*)(void*, std::uint32_t);
        task = reinterpret_cast<Proc>(procedure)(controller, taskType);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        task = nullptr;
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
