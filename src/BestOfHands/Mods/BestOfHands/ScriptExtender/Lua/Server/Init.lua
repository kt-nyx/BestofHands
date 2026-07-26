-- SPDX-License-Identifier: Unlicense

local Settings = Ext.Require("Server/Settings.lua")
local Diagnostics = Ext.Require("Server/Diagnostics.lua")
local NativeRuntimeApi = Ext.Require("Server/NativeRuntimeApi.lua")
local PartySkillResolver = Ext.Require("Server/PartySkillResolver.lua")
local LegacyAssistanceCleanup = Ext.Require("Server/LegacyAssistanceCleanup.lua")
local NativeBridge = Ext.Require("Server/NativeBridge.lua")
local NativeInteractionCoordinator = Ext.Require("Server/NativeInteractionCoordinator.lua")
local QuickLockpickCoordinator = Ext.Require("Server/QuickLockpickCoordinator.lua")
local Channels = Ext.Require("Shared/Channels.lua")

Ext.Vars.RegisterModVariable(Settings.MODULE_UUID, Settings.ACTIVE_ASSISTANCE_VAR, {
    Server = true,
    Persistent = true,
})

local diagnostics = Diagnostics.Create(Settings)
local api = NativeRuntimeApi.Create(Settings, diagnostics)
local resolver = PartySkillResolver.Create(api, diagnostics)
local legacyCleanup = LegacyAssistanceCleanup.Create(api, diagnostics)
local bridge = NativeBridge.Create(Settings, api, diagnostics)
local interaction = NativeInteractionCoordinator.Create(
    Settings,
    api,
    resolver,
    bridge,
    diagnostics
)
local quickLockpick = QuickLockpickCoordinator.Create(
    Settings,
    api,
    bridge,
    Channels.QuickLockpick,
    diagnostics
)
Channels.QuickLockpick:SetHandler(function(data, userId)
    local ok, errorMessage = xpcall(
        quickLockpick.OnClientMessage,
        debug.traceback,
        data,
        userId
    )
    if not ok then
        diagnostics.Error("quick_lockpick_client_reply_failed", {
            error = errorMessage,
            user_id = userId,
        })
    end
end)
local rollRouterAvailable = false

local function statusFields()
    local status = bridge.GetStatus()
    return {
        bridge_detail = status.detail,
        bridge_state = status.state,
        native_ready = status.ready and 1 or 0,
        native_session = status.nativeSession,
        pending_delegations = interaction.Count(),
        pending_quick_lockpicks = quickLockpick.Count(),
        roll_router = rollRouterAvailable and 1 or 0,
        version = Settings.VERSION,
    }
end

local function emitStatus(reason, extraFields)
    local fields = statusFields()
    fields.legacy_assistance_cleanup = legacyCleanup.Count()
    fields.reason = reason
    fields.trace = diagnostics.IsTraceEnabled()
    for key, value in pairs(extraFields or {}) do
        fields[key] = value
    end
    diagnostics.Info("status", fields)
end

-- Register recovery/diagnostic commands before any optional engine observer.
-- A future API mismatch must remain inspectable from the server console.
Ext.RegisterConsoleCommand("best_of_hands_trace", function(_, value)
    -- With no argument this command now means "enable", matching its normal
    -- development use. "off", "0", or "false" still disable explicitly.
    local enabled = value == nil
        or value == ""
        or value == "on"
        or value == "1"
        or value == "true"
    diagnostics.SetTrace(enabled)
    bridge.SetTrace(enabled)
    if enabled then
        local fields = statusFields()
        fields.extender_version = api.GetExtenderVersion()
        fields.game_version = api.GetGameVersion()
        fields.legacy_assistance_cleanup = legacyCleanup.Count()
        diagnostics.Info("trace_context", fields)
    end
end)

Ext.RegisterConsoleCommand("best_of_hands_status", function()
    emitStatus("console")
end)

local function listen(name, arity, timing, handler)
    Ext.Osiris.RegisterListener(name, arity, timing, function(...)
        local ok, errorMessage = xpcall(handler, debug.traceback, ...)
        if not ok then
            diagnostics.Error("listener_failed", {
                error = errorMessage,
                event = name,
            })
        end
    end)
end

