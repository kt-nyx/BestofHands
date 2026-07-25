-- SPDX-License-Identifier: Unlicense

local NativeRuntimeApi = {}

local function safe(diagnostics, operation, fallback, callback)
    local ok, result = xpcall(callback, debug.traceback)
    if ok then
        return result
    end
    diagnostics.Warn("api_call_failed", {
        error = result,
        operation = operation,
    })
    return fallback
end

function NativeRuntimeApi.Create(settings, diagnostics)
    local api = {}

    function api.GetPlayers()
        return safe(diagnostics, "DB_Players.Get", {}, function()
            local rows = Osi.DB_Players:Get(nil) or {}
            local players = {}
            for _, row in pairs(rows) do
                local value = row[1]
                if value ~= nil and tostring(value) ~= "" then
                    players[#players + 1] = tostring(value)
                end
            end
            return players
        end)
    end

    function api.CalculateSleightOfHand(character)
        return safe(diagnostics, "Stats.Skills.SleightOfHand", nil, function()
            local entity = Ext.Entity.Get(character)
            if entity == nil or entity.Stats == nil or entity.Stats.Skills == nil then
                return nil
            end
            -- SkillId.SleightOfHand is enum value 5. BG3SE's Lua array is
            -- one-based, so index 6 is the calculated raw skill modifier.
            local modifier = entity.Stats.Skills[6]
            return type(modifier) == "number" and modifier or nil
        end)
    end

    function api.IsPartyMember(character)
        return safe(diagnostics, "IsPartyMember", false, function()
            return Osi.IsPartyMember(character, 0) == 1
        end)
    end

    function api.IsInPartyWith(character, initiator)
        return safe(diagnostics, "IsInPartyWith", false, function()
            return Osi.IsInPartyWith(character, initiator) == 1
        end)
    end

    function api.IsDead(character)
        return safe(diagnostics, "IsDead", true, function()
            return Osi.IsDead(character) == 1
        end)
    end

    function api.IsSummon(character)
        return safe(diagnostics, "IsSummon", true, function()
            return Osi.IsSummon(character) == 1
        end)
    end

    function api.GetRegion(object)
        return safe(diagnostics, "GetRegion", nil, function()
            local region = Osi.GetRegion(object)
            return region ~= nil and tostring(region) ~= "" and tostring(region) or nil
        end)
    end

    function api.HasIneligibleStatus(character)
        for _, status in ipairs(settings.INELIGIBLE_STATUSES) do
            local active = safe(diagnostics, "HasActiveStatus", false, function()
                return Osi.HasActiveStatus(character, status) == 1
            end)
            if active then
                return true, status
            end
        end
        return false, nil
    end

    function api.FindNativeActionTool(action, character)
        local templates = action == "lockpick"
            and settings.VANILLA_THIEVES_TOOLS_TEMPLATES
            or settings.VANILLA_TRAP_DISARM_TOOL_TEMPLATES
        return safe(diagnostics, "GetItemByTemplateInPartyInventory", nil, function()
            for _, template in ipairs(templates or {}) do
                local item = Osi.GetItemByTemplateInPartyInventory(template, character)
                if item ~= nil and tostring(item) ~= "" then
                    local owner = Osi.GetInventoryOwner(item)
                    return {
                        item = tostring(item),
                        owner = owner ~= nil and tostring(owner) or nil,
                        template = template,
                    }
                end
            end
            return nil
        end)
    end

    function api.RejectNativeActionWithoutTool(action, character, target)
        local responsePublished = safe(
            diagnostics,
            action == "lockpick"
                and "DB_CustomLockpickItemResponse"
                or "DB_CustomDisarmTrapResponse",
            false,
            function()
                if action == "lockpick" then
                    Osi.DB_CustomLockpickItemResponse(character, target, 0)
                else
                    Osi.DB_CustomDisarmTrapResponse(character, target, 0)
                end
                return true
            end
        )
        local notificationShown = safe(diagnostics, "ShowError", false, function()
            -- ShowError uses BG3's native, non-modal red-X notification. The
            -- engine exposes only its built-in error-key catalogue here;
            -- CannotUse is the narrow generic entry that remains valid for
            -- both lockpicking and trap disarming.
            Osi.ShowError(character, settings.MISSING_TOOL_ERROR_KEY or "CannotUse")
            return true
        end)
        return responsePublished, notificationShown
    end

    function api.RemoveSkillBoost(character, delta, source)
        return safe(diagnostics, "RemoveBoosts", false, function()
            Osi.RemoveBoosts(
                character,
                string.format("Skill(SleightOfHand,%d)", delta),
                0,
                source,
                character
            )
            return true
        end)
    end

    function api.LoadAssistanceState()
        return safe(diagnostics, "GetModVariables", {}, function()
            local variables = Ext.Vars.GetModVariables(settings.MODULE_UUID)
            return variables[settings.ACTIVE_ASSISTANCE_VAR] or {}
        end)
    end

    function api.SaveAssistanceState(state)
        return safe(diagnostics, "SetModVariables", false, function()
            local variables = Ext.Vars.GetModVariables(settings.MODULE_UUID)
            variables[settings.ACTIVE_ASSISTANCE_VAR] = state
            return true
        end)
    end

    function api.Schedule(milliseconds, callback)
        Ext.Timer.WaitFor(milliseconds, callback)
    end

    function api.GetGameVersion()
        return safe(diagnostics, "GameVersion", "unknown", function()
            return Ext.Utils.GameVersion() or "unknown"
        end)
    end

    function api.GetExtenderVersion()
        return safe(diagnostics, "ExtenderVersion", "unknown", function()
            return Ext.Utils.Version()
        end)
    end

    return api
end

return NativeRuntimeApi
