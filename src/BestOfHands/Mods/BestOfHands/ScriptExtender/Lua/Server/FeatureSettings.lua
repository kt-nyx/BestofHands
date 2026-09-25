-- SPDX-License-Identifier: Unlicense

local FeatureSettings = {}
local IDS = { "best_in_party_lockpick", "best_in_party_disarm" }

-- Read only the host/server MCM configuration. Only a boolean false disables
-- a feature: absent MCM, untouched settings, and invalid values keep it On.
function FeatureSettings.Read(moduleUuid)
    local values = {}
    for _, id in ipairs(IDS) do
        values[id] = true
        if type(MCM) == "table" and type(MCM.Get) == "function" then
            local ok, value = pcall(MCM.Get, id, moduleUuid)
            if ok and type(value) == "boolean" then values[id] = value end
        end
    end
    return values
end

function FeatureSettings.Create(settings)
    local instance = {}
    function instance.IsEnabled(id)
        -- Read at action admission, not during an accepted roll. This also
        -- handles MCM initialization order, resets, and profile changes
        -- without caching settings or depending on optional MCM events.
        return FeatureSettings.Read(settings.MODULE_UUID)[id] ~= false
    end
    return instance
end

return FeatureSettings
