// SPDX-License-Identifier: Unlicense
#pragma once
#include <algorithm>
#include <cstdint>
#include <string>
#include <utility>

namespace best_of_hands {

// Retain the latest status until it reaches disk. The worker retries even
// when Lua cannot read a session nonce and therefore cannot change its input.
class StatusPublication {
public:
    void Queue(std::string text, bool repair = false)
    {
        if (!repair && text == text_) return;
        text_ = std::move(text);
        if (!pending_) retryAfter_ = 0;
        pending_ = true;
    }
    bool Pending() const { return pending_; }
    std::string const& Text() const { return text_; }
    std::uint32_t Failures() const { return failures_; }

    template<class Writer>
    bool Poll(std::uint64_t now, Writer&& writer)
    {
        if (!pending_ || text_.empty() || now < retryAfter_) return false;
        if (writer(text_)) {
            pending_ = false;
            failures_ = 0;
            retryAfter_ = 0;
            return true;
        }
        failures_ = (std::min)(failures_ + 1U, 5U);
        retryAfter_ = now + (std::min)(250ULL << (failures_ - 1), 2000ULL);
        return false;
    }

private:
    std::string text_;
    bool pending_{};
    std::uint32_t failures_{};
    std::uint64_t retryAfter_{};
};
} // namespace best_of_hands
