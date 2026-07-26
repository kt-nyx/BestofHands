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
            return false
        end
        if not api.IsInPartyWith(candidate, initiator) then
            return false
        end
        if api.IsDead(candidate) then
            return false
        end
        if api.IsSummon(candidate) then
            return false
        end
        local unavailable = api.HasIneligibleStatus(candidate)
        if unavailable then
            return false
        end
        if region == nil or api.GetRegion(candidate) ~= region then
            return false
        end
        return true
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

        for _, candidate in ipairs(players) do
            local eligible = eligibility(candidate, initiator, region)
            local score = nil
            if eligible then
                score = api.CalculateSleightOfHand(candidate)
                eligible = type(score) == "number"
            end

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
        }

        if type(diagnostics.IsTraceEnabled) ~= "function"
            or diagnostics.IsTraceEnabled() then
            diagnostics.Trace("skill_resolved", {
                action = action,
                actor = initiator,
                actor_score = initiatorScore,
                request_id = requestId,
                specialist = bestCharacter,
                specialist_score = bestScore,
                target = target,
            })
        end
        return result
    end

    return instance
end

return PartySkillResolver
