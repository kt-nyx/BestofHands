-- SPDX-License-Identifier: Unlicense

local FeatureSettings = {}
local IDS = { "best_in_party_lockpick", "best_in_party_disarm" }

-- Read only the host/server configuration. Legacy booleans remain readable;
-- missing MCM and invalid values retain the default On behavior.
local function mode(value)
    if value == false or value == "Off" then return "Off" end
    if value == "Only while sneaking" then return value end
    return "On"
end

function FeatureSettings.Read(moduleUuid)
    local values = {}
    for _, id in ipairs(IDS) do
        values[id] = "On"
        if type(MCM) == "table" and type(MCM.Get) == "function" then
            local ok, value = pcall(MCM.Get, id, moduleUuid)
            if ok then values[id] = mode(value) end
        end
    end
    return values
end

function FeatureSettings.Create(settings, api)
    local instance = {}
    function instance.GetMode(id)
        -- Read at action admission, not during an accepted roll. This also
        -- handles MCM initialization order, resets, and profile changes
        -- without caching settings or depending on optional MCM events.
        return FeatureSettings.Read(settings.MODULE_UUID)[id] or "On"
    end
    function instance.IsEnabled(id, actor)
        local value = instance.GetMode(id)
        if value == "Only while sneaking" then
            return actor ~= nil and api ~= nil and api.IsSneaking(actor) == true
        end
        return value == "On"
    end
    return instance
end

return FeatureSettings
