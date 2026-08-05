// SPDX-License-Identifier: Unlicense
#pragma once

#include <cstddef>
#include <span>
#include <string_view>

namespace best_of_hands {

enum class ResolutionSource {
    None,
    ExactTable,
    StructuralCompatibility,
};

enum class CapabilityState {
    Unavailable,
    Ready,
};

struct StructuralCandidate {
    std::size_t identity{};
    bool instructionFingerprint{};
    bool controlFlow{};
    bool callRelationships{};
    bool layout{};
    bool indexes{};
    bool pointers{};
    bool writableSlots{};
};

struct CapabilityResolution {
    CapabilityState state{CapabilityState::Unavailable};
    ResolutionSource source{ResolutionSource::None};
    std::string_view reason{"not_resolved"};
    std::size_t candidateIdentity{};
};

constexpr bool AllStructuralInvariants(StructuralCandidate const& candidate)
{
    return candidate.instructionFingerprint
        && candidate.controlFlow
        && candidate.callRelationships
        && candidate.layout
        && candidate.indexes
        && candidate.pointers
        && candidate.writableSlots;
}

inline CapabilityResolution ResolveStructural(
    std::span<StructuralCandidate const> candidates)
{
    StructuralCandidate const* match = nullptr;
    for (auto const& candidate : candidates) {
        if (!AllStructuralInvariants(candidate)) {
            continue;
        }
        if (match != nullptr && match->identity != candidate.identity) {
            return {CapabilityState::Unavailable, ResolutionSource::None,
                "ambiguous_structural_matches", 0};
        }
        match = &candidate;
    }
    if (match == nullptr) {
        return {CapabilityState::Unavailable, ResolutionSource::None,
            "structural_invariants_unproven", 0};
    }
    return {CapabilityState::Ready,
        ResolutionSource::StructuralCompatibility, "ok", match->identity};
}

inline CapabilityResolution ResolveCapability(bool exactIdentity,
    bool exactCapabilityValid,
    std::span<StructuralCandidate const> structuralCandidates)
{
    if (exactIdentity) {
        return exactCapabilityValid
            ? CapabilityResolution{CapabilityState::Ready,
                ResolutionSource::ExactTable, "ok", 0}
            : CapabilityResolution{CapabilityState::Unavailable,
                ResolutionSource::None, "known_build_invariant_failed", 0};
    }
    return ResolveStructural(structuralCandidates);
}

} // namespace best_of_hands
