// SPDX-License-Identifier: Unlicense
#pragma once

#include <array>
#include <cstddef>

namespace best_of_hands {

template <class T, std::size_t Capacity>
struct FixedSnapshot {
    std::array<T, Capacity> entries{};
    std::size_t count{};

    bool push_back(T const& value) noexcept
    {
        if (count >= Capacity) {
            return false;
        }
        entries[count++] = value;
        return true;
    }

    void clear() noexcept { count = 0; }
    [[nodiscard]] bool empty() const noexcept { return count == 0; }
    [[nodiscard]] std::size_t size() const noexcept { return count; }
    [[nodiscard]] static constexpr std::size_t capacity() noexcept
    {
        return Capacity;
    }
    [[nodiscard]] T* begin() noexcept { return entries.data(); }
    [[nodiscard]] T* end() noexcept { return entries.data() + count; }
    [[nodiscard]] T const* begin() const noexcept { return entries.data(); }
    [[nodiscard]] T const* end() const noexcept
    {
        return entries.data() + count;
    }
    [[nodiscard]] T& operator[](std::size_t index) noexcept
    {
        return entries[index];
    }
    [[nodiscard]] T const& operator[](std::size_t index) const noexcept
    {
        return entries[index];
    }
};

} // namespace best_of_hands
