// SPDX-License-Identifier: Unlicense
#pragma once

#include <optional>
#include <regex>
#include <string>
#include <string_view>
#include <charconv>

namespace best_of_hands {

// Script Extender substitutes CustomProfile for the final game-profile folder.
// Decode JSON escapes so escaped paths and non-ASCII profile names agree too.
inline std::optional<std::string> CustomProfileFromSettings(std::string const& json)
{
    static std::regex const field{R"boh("CustomProfile"\s*:\s*"((?:[^"\\]|\\.)*)")boh"};
    std::smatch match;
    if (!std::regex_search(json, match, field)) return {};
    auto const encoded = match[1].str();
    std::string decoded;
    auto appendUtf8 = [&decoded](unsigned value) {
        if (value < 0x80) decoded += static_cast<char>(value);
        else if (value < 0x800) {
            decoded += static_cast<char>(0xc0 | (value >> 6));
            decoded += static_cast<char>(0x80 | (value & 0x3f));
        } else if (value < 0x10000) {
            decoded += static_cast<char>(0xe0 | (value >> 12));
            decoded += static_cast<char>(0x80 | ((value >> 6) & 0x3f));
            decoded += static_cast<char>(0x80 | (value & 0x3f));
        } else {
            decoded += static_cast<char>(0xf0 | (value >> 18));
            decoded += static_cast<char>(0x80 | ((value >> 12) & 0x3f));
            decoded += static_cast<char>(0x80 | ((value >> 6) & 0x3f));
            decoded += static_cast<char>(0x80 | (value & 0x3f));
        }
    };
    auto readHex = [&encoded](std::size_t position, unsigned& value) {
        if (position + 4 > encoded.size()) return false;
        auto const begin = encoded.data() + position;
        auto const parsed = std::from_chars(begin, begin + 4, value, 16);
        return parsed.ec == std::errc{} && parsed.ptr == begin + 4;
    };
    for (std::size_t i = 0; i < encoded.size(); ++i) {
        if (encoded[i] != '\\') { decoded += encoded[i]; continue; }
        if (++i == encoded.size()) return {};
        switch (encoded[i]) {
        case '"': case '\\': case '/': decoded += encoded[i]; break;
        case 'b': decoded += '\b'; break;
        case 'f': decoded += '\f'; break;
        case 'n': decoded += '\n'; break;
        case 'r': decoded += '\r'; break;
        case 't': decoded += '\t'; break;
        case 'u': {
            unsigned value{};
            if (!readHex(i + 1, value)) return {};
            i += 4;
            if (value >= 0xd800 && value <= 0xdbff) {
                unsigned low{};
                if (i + 6 >= encoded.size() || encoded[i + 1] != '\\'
                    || encoded[i + 2] != 'u' || !readHex(i + 3, low)
                    || low < 0xdc00 || low > 0xdfff) return {};
                value = 0x10000 + ((value - 0xd800) << 10) + low - 0xdc00;
                i += 6;
            } else if (value >= 0xdc00 && value <= 0xdfff) return {};
            appendUtf8(value);
            break;
        }
        default: return {};
        }
    }
    return decoded.empty() ? std::nullopt : std::optional{decoded};
}

} // namespace best_of_hands
