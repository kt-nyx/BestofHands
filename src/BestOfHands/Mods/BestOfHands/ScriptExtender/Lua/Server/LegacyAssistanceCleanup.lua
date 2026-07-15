-- SPDX-License-Identifier: Unlicense

-- Removes exact temporary Sleight boosts persisted by older Best of Hands builds.
-- Current roll delegation never creates these boosts.
local LegacyAssistanceCleanup = {}

local function copyState(state)
    local result = {}
    for key, value in pairs(state or {}) do
        result[key] = value
    end
    return result
end

function LegacyAssistanceCleanup.Create(api, diagnostics)
    local retained = {}
    local instance = {}

    local function persist()
        api.SaveAssistanceState(copyState(retained))
    end

    function instance.RecoverPersisted()
        local persisted = api.LoadAssistanceState()
        local recovered = 0
        local nextRetained = {}

        for key, record in pairs(persisted or {}) do
            if type(record) == "table"
                and type(record.actor) == "string"
                and type(record.delta) == "number"
                and type(record.source) == "string" then
                if api.RemoveSkillBoost(record.actor, record.delta, record.source) then
                    recovered = recovered + 1
                else
                    -- Keep valid ownership metadata so a later session load or
                    -- Lua reset can retry instead of orphaning the legacy boost.
                    nextRetained[key] = record
                end
            end
        end

        retained = nextRetained
        persist()

        if recovered > 0 then
            diagnostics.Info("assistance_recovered", { count = recovered })
        end
        if instance.Count() > 0 then
            diagnostics.Warn("assistance_recovery_deferred", { count = instance.Count() })
        end
    end

    function instance.Count()
        local count = 0
        for _ in pairs(retained) do
            count = count + 1
        end
        return count
    end

    return instance
end

return LegacyAssistanceCleanup