listen("RequestCanLockpick", 3, "before", function(character, item, requestId)
    if diagnostics.IsTraceEnabled() then
        diagnostics.Trace("request_can_lockpick", {
            actor = character,
            request_id = requestId,
            target = item,
        })
    end
    quickLockpick.OnNativeRequest(character, item)
    interaction.OnNativeRequest("lockpick", character, item, requestId)
end)

listen("RequestCanDisarmTrap", 3, "before", function(character, item, requestId)
    if diagnostics.IsTraceEnabled() then
        diagnostics.Trace("request_can_disarm", {
            actor = character,
            request_id = requestId,
            target = item,
        })
    end
    interaction.OnNativeRequest("disarm", character, item, requestId)
end)

listen("RequestProcessed", 3, "after", function(character, requestId, result)
    if diagnostics.IsTraceEnabled() then
        diagnostics.Trace("request_processed", {
            actor = character,
            request_id = requestId,
            result = result,
        })
    end
end)

listen("StartedLockpicking", 2, "after", function(character, item)
    quickLockpick.OnNativeStarted(character, item)
    interaction.OnNativeStarted("lockpick", character, item)
end)

listen("StoppedLockpicking", 2, "after", function(character, item)
    quickLockpick.OnNativeStopped(character, item)
    interaction.OnNativeStopped("lockpick", character, item)
end)

listen("StartedDisarmingTrap", 2, "after", function(character, item)
    interaction.OnNativeStarted("disarm", character, item)
end)

listen("StoppedDisarmingTrap", 2, "after", function(character, item)
    interaction.OnNativeStopped("disarm", character, item)
end)

listen("UseFinished", 3, "before", function(character, item, success)
    if diagnostics.IsTraceEnabled() then
        diagnostics.Trace("use_finished", {
            actor = character,
            success = success,
            target = item,
        })
    end
    quickLockpick.OnUseFinished(character, item, success)
end)

listen("EnteredForceTurnBased", 1, "after", function(character)
    quickLockpick.OnEnteredForceTurnBased(character)
end)

listen("LeftForceTurnBased", 1, "after", function(character)
    quickLockpick.OnLeftForceTurnBased(character)
end)

listen("RollResult", 6, "after", function(eventName, character, subject, result, isActive, criticality)
    local handled = interaction.OnRollResult(
        eventName,
        character,
        subject,
        result,
        isActive,
        criticality
    )
    -- Left-click interception caches every locked target, including rolls for
    -- which the initiator is already the specialist and no delegation record
    -- is armed. Invalidate all authoritative lockpick successes rather than
    -- coupling cache cleanup to delegated-roll ownership.
    quickLockpick.OnRollResult(eventName, character, subject, result)
    if handled then
        if diagnostics.IsTraceEnabled() then
            -- The coordinator may schedule terminal cleanup on the next tick.
            -- Queue the diagnostic snapshot afterward so pending counts
            -- reflect post-roll state rather than callback-local state.
            api.Schedule(0, function()
                emitStatus("roll_result", {
                    criticality = criticality,
                    event_name = eventName,
                    is_active = isActive,
                    result = result,
                })
            end)
        end
    end
end)

rollRouterAvailable = interaction.Subscribe()

Ext.Events.SessionLoaded:Subscribe(function()
    legacyCleanup.RecoverPersisted()
    interaction.Clear("session_loaded")
    quickLockpick.Clear("session_loaded")
    bridge.BeginHandshake()
    diagnostics.Info("loaded", {
        extender_version = api.GetExtenderVersion(),
        game_version = api.GetGameVersion(),
        implementation = "native_local_profile_substitution",
        version = Settings.VERSION,
    })
    emitStatus("session_loaded")
end)

Ext.Events.ResetCompleted:Subscribe(function()
    legacyCleanup.RecoverPersisted()
    interaction.Clear("lua_reset")
    quickLockpick.Clear("lua_reset")
    bridge.BeginHandshake()
    diagnostics.Info("lua_reset_completed", {})
    emitStatus("lua_reset_completed")
end)

return {
    Bridge = bridge,
    Diagnostics = diagnostics,
    Interaction = interaction,
    LegacyCleanup = legacyCleanup,
    QuickLockpick = quickLockpick,
    Resolver = resolver,
}
