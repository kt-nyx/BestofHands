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
    local actionToolCandidates = {
        disarm = {},
        lockpick = {},
    }
    local toolCompatibilityStatus = {}

    for action, providers in pairs(
        settings.OPTIONAL_ACTION_TOOL_PROVIDERS or {}
    ) do
        actionToolCandidates[action] = actionToolCandidates[action] or {}
        for _, provider in ipairs(providers) do
            local loaded = safe(
                diagnostics,
                "Ext.Mod.IsModLoaded",
                false,
                function()
                    return Ext.Mod ~= nil
                        and type(Ext.Mod.IsModLoaded) == "function"
                        and Ext.Mod.IsModLoaded(provider.moduleUuid) == true
                end
            )
            toolCompatibilityStatus[provider.id] = loaded
            if loaded then
                for _, template in ipairs(provider.templates or {}) do
                    actionToolCandidates[action][#actionToolCandidates[action] + 1] = {
                        moduleUuid = provider.moduleUuid,
                        provider = provider.id,
                        template = template,
                    }
                end
                diagnostics.Info("optional_tool_provider_loaded", {
                    action = action,
                    module_uuid = provider.moduleUuid,
                    provider = provider.id,
                })
            end
        end
    end

    for action, templates in pairs({
        disarm = settings.VANILLA_TRAP_DISARM_TOOL_TEMPLATES,
        lockpick = settings.VANILLA_THIEVES_TOOLS_TEMPLATES,
    }) do
        for _, template in ipairs(templates or {}) do
            actionToolCandidates[action][#actionToolCandidates[action] + 1] = {
                provider = "vanilla",
                template = template,
            }
        end
    end

    function api.GetPlayers()
        return safe(diagnostics, "DB_Players.Get", {}, function()
            local rows = Osi.DB_Players:Get(nil) or {}
            local players = {}
            local seen = {}
            for _, row in pairs(rows) do
                local value = row[1]
                local player = value ~= nil and tostring(value) or ""
                if player ~= "" and not seen[player] then
                    seen[player] = true
                    players[#players + 1] = player
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
        return safe(diagnostics, "GetItemByTemplateInPartyInventory", nil, function()
            for _, candidate in ipairs(actionToolCandidates[action] or {}) do
                local item = Osi.GetItemByTemplateInPartyInventory(
                    candidate.template,
                    character
                )
                if item ~= nil and tostring(item) ~= "" then
                    local owner = Osi.GetInventoryOwner(item)
                    return {
                        item = tostring(item),
                        moduleUuid = candidate.moduleUuid,
                        owner = owner ~= nil and tostring(owner) or nil,
                        provider = candidate.provider,
                        template = candidate.template,
                    }
                end
            end
            return nil
        end)
    end

    function api.GetToolCompatibilityStatus()
        local status = {}
        for provider, loaded in pairs(toolCompatibilityStatus) do
            status[provider] = loaded
        end
        return status
    end

    function api.IsPlayer(character)
        return safe(diagnostics, "DB_Players.Get", false, function()
            local rows = Osi.DB_Players:Get(character) or {}
            return next(rows) ~= nil
        end)
    end

    function api.IsLocked(target)
        return safe(diagnostics, "IsLocked", false, function()
            return Osi.IsLocked(target) == 1
        end)
    end

    function api.IsInCombat(character)
        return safe(diagnostics, "IsInCombat", true, function()
            return Osi.IsInCombat(character) == 1
        end)
    end

    function api.GetEntityUuid(value)
        return safe(diagnostics, "EntityUuid", nil, function()
            local entity = Ext.Entity.Get(value)
            local uuid = entity
                and entity.Uuid
                and entity.Uuid.EntityUuid
                or nil
            return uuid ~= nil and tostring(uuid) or nil
        end)
    end

    function api.GetReservedUserId(character)
        return safe(diagnostics, "GetReservedUserID", nil, function()
            local userId = Osi.GetReservedUserID(character)
            return type(userId) == "number" and userId >= 0 and userId or nil
        end)
    end

    function api.SendQuickLockpick(channel, payload, userId)
        return safe(diagnostics, "QuickLockpick.SendToClient", false, function()
            channel:SendToClient(payload, userId)
            return true
        end)
    end

    function api.MonotonicTime()
        return safe(diagnostics, "MonotonicTime", nil, function()
            if Ext.Utils ~= nil
                and type(Ext.Utils.MonotonicTime) == "function" then
                return Ext.Utils.MonotonicTime()
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
