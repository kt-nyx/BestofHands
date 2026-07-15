-- SPDX-License-Identifier: Unlicense

local PartySkillResolver = {}

local function contains(values, expected)
    for _, value in ipairs(values) do
        if value == expected then
            return true
        end
    end
    return false
end

function PartySkillResolver.Create(api, diagnostics)
    local instance = {}

    local function eligibility(candidate, initiator, region)
        if not api.IsPartyMember(candidate) then
            return false, "not_active_party_member"
        end
        if not api.IsInPartyWith(candidate, initiator) then
            return false, "different_party"
        end
        if api.IsDead(candidate) then
            return false, "dead"
        end
        if api.IsSummon(candidate) then
            return false, "summon"
        end
        local unavailable, status = api.HasIneligibleStatus(candidate)
        if unavailable then
            return false, "status_" .. tostring(status)
        end
        if region == nil or api.GetRegion(candidate) ~= region then
            return false, "different_or_unknown_region"
        end
        return true, nil
    end

    function instance.Resolve(initiator, target, action, requestId)
        local initiatorScore = api.CalculateSleightOfHand(initiator)
        if type(initiatorScore) ~= "number" then
            diagnostics.Warn("resolve_failed", {
                action = action,
                actor = initiator,
                reason = "initiator_score_unavailable",
                request_id = requestId,
                target = target,
            })
            return nil
        end

        local region = api.GetRegion(initiator)
        local players = api.GetPlayers()
        if not contains(players, initiator) then
            players[#players + 1] = initiator
        end
        table.sort(players)

        local bestCharacter = initiator
        local bestScore = initiatorScore
        local candidates = {}

        for _, candidate in ipairs(players) do
            local eligible, reason = eligibility(candidate, initiator, region)
            local score = nil
            if eligible then
                score = api.CalculateSleightOfHand(candidate)
                eligible = type(score) == "number"
                if not eligible then
                    reason = "score_unavailable"
                end
            end

            candidates[#candidates + 1] = {
                character = candidate,
                eligible = eligible,
                reason = reason,
                score = score,
            }

            if eligible and (score > bestScore or (score == bestScore and candidate == initiator)) then
                bestCharacter = candidate
                bestScore = score
            end
        end

        local result = {
            action = action,
            initiator = initiator,
            initiatorScore = initiatorScore,
            requestId = requestId,
            specialist = bestCharacter,
            specialistScore = bestScore,
            target = target,
            candidates = candidates,
        }

        diagnostics.Trace("skill_resolved", {
            action = action,
            actor = initiator,
            actor_score = initiatorScore,
            request_id = requestId,
            specialist = bestCharacter,
            specialist_score = bestScore,
            target = target,
        })
        return result
    end

    return instance
end

return PartySkillResolver
