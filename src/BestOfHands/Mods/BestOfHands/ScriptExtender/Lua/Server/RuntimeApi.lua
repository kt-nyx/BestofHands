-- SPDX-License-Identifier: Unlicense

local RuntimeApi = {}
local NULL_GUID = "00000000-0000-0000-0000-000000000000"

local function normalizeGuid(value)
    if value == nil then
        return nil
    end
    local result = tostring(value)
    if result == "" or result == NULL_GUID then
        return nil
    end
    return result
end

local function safe(diagnostics, operation, fallback, callback)
    local ok, result = xpcall(callback, debug.traceback)
    if ok then
        return result
    end
    diagnostics.Warn("api_call_failed", {
        operation = operation,
        error = result,
    })
    return fallback
end

function RuntimeApi.Create(settings, diagnostics)
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

            -- SkillId.SleightOfHand is enum value 5. BG3SE exposes static
            -- arrays to Lua with one-based indexing, hence index 6 here.
            -- This is the actual calculated skill modifier used by a roll;
            -- CalculatePassiveSkill is unsuitable because it adds the passive
            -- baseline and can fold advantage/disadvantage into a +/-5 value.
            local modifier = entity.Stats.Skills[6]
            if type(modifier) ~= "number" then
                return nil
            end
            return modifier
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
            if region == nil or tostring(region) == "" then
                return nil
            end
            return tostring(region)
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

    function api.RemoveSkillBoost(character, delta, source)
        return safe(diagnostics, "RemoveBoosts", false, function()
            Osi.RemoveBoosts(character, string.format("Skill(SleightOfHand,%d)", delta), 0, source, character)
            return true
        end)
    end

    function api.Schedule(milliseconds, callback)
        Ext.Timer.WaitFor(milliseconds, callback)
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

    function api.IsLocked(item)
        return safe(diagnostics, "IsLocked", false, function()
            return Osi.IsLocked(item) == 1
        end)
    end

    function api.IsActionAvailable(action, item)
        if action == "disarm" then
            return safe(diagnostics, "IsTrapArmed", false, function()
                return Osi.IsTrapArmed(item) == 1
            end)
        end
        return api.IsLocked(item)
    end

    function api.IsInCombat(character)
        return safe(diagnostics, "IsInCombat", true, function()
            return Osi.IsInCombat(character) == 1
        end)
    end

    local function templatesForAction(action)
        if action == "lockpick" then
            return settings.THIEVES_TOOLS_TEMPLATES
        elseif action == "disarm" then
            return settings.TRAP_DISARM_TOOL_TEMPLATES
        end
        return {}
    end

    local function inventoryItem(template, holder)
        return safe(diagnostics, "GetItemByTemplateInInventory", nil, function()
            local item = Osi.GetItemByTemplateInInventory(template, holder)
            if item == nil or tostring(item) == "" then
                return nil
            end
            return tostring(item)
        end)
    end

    local function itemOwner(item, fallback)
        return safe(diagnostics, "GetInventoryOwner", fallback, function()
            local owner = Osi.GetInventoryOwner(item)
            if owner == nil or tostring(owner) == "" then
                return fallback
            end
            return tostring(owner)
        end)
    end

    function api.FindActionTool(action, specialist, initiator)
        local templates = templatesForAction(action)
        local holders = { specialist }
        local seen = { [specialist] = true }
        if initiator ~= specialist then
            holders[#holders + 1] = initiator
            seen[initiator] = true
        end

        local players = api.GetPlayers()
        table.sort(players)
        for _, player in ipairs(players) do
            if not seen[player]
                and api.IsPartyMember(player)
                and api.IsInPartyWith(player, initiator) then
                holders[#holders + 1] = player
                seen[player] = true
            end
        end

        -- Prefer the specialist's own inventory, then the initiating
        -- character, then the rest of the active party. This makes failure
        -- consumption deterministic while retaining a final vanilla party-
        -- inventory fallback for nested or magic-pockets inventory layouts.
        for _, holder in ipairs(holders) do
            for _, template in ipairs(templates) do
                local item = inventoryItem(template, holder)
                if item ~= nil then
                    return {
                        item = item,
                        owner = itemOwner(item, holder),
                        template = template,
                    }
                end
            end
        end

        for _, template in ipairs(templates) do
            local item = safe(diagnostics, "GetItemByTemplateInPartyInventory", nil, function()
                return Osi.GetItemByTemplateInPartyInventory(template, specialist)
            end)
            if item ~= nil and tostring(item) ~= "" then
                item = tostring(item)
                return {
                    item = item,
                    owner = itemOwner(item, specialist),
                    template = template,
                }
            end
        end
        return nil
    end

    function api.GetActionDifficultyClass(action, item)
        return safe(diagnostics, "GetActionDifficultyClass", nil, function()
            local templateId = Osi.GetTemplate(item)
            if templateId ~= nil and tostring(templateId) ~= "" then
                local template = Ext.Template.GetRootTemplate(tostring(templateId))
                    or Ext.Template.GetTemplate(tostring(templateId))
                if template ~= nil then
                    local field = action == "disarm"
                        and "DisarmDifficultyClassID"
                        or "LockDifficultyClassID"
                    local difficulty = normalizeGuid(template[field])
                    if difficulty ~= nil then
                        return difficulty
                    end
                end
            end

            -- Some runtime targets do not expose a usable root-template DC.
            -- BG3SE currently exposes their fallback GUID under an unmapped
            -- component field name.
            local entity = Ext.Entity.Get(item)
            local component = nil
            local field = nil
            if entity ~= nil and action == "lockpick" then
                component = entity.Lock
                field = "field_8"
            elseif entity ~= nil and action == "disarm" then
                component = entity.Disarmable
                field = "field_0"
            end
            if component ~= nil then
                local difficulty = normalizeGuid(component[field])
                if difficulty ~= nil then
                    return difficulty
                end
            end
            return nil
        end)
    end

    function api.BlockNativeAction(action, character, item)
        return safe(diagnostics, "BlockNativeAction", false, function()
            local database = action == "disarm"
                and Osi.DB_CustomDisarmTrapResponse
                or Osi.DB_CustomLockpickItemResponse
            local existing = database:Get(character, item, nil) or {}
            if next(existing) ~= nil then
                diagnostics.Warn("delegation_skipped", {
                    action = action,
                    actor = character,
                    reason = "custom_response_already_present",
                    target = item,
                })
                return false
            end
            database(character, item, 0)
            return true
        end)
    end

    function api.ProcessActionPermission(action, character, item, requestId)
        return safe(diagnostics, "ProcessActionPermission", false, function()
            if action == "disarm" then
                Osi.PROC_BlockTrapDisarm(character, item)
                Osi.PROC_ProcessDisarmTrap(character, item, requestId)
            else
                Osi.PROC_BlockLockpickItem(character, item)
                Osi.PROC_ProcessLockpickItem(character, item, requestId)
            end
            return true
        end)
    end

    function api.RequestActiveSleightRoll(character, item, difficultyClass, event)
        return safe(diagnostics, "RequestActiveRoll", false, function()
            Osi.RequestActiveRoll(
                character,
                item,
                "RawAbility",
                "SleightOfHand",
                difficultyClass,
                0,
                event
            )
            return true
        end)
    end

    function api.CompleteAction(action, item, character)
        return safe(diagnostics, "CompleteAction", false, function()
            if action == "disarm" then
                Osi.SetTrapArmed(item, 0)
            else
                Osi.Unlock(item, character)
            end
            return true
        end)
    end

    function api.NotifyDisarmAttempt(item, character, tool, succeeded)
        return safe(diagnostics, "AttemptedDisarm", false, function()
            Osi.AttemptedDisarm(item, character, tool, succeeded and 1 or 0)
            return true
        end)
    end

    function api.UseTarget(character, item, event)
        return safe(diagnostics, "Use", false, function()
            Osi.Use(character, item, 1, 1, event)
            return true
        end)
    end

    function api.ConsumeActionTool(tool)
        return safe(diagnostics, "TemplateRemoveFrom", false, function()
            Osi.TemplateRemoveFrom(tool.template, tool.owner, 1)
            return true
        end)
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

return RuntimeApi
