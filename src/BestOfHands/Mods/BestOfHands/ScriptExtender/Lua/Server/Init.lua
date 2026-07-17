-- SPDX-License-Identifier: Unlicense

local Settings = Ext.Require("Server/Settings.lua")
local Diagnostics = Ext.Require("Server/Diagnostics.lua")
local RuntimeApi = Ext.Require("Server/RuntimeApi.lua")
local PartySkillResolver = Ext.Require("Server/PartySkillResolver.lua")
local LegacyAssistanceCleanup = Ext.Require("Server/LegacyAssistanceCleanup.lua")
local InteractionCoordinator = Ext.Require("Server/InteractionCoordinator.lua")

Ext.Vars.RegisterModVariable(Settings.MODULE_UUID, Settings.ACTIVE_ASSISTANCE_VAR, {
    Server = true,
    Persistent = true,
})

local diagnostics = Diagnostics.Create(Settings)
local api = RuntimeApi.Create(Settings, diagnostics)
local resolver = PartySkillResolver.Create(api, diagnostics)
-- Compatibility cleanup for older boost-based builds. Current rolls never add
-- a boost to the initiating character.
local legacyCleanup = LegacyAssistanceCleanup.Create(api, diagnostics)
local interaction = InteractionCoordinator.Create(Settings, api, resolver, diagnostics)

local function listen(name, arity, timing, handler)
    Ext.Osiris.RegisterListener(name, arity, timing, function(...)
        local ok, err = xpcall(handler, debug.traceback, ...)
        if not ok then
            diagnostics.Error("listener_failed", {
                event = name,
                error = err,
            })
        end
    end)
end

listen("RequestCanLockpick", 3, "before", function(character, item, requestId)
    diagnostics.Trace("request_can_lockpick", {
        actor = character,
        target = item,
        request_id = requestId,
    })
    interaction.OnNativeRequest("lockpick", character, item, requestId)
end)

listen("RequestCanDisarmTrap", 3, "before", function(character, item, requestId)
    diagnostics.Trace("request_can_disarm", {
        actor = character,
        target = item,
        request_id = requestId,
    })
    interaction.OnNativeRequest("disarm", character, item, requestId)
end)

listen("RequestCanUse", 3, "before", function(character, item, requestId)
    diagnostics.Trace("request_can_use", {
        actor = character,
        target = item,
        request_id = requestId,
    })
    -- A use attempt on a target with an in-flight delegated permission marks
    -- that delegation as contended so a concurrency-induced rejection can be
    -- re-driven instead of aborted.
    interaction.OnCompetingUse(item)
end)

listen("RequestProcessed", 3, "after", function(character, requestId, accepted)
    diagnostics.Trace("request_processed", {
        accepted = accepted,
        actor = character,
        request_id = requestId,
    })
    interaction.OnRequestProcessed(character, requestId, accepted)
end)

listen("StartedLockpicking", 2, "after", function(character, item)
    diagnostics.Trace("started_lockpicking", { actor = character, target = item })
    interaction.OnNativeStarted("lockpick", character, item)
end)

listen("StoppedLockpicking", 2, "after", function(character, item)
    diagnostics.Trace("stopped_lockpicking", { actor = character, target = item })
    interaction.OnNativeStopped("lockpick", character, item)
end)

listen("StartedDisarmingTrap", 2, "after", function(character, item)
    diagnostics.Trace("started_disarming", { actor = character, target = item })
    interaction.OnNativeStarted("disarm", character, item)
end)

listen("StoppedDisarmingTrap", 2, "after", function(character, item)
    diagnostics.Trace("stopped_disarming", { actor = character, target = item })
    interaction.OnNativeStopped("disarm", character, item)
end)

listen("RollResult", 6, "after", function(eventName, character, subject, result, isActive, criticality)
    diagnostics.Trace("roll_result", {
        actor = character,
        criticality = criticality,
        event_name = eventName,
        is_active = isActive,
        result = result,
        target = subject,
    })

    interaction.OnRollResult(eventName, character, subject, result)
end)

listen("EnteredForceTurnBased", 1, "after", function(object)
    interaction.OnEnteredForceTurnBased(object)
    diagnostics.Trace("entered_forced_turn_based", { actor = object })
end)

listen("LeftForceTurnBased", 1, "after", function(object)
    interaction.OnLeftForceTurnBased(object)
    diagnostics.Trace("left_forced_turn_based", { actor = object })
end)

listen("UseStarted", 2, "before", function(character, item)
    diagnostics.Trace("use_started", { actor = character, target = item })
end)

-- Capture the exact actor and locked target before vanilla's remaining
-- UseFinished handlers. The coordinator deliberately defers its permission
-- procedures until this callback stack has unwound.
listen("UseFinished", 3, "before", function(character, item, success)
    diagnostics.Trace("use_finished", {
        actor = character,
        target = item,
        success = success,
    })
    interaction.OnUseFinished(character, item, success)
end)

Ext.Events.SessionLoaded:Subscribe(function()
    legacyCleanup.RecoverPersisted()
    diagnostics.Info("loaded", {
        version = Settings.VERSION,
        game_version = api.GetGameVersion(),
        extender_version = api.GetExtenderVersion(),
    })
end)

Ext.Events.ResetCompleted:Subscribe(function()
    legacyCleanup.RecoverPersisted()
    diagnostics.Info("lua_reset_completed", {})
end)

Ext.RegisterConsoleCommand("best_of_hands_trace", function(_, value)
    diagnostics.SetTrace(value == "on" or value == "1" or value == "true")
end)

Ext.RegisterConsoleCommand("best_of_hands_status", function()
    diagnostics.Info("status", {
        legacy_assistance_cleanup = legacyCleanup.Count(),
        pending_delegations = interaction.Count(),
        trace = diagnostics.IsTraceEnabled(),
    })
end)

return {
    Diagnostics = diagnostics,
    Interaction = interaction,
    LegacyCleanup = legacyCleanup,
    Resolver = resolver,
}
