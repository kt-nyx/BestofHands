-- SPDX-License-Identifier: Unlicense

local luaRoot = BEST_OF_HANDS_ROOT .. "/src/BestOfHands/Mods/BestOfHands/ScriptExtender/Lua/Server/"
local PartySkillResolver = dofile(luaRoot .. "PartySkillResolver.lua")
local LegacyAssistanceCleanup = dofile(luaRoot .. "LegacyAssistanceCleanup.lua")
local NativeBridge = dofile(luaRoot .. "NativeBridge.lua")
local NativeInteractionCoordinator = dofile(luaRoot .. "NativeInteractionCoordinator.lua")
local NativeRuntimeApi = dofile(luaRoot .. "NativeRuntimeApi.lua")
local QuickLockpickCoordinator = dofile(
    luaRoot .. "QuickLockpickCoordinator.lua"
)
local NativePresentationBridge = dofile(
    BEST_OF_HANDS_ROOT
        .. "/src/BestOfHands/Mods/BestOfHands/ScriptExtender/Lua/Client/"
        .. "NativePresentationBridge.lua"
)

local passed = 0
local failed = 0

local function assertEqual(expected, actual, message)
    if expected ~= actual then
        error(string.format(
            "%s: expected %s, got %s",
            message,
            tostring(expected),
            tostring(actual)
        ), 2)
    end
end

local function assertContains(text, expected, message)
    if type(text) ~= "string" or not text:find(expected, 1, true) then
        error(string.format("%s: '%s' was not found", message, expected), 2)
    end
end

local function test(name, callback)
    local ok, errorMessage = xpcall(callback, debug.traceback)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. "\n" .. tostring(errorMessage))
    end
end

local function recordingDiagnostics(traceEnabled)
    local records = {}
    local instance = {}
    for _, level in ipairs({ "Info", "Warn", "Error", "Trace" }) do
        instance[level] = function(event, fields)
            records[#records + 1] = { event = event, fields = fields, level = level }
        end
    end
    instance.IsTraceEnabled = function() return traceEnabled ~= false end
    return instance, records
end

local function findRecord(records, event)
    for index = #records, 1, -1 do
        if records[index].event == event then
            return records[index]
        end
    end
    return nil
end

local function resolverApi(scores, overrides)
    overrides = overrides or {}
    return {
        CalculateSleightOfHand = function(character) return scores[character] end,
        GetPlayers = function() return overrides.players or { "actor", "best", "other" } end,
        GetRegion = function(character)
            return overrides.regions and overrides.regions[character] or "R"
        end,
        HasIneligibleStatus = function(character)
            return overrides.ineligible == character, "TEST"
        end,
        IsDead = function(character) return overrides.dead == character end,
        IsInPartyWith = function(character) return overrides.outside ~= character end,
        IsPartyMember = function(character) return overrides.inactive ~= character end,
        IsSummon = function(character) return overrides.summon == character end,
    }
end

test("resolver selects the highest eligible raw Sleight of Hand profile", function()
    local resolver = PartySkillResolver.Create(
        resolverApi({ actor = 1, best = 13, other = 4 }),
        recordingDiagnostics()
    )
    local result = resolver.Resolve("actor", "target", "lockpick", 7)
    assertEqual("best", result.specialist, "specialist")
    assertEqual(13, result.specialistScore, "specialist score")
    assertEqual(1, result.initiatorScore, "initiator score")
end)

test("resolver keeps the initiator on a tie", function()
    local resolver = PartySkillResolver.Create(
        resolverApi({ actor = 9, best = 9, other = 2 }),
        recordingDiagnostics()
    )
    assertEqual("actor", resolver.Resolve("actor", "target", "disarm", 2).specialist, "tie")
end)

test("resolver excludes unavailable party members", function()
    local api = resolverApi(
        { actor = 1, best = 20, other = 7 },
        { dead = "best" }
    )
    local resolver = PartySkillResolver.Create(api, recordingDiagnostics())
    assertEqual("other", resolver.Resolve("actor", "target", "lockpick", 3).specialist, "eligible")
end)

test("legacy boost cleanup retains only failed removals", function()
    local state = {
        one = { actor = "a", delta = 5, source = "s" },
        two = { actor = "b", delta = 2, source = "t" },
    }
    local saved = nil
    local cleanup = LegacyAssistanceCleanup.Create({
        LoadAssistanceState = function() return state end,
        RemoveSkillBoost = function(actor) return actor == "a" end,
        SaveAssistanceState = function(value) saved = value return true end,
    }, recordingDiagnostics())
    cleanup.RecoverPersisted()
    assertEqual(1, cleanup.Count(), "retained count")
    assertEqual(nil, saved.one, "removed record")
    assertEqual("b", saved.two.actor, "retained record")
end)

local function entity(guid, handle)
    return setmetatable({
        Uuid = { EntityUuid = guid },
        guid = guid,
        handle = handle,
    }, {
        __tostring = function(value) return "Entity (" .. value.handle .. ")" end,
    })
end

local actor = entity("00000000-0000-0000-0000-000000000001", "0200000100000001")
local specialist = entity("00000000-0000-0000-0000-000000000002", "0200000100000002")
local target = entity("00000000-0000-0000-0000-000000000003", "0200000100000003")

test("quick lockpick accepts one correlated native task request", function()
    local scheduled = {}
    local sent = {}
    local locked = true
    local bridgeReady = true
    local api = {
        GetEntityUuid = function(value) return value .. "-uuid" end,
        GetReservedUserId = function() return 65537 end,
        IsInCombat = function() return false end,
        IsLocked = function() return locked end,
        IsPlayer = function() return true end,
        MonotonicTime = function() return 25 end,
        Schedule = function(delay, callback)
            scheduled[#scheduled + 1] = {
                callback = callback,
                delay = delay,
            }
        end,
        SendQuickLockpick = function(_, payload, userId)
            sent[#sent + 1] = { payload = payload, userId = userId }
            return true
        end,
    }
    local coordinator = QuickLockpickCoordinator.Create(
        { QUICK_LOCKPICK_TIMEOUT_MS = 5000 },
        api,
        { IsReady = function() return bridgeReady end },
        {},
        recordingDiagnostics()
    )

    assertEqual(true,
        coordinator.OnUseFinished("actor", "target", 0),
        "failed locked use accepted")
    assertEqual(false,
        coordinator.OnUseFinished("actor", "target", 0),
        "duplicate use coalesced")
    assertEqual(1, coordinator.Count(), "one pending request")
    assertEqual(2, #scheduled, "dispatch and timeout scheduled")
    assertEqual(0, scheduled[1].delay, "dispatch is deferred one turn")
    scheduled[1].callback()
    assertEqual(1, #sent, "one task start sent")
    assertEqual("start", sent[1].payload.operation, "start operation")
    assertEqual("actor-uuid", sent[1].payload.actor, "initiator retained")
    assertEqual("target-uuid", sent[1].payload.target, "target retained")
    assertEqual(65537, sent[1].userId, "owning client selected")

    assertEqual(false,
        coordinator.OnClientMessage({
            operation = "queued",
            request = sent[1].payload.request,
        }, 1),
        "wrong client cannot acknowledge request")
    assertEqual(true,
        coordinator.OnClientMessage({
            operation = "queued",
            request = sent[1].payload.request,
        }, 65537),
        "owning client queue acknowledgement accepted")
    assertEqual(2, #scheduled, "queueing adds no server-side replay")
    assertEqual(false,
        coordinator.OnClientMessage({
            operation = "queued",
            request = sent[1].payload.request,
        }, 65537),
        "duplicate acknowledgement is ignored")

    assertEqual(true,
        coordinator.OnNativeRequest("actor", "target"),
        "native request acknowledges adapter")
    assertEqual(0, coordinator.Count(), "pending request cleared")
    assertEqual(2, #sent, "client cleanup sent after native request")
    assertEqual("cancel", sent[2].payload.operation, "cleanup operation")

    assertEqual(false,
        coordinator.OnUseFinished("actor", "target", 1),
        "successful key or use path remains vanilla")
    bridgeReady = false
    assertEqual(false,
        coordinator.OnUseFinished("actor", "target", 0),
        "missing native bridge is a no-op")
    bridgeReady = true
    locked = false
    assertEqual(false,
        coordinator.OnUseFinished("actor", "target", 0),
        "unlocked failed use is not converted")
    assertEqual(true,
        coordinator.OnLockpickSucceeded("actor", "target"),
        "successful lockpick invalidates the owning client's target cache")
    assertEqual(3, #sent, "one target invalidation sent")
    assertEqual("invalidate", sent[3].payload.operation,
        "target invalidation operation")
    assertEqual("actor-uuid", sent[3].payload.actor,
        "target invalidation retains the initiator")
    assertEqual("target-uuid", sent[3].payload.target,
        "target invalidation retains the unlocked target")
end)

test("quick lockpick respects combat, forced turn-based, timeout, and reset", function()
    local scheduled = {}
    local sent = {}
    local inCombat = true
    local api = {
        GetEntityUuid = function(value) return value .. "-uuid" end,
        GetReservedUserId = function() return 65537 end,
        IsInCombat = function() return inCombat end,
        IsLocked = function() return true end,
        IsPlayer = function() return true end,
        MonotonicTime = function() return 30 end,
        Schedule = function(delay, callback)
            scheduled[#scheduled + 1] = {
                callback = callback,
                delay = delay,
            }
        end,
        SendQuickLockpick = function(_, payload)
            sent[#sent + 1] = payload
            return true
        end,
    }
    local coordinator = QuickLockpickCoordinator.Create(
        { QUICK_LOCKPICK_TIMEOUT_MS = 5000 },
        api,
        { IsReady = function() return true end },
        {},
        recordingDiagnostics()
    )
    assertEqual(false,
        coordinator.OnUseFinished("actor", "target", 0),
        "combat blocks quick entry")
    inCombat = false
    coordinator.OnEnteredForceTurnBased("actor")
    assertEqual(false,
        coordinator.OnUseFinished("actor", "target", 0),
        "forced turn-based blocks quick entry")
    coordinator.OnLeftForceTurnBased("actor")
    assertEqual(true,
        coordinator.OnUseFinished("actor", "target", 0),
        "entry resumes after forced turn-based")
    scheduled[1].callback()
    scheduled[2].callback()
    assertEqual(0, coordinator.Count(), "timeout clears request")
    assertEqual("cancel", sent[#sent].operation, "timeout cancels client request")

    assertEqual(true,
        coordinator.OnUseFinished("actor", "other", 0),
        "second target accepted")
    coordinator.Clear("test")
    assertEqual(0, coordinator.Count(), "reset clears all requests")
    assertEqual("cancel", sent[#sent].operation, "reset cancels client request")
end)

test("quick lockpick fallback does not replay a native context-menu interaction", function()
    local now = 1000
    local scheduled = {}
    local api = {
        GetEntityUuid = function(value) return value .. "-uuid" end,
        GetReservedUserId = function() return 65537 end,
        IsInCombat = function() return false end,
        IsLocked = function() return true end,
        IsPlayer = function() return true end,
        MonotonicTime = function() return now end,
        Schedule = function(delay, callback)
            scheduled[#scheduled + 1] = {
                callback = callback,
                delay = delay,
            }
        end,
        SendQuickLockpick = function() return true end,
    }
    local coordinator = QuickLockpickCoordinator.Create({
        QUICK_LOCKPICK_NATIVE_SUPPRESSION_MS = 2000,
        QUICK_LOCKPICK_TIMEOUT_MS = 5000,
    }, api, {
        IsReady = function() return true end,
    }, {}, recordingDiagnostics())

    assertEqual(false,
        coordinator.OnNativeRequest("actor", "target"),
        "ordinary context-menu request has no fallback to acknowledge")
    coordinator.OnNativeStarted("actor", "target")
    assertEqual(false,
        coordinator.OnUseFinished("actor", "target", 0),
        "active native interaction suppresses failed-Use fallback")
    coordinator.OnNativeStopped("actor", "target")
    assertEqual(1, #scheduled,
        "native stop schedules bounded lifecycle cleanup")
    assertEqual(2000, scheduled[1].delay,
        "native suppression state uses the configured grace period")
    now = 2500
    assertEqual(false,
        coordinator.OnUseFinished("actor", "target", 0),
        "native completion grace suppresses its failed Use event")

    coordinator.OnNativeStopped("actor", "target")
    assertEqual(2, #scheduled,
        "a repeated stop refreshes the suppression lifetime")
    now = 3001
    scheduled[1].callback()
    assertEqual(false,
        coordinator.OnUseFinished("actor", "target", 0),
        "an older cleanup cannot erase a newer suppression window")
    now = 4501
    scheduled[2].callback()
    assertEqual(true,
        coordinator.OnUseFinished("actor", "target", 0),
        "expired native lifecycle state is removed")
    assertEqual(1, coordinator.Count(), "new fallback is queued once")
end)

test("quick lockpick validates route identity and client replies", function()
    local scheduled = {}
    local sent = {}
    local isPlayer = false
    local actorUuid = "actor-uuid"
    local targetUuid = "target-uuid"
    local userId = 65537
    local api = {
        GetEntityUuid = function(value)
            if value == "actor" then
                return actorUuid
            end
            return targetUuid
        end,
        GetReservedUserId = function() return userId end,
        IsInCombat = function() return false end,
        IsLocked = function() return true end,
        IsPlayer = function() return isPlayer end,
        MonotonicTime = function() return 100 end,
        Schedule = function(delay, callback)
            scheduled[#scheduled + 1] = {
                callback = callback,
                delay = delay,
            }
        end,
        SendQuickLockpick = function(_, payload, recipient)
            sent[#sent + 1] = {
                payload = payload,
                userId = recipient,
            }
            return true
        end,
    }
    local coordinator = QuickLockpickCoordinator.Create({
        QUICK_LOCKPICK_TIMEOUT_MS = 5000,
    }, api, {
        IsReady = function() return true end,
    }, {}, recordingDiagnostics())

    assertEqual(false,
        coordinator.OnUseFinished("actor", "target", 0),
        "non-player failed Use is ignored")
    assertEqual(0, #scheduled, "non-player schedules nothing")

    isPlayer = true
    actorUuid = nil
    assertEqual(false,
        coordinator.OnUseFinished("actor", "target", 0),
        "missing actor UUID is rejected")
    userId = nil
    actorUuid = "actor-uuid"
    assertEqual(false,
        coordinator.OnUseFinished("actor", "target", 0),
        "missing owning user is rejected")
    userId = 65537
    targetUuid = nil
    assertEqual(false,
        coordinator.OnUseFinished("actor", "target", 0),
        "missing target UUID is rejected")

    targetUuid = "target-uuid"
    assertEqual(true,
        coordinator.OnUseFinished("actor", "target", 0),
        "valid route is accepted")
    scheduled[1].callback()
    local request = sent[1].payload.request
    assertEqual(false,
        coordinator.OnClientMessage(nil, 65537),
        "nil client reply is ignored")
    assertEqual(false,
        coordinator.OnClientMessage({}, 65537),
        "reply without request is ignored")
    assertEqual(false,
        coordinator.OnClientMessage({
            operation = "queued",
            request = "unknown",
        }, 65537),
        "unknown request is ignored")
    assertEqual(false,
        coordinator.OnClientMessage({
            operation = "unknown",
            request = request,
        }, 65537),
        "unknown operation is ignored")
    assertEqual(false,
        coordinator.OnClientMessage({
            operation = "rejected",
            request = request,
        }, 1),
        "wrong client cannot reject a request")
    assertEqual(true,
        coordinator.OnClientMessage({
            operation = "rejected",
            reason = "test_rejection",
            request = request,
        }, 65537),
        "owning client rejection clears the request")
    assertEqual(0, coordinator.Count(), "rejected request is removed")
    assertEqual("cancel", sent[#sent].payload.operation,
        "client rejection is acknowledged with cleanup")
end)

test("quick lockpick deferred failures and stale timers are harmless", function()
    local now = 100
    local locked = true
    local scheduled = {}
    local sent = {}
    local failStarts = false
    local api = {
        GetEntityUuid = function(value) return value .. "-uuid" end,
        GetReservedUserId = function() return 65537 end,
        IsInCombat = function() return false end,
        IsLocked = function() return locked end,
        IsPlayer = function() return true end,
        MonotonicTime = function() return now end,
        Schedule = function(delay, callback)
            scheduled[#scheduled + 1] = {
                callback = callback,
                delay = delay,
            }
        end,
        SendQuickLockpick = function(_, payload)
            sent[#sent + 1] = payload
            return not (failStarts and payload.operation == "start")
        end,
    }
    local coordinator = QuickLockpickCoordinator.Create({
        QUICK_LOCKPICK_NATIVE_SUPPRESSION_MS = 10,
        QUICK_LOCKPICK_TIMEOUT_MS = 5000,
    }, api, {
        IsReady = function() return true end,
    }, {}, recordingDiagnostics())

    assertEqual(true,
        coordinator.OnUseFinished("actor", "target", 0),
        "first fallback is accepted")
    locked = false
    scheduled[1].callback()
    assertEqual(0, coordinator.Count(),
        "changed lock state cancels before client dispatch")
    assertEqual("cancel", sent[#sent].operation,
        "changed conditions remove any client state")
    scheduled[2].callback()
    assertEqual(1, #sent, "stale timeout cannot send duplicate cleanup")

    locked = true
    failStarts = true
    assertEqual(true,
        coordinator.OnUseFinished("actor", "target", 0),
        "second fallback is accepted")
    scheduled[3].callback()
    assertEqual(0, coordinator.Count(),
        "failed client transport clears the pending request")
    assertEqual("start", sent[#sent - 1].operation,
        "failed start was attempted once")
    assertEqual("cancel", sent[#sent].operation,
        "failed start receives cleanup")

    failStarts = false
    assertEqual(true,
        coordinator.OnUseFinished("actor", "target", 0),
        "third fallback is accepted")
    local thirdDispatch = scheduled[5]
    local thirdTimeout = scheduled[6]
    thirdDispatch.callback()
    assertEqual(true,
        coordinator.OnNativeRequest("actor", "target"),
        "native request consumes the third fallback")
    coordinator.OnNativeStopped("actor", "target")
    now = 111
    assertEqual(true,
        coordinator.OnUseFinished("actor", "target", 0),
        "replacement fallback is accepted after suppression grace")
    assertEqual(1, coordinator.Count(), "replacement is pending")
    thirdTimeout.callback()
    assertEqual(1, coordinator.Count(),
        "stale timeout cannot clear a replacement record")
end)

test("quick lockpick keeps simultaneous actor-target requests isolated", function()
    local scheduled = {}
    local sent = {}
    local api = {
        GetEntityUuid = function(value) return value .. "-uuid" end,
        GetReservedUserId = function(actor)
            return actor == "actor-a" and 10 or 20
        end,
        IsInCombat = function() return false end,
        IsLocked = function() return true end,
        IsPlayer = function() return true end,
        MonotonicTime = function() return 200 end,
        Schedule = function(delay, callback)
            scheduled[#scheduled + 1] = {
                callback = callback,
                delay = delay,
            }
        end,
        SendQuickLockpick = function(_, payload, userId)
            sent[#sent + 1] = {
                payload = payload,
                userId = userId,
            }
            return true
        end,
    }
    local coordinator = QuickLockpickCoordinator.Create({
        QUICK_LOCKPICK_TIMEOUT_MS = 5000,
    }, api, {
        IsReady = function() return true end,
    }, {}, recordingDiagnostics())

    assertEqual(true,
        coordinator.OnUseFinished("actor-a", "target-a", 0),
        "first actor-target accepted")
    assertEqual(true,
        coordinator.OnUseFinished("actor-b", "target-b", 0),
        "second actor-target accepted")
    assertEqual(true,
        coordinator.OnUseFinished("actor-a", "target-b", 0),
        "same actor on another target is independent")
    assertEqual(3, coordinator.Count(), "three independent requests pending")
    scheduled[1].callback()
    scheduled[3].callback()
    scheduled[5].callback()
    assertEqual(3, #sent, "each request starts exactly once")
    assertEqual(false,
        sent[1].payload.request == sent[2].payload.request,
        "same-tick requests receive distinct correlation IDs")
    assertEqual(false,
        sent[2].payload.request == sent[3].payload.request,
        "request sequence remains unique for every target")
    assertEqual(10, sent[1].userId, "first request routed to actor A client")
    assertEqual(20, sent[2].userId, "second request routed to actor B client")
    assertEqual(10, sent[3].userId, "third request routed to actor A client")

    assertEqual(true,
        coordinator.OnNativeRequest("actor-b", "target-b"),
        "one native request clears only its exact pending route")
    assertEqual(2, coordinator.Count(), "two unrelated requests remain")
    coordinator.Clear("test")
    assertEqual(0, coordinator.Count(), "reset clears every remaining request")
    local cancellations = 0
    for _, message in ipairs(sent) do
        if message.payload.operation == "cancel" then
            cancellations = cancellations + 1
        end
    end
    assertEqual(3, cancellations,
        "consumed and reset requests each receive one cleanup")
    local sentAfterReset = #sent
    scheduled[2].callback()
    scheduled[4].callback()
    scheduled[6].callback()
    assertEqual(sentAfterReset, #sent,
        "stale timeouts after reset cannot send more cleanup")
end)

test("quick lockpick invalidation fails closed when routing is unavailable", function()
    local userId = nil
    local sendResult = false
    local sent = 0
    local api = {
        GetEntityUuid = function(value) return value .. "-uuid" end,
        GetReservedUserId = function() return userId end,
        SendQuickLockpick = function()
            sent = sent + 1
            return sendResult
        end,
    }
    local coordinator = QuickLockpickCoordinator.Create({}, api, {}, {},
        recordingDiagnostics())

    assertEqual(false,
        coordinator.OnLockpickSucceeded("actor", "target"),
        "missing owning user prevents invalidation")
    assertEqual(0, sent, "unrouteable invalidation is not sent")
    userId = 65537
    assertEqual(false,
        coordinator.OnLockpickSucceeded("actor", "target"),
        "transport failure is reported")
    assertEqual(1, sent, "failed invalidation is attempted once")
    sendResult = true
    assertEqual(true,
        coordinator.OnLockpickSucceeded("actor", "target"),
        "valid invalidation succeeds")
    assertEqual(2, sent, "successful invalidation is sent once")
    assertEqual(false,
        coordinator.OnRollResult(
            "GAMEPLAY_DisarmingTrap", "actor", "target", 1),
        "trap success cannot invalidate the lockpick cache")
    assertEqual(false,
        coordinator.OnRollResult(
            "GAMEPLAY_LockPicking", "actor", "target", 0),
        "lockpick failure cannot invalidate the target")
    assertEqual(true,
        coordinator.OnRollResult(
            "GAMEPLAY_LockPicking", "actor", "target", "1"),
        "all authoritative lockpick successes invalidate the target")
    assertEqual(3, sent,
        "result routing adds exactly one successful invalidation")
end)

local function installEntityMock()
    local entities = {
        actor = actor,
        best = specialist,
        target = target,
        [actor] = actor,
        [specialist] = specialist,
        [target] = target,
    }
    Ext = Ext or {}
    Ext.Entity = Ext.Entity or {}
    Ext.Entity.Get = function(value)
        return entities[value] or (type(value) == "table" and value or nil)
    end
end

test("native bridge requires a live matching challenge acknowledgement", function()
    installEntityMock()
    local files = {}
    local loads = {}
    local saves = {}
    local scheduled = {}
    local warnings = 0
    Ext.IO = {
        LoadFile = function(path)
            loads[path] = (loads[path] or 0) + 1
            return files[path]
        end,
        SaveFile = function(path, value)
            saves[path] = (saves[path] or 0) + 1
            files[path] = value
            return true
        end,
    }
    Ext.Utils = { MonotonicTime = function() return 42 end }
    Osi = {
        GetHostCharacter = function() return "actor" end,
        OpenMessageBox = function() warnings = warnings + 1 end,
    }
    local api = {
        Schedule = function(_, callback) scheduled[#scheduled + 1] = callback end,
    }
    local settings = {
        NATIVE_HANDSHAKE_ATTEMPTS = 2,
        NATIVE_HANDSHAKE_POLL_MS = 1,
        TRACE_EVENTS = false,
        VERSION = "2.0.0",
    }
    local bridge = NativeBridge.Create(settings, api, recordingDiagnostics())
    bridge.BeginHandshake()
    assertEqual(false, bridge.IsReady(), "not ready before ack")
    local probe = files["BestOfHandsNative.actions"]:match("probe=([^\r\n]+)")
    files["BestOfHandsNative.status"] = table.concat({
        "protocol=7",
        "version=2.0.0",
        "state=ready",
        "session=123-456",
        "pid=123",
        "hooks=" .. NativeBridge.REQUIRED_HOOKS,
        "features=" .. NativeBridge.REQUIRED_FEATURES,
        "ack=" .. probe,
        "detail=ok",
        "end=1",
        "",
    }, "\n")
    scheduled[1]()
    assertEqual(true, bridge.IsReady(), "ready after ack")
    assertContains(files["BestOfHandsNative.actions"], "native_session=123-456", "session echoed")
    local written, reason = bridge.Upsert({
        action = "lockpick",
        id = 9,
        initiator = "actor",
        specialist = "best",
        target = "target",
    })
    assertEqual(true, written, reason or "record written")
    assertContains(files["BestOfHandsNative.actions"],
        "record=9\tlockpick\t0200000100000001\t0200000100000002\t0200000100000003\t0\t0",
        "native action record")
    local roll = entity("00000000-0000-0000-0000-000000000009", "0200000200000009")
    local correlated, correlationReason = bridge.SetRoll(
        9,
        roll,
        "00000000-0000-0000-0000-000000000009"
    )
    assertEqual(true, correlated, correlationReason or "roll correlated")
    assertContains(files["BestOfHandsNative.actions"],
        "record=9\tlockpick\t0200000100000001\t0200000100000002\t0200000100000003\t0200000200000009\t0",
        "correlated roll record")
    local loadsAfterRoll = loads["BestOfHandsNative.status"]
    local savesAfterRoll = saves["BestOfHandsNative.actions"]
    local duplicateRoll, duplicateRollReason = bridge.SetRoll(
        9,
        roll,
        "00000000-0000-0000-0000-000000000009"
    )
    assertEqual(true, duplicateRoll, duplicateRollReason or "duplicate roll accepted")
    assertEqual(loadsAfterRoll, loads["BestOfHandsNative.status"],
        "unchanged roll correlation does not reread native status")
    assertEqual(savesAfterRoll, saves["BestOfHandsNative.actions"],
        "unchanged roll correlation does not rewrite actions")
    local finished = entity("00000000-0000-0000-0000-000000000010", "0200000200000010")
    local finishedCorrelated, finishedReason = bridge.SetFinishedEvent(9, finished)
    assertEqual(true, finishedCorrelated, finishedReason or "finished event correlated")
    assertContains(files["BestOfHandsNative.actions"],
        "record=9\tlockpick\t0200000100000001\t0200000100000002\t0200000100000003\t0200000200000009\t0200000200000010",
        "correlated finished-event record")
    local presentationWritten, presentationReason = bridge.SetPresentation(9, 1)
    assertEqual(true, presentationWritten, presentationReason or "presentation written")
    assertContains(
        files["BestOfHandsNative.actions"],
        "\t00000000-0000-0000-0000-000000000009"
            .. "\t00000000-0000-0000-0000-000000000001"
            .. "\t00000000-0000-0000-0000-000000000002"
            .. "\t00000000-0000-0000-0000-000000000003\t1",
        "stable client correlation and presentation state"
    )
    local loadsAfterPresentation = loads["BestOfHandsNative.status"]
    local savesAfterPresentation = saves["BestOfHandsNative.actions"]
    local duplicatePresentation, duplicatePresentationReason =
        bridge.SetPresentation(9, 1)
    assertEqual(true, duplicatePresentation,
        duplicatePresentationReason or "duplicate presentation accepted")
    assertEqual(loadsAfterPresentation, loads["BestOfHandsNative.status"],
        "unchanged presentation does not reread native status")
    assertEqual(savesAfterPresentation, saves["BestOfHandsNative.actions"],
        "unchanged presentation does not rewrite actions")
    local invalidPresentation, invalidPresentationReason =
        bridge.SetPresentation(9, 3)
    assertEqual(false, invalidPresentation, "invalid presentation rejected")
    assertEqual("presentation_advantage_invalid", invalidPresentationReason,
        "invalid presentation reason")
    assertEqual(loadsAfterPresentation, loads["BestOfHandsNative.status"],
        "invalid presentation does not reread native status")
    assertEqual(savesAfterPresentation, saves["BestOfHandsNative.actions"],
        "invalid presentation does not rewrite actions")
    local changedPresentation, changedPresentationReason =
        bridge.SetPresentation(9, 2)
    assertEqual(true, changedPresentation,
        changedPresentationReason or "changed presentation accepted")
    assertEqual(loadsAfterPresentation + 1, loads["BestOfHandsNative.status"],
        "changed presentation revalidates native status exactly once")
    assertEqual(savesAfterPresentation + 1, saves["BestOfHandsNative.actions"],
        "changed presentation rewrites actions exactly once")
    assertContains(files["BestOfHandsNative.actions"], "\t2\nend=1",
        "changed presentation is published")
    assertEqual(0, warnings, "no warning")
end)

test("production handshake omits the retired observation-only hook", function()
    assertEqual(nil,
        NativeBridge.REQUIRED_HOOKS:find(
            "client_roll_bonus_preserve_selected", 1, true),
        "trace-only selected-modifier hook is not installed in production")
end)

test("native bridge fails closed and warns once when the DLL is unavailable", function()
    installEntityMock()
    local files = {}
    local scheduled = {}
    local warnings = 0
    Ext.IO = {
        LoadFile = function(path) return files[path] end,
        SaveFile = function(path, value) files[path] = value return true end,
    }
    Ext.Utils = { MonotonicTime = function() return 99 end }
    Osi = {
        GetHostCharacter = function() return "actor" end,
        OpenMessageBox = function() warnings = warnings + 1 end,
    }
    local bridge = NativeBridge.Create({
        NATIVE_HANDSHAKE_ATTEMPTS = 1,
        NATIVE_HANDSHAKE_POLL_MS = 1,
        TRACE_EVENTS = false,
        VERSION = "2.0.0",
    }, {
        Schedule = function(_, callback) scheduled[#scheduled + 1] = callback end,
    }, recordingDiagnostics())
    bridge.BeginHandshake()
    scheduled[1]()
    assertEqual(false, bridge.IsReady(), "bridge disabled")
    assertEqual(1, warnings, "one warning")
end)

test("native bridge disables delegation if the acknowledged native session is lost", function()
    installEntityMock()
    local files = {}
    local scheduled = {}
    local warnings = 0
    Ext.IO = {
        LoadFile = function(path) return files[path] end,
        SaveFile = function(path, value) files[path] = value return true end,
    }
    Ext.Utils = {}
    Osi = {
        GetHostCharacter = function() return "actor" end,
        OpenMessageBox = function() warnings = warnings + 1 end,
    }
    local bridge = NativeBridge.Create({
        NATIVE_HANDSHAKE_ATTEMPTS = 1,
        NATIVE_HANDSHAKE_POLL_MS = 1,
        TRACE_EVENTS = false,
        VERSION = "2.0.0",
    }, {
        Schedule = function(_, callback) scheduled[#scheduled + 1] = callback end,
    }, recordingDiagnostics())
    bridge.BeginHandshake()
    local probe = files["BestOfHandsNative.actions"]:match("probe=([^\r\n]+)")
    files["BestOfHandsNative.status"] = table.concat({
        "protocol=7", "version=2.0.0", "state=ready", "session=session-a",
        "pid=10", "hooks=" .. NativeBridge.REQUIRED_HOOKS,
        "features=" .. NativeBridge.REQUIRED_FEATURES,
        "ack=" .. probe, "detail=ok", "end=1", "",
    }, "\n")
    scheduled[1]()
    assertEqual(true, bridge.IsReady(), "initially ready")
    files["BestOfHandsNative.status"] = table.concat({
        "protocol=7", "version=2.0.0", "state=waiting_for_server", "session=session-a",
        "pid=10", "hooks=none", "ack=" .. probe, "detail=world changed", "end=1", "",
    }, "\n")
    local written, reason = bridge.Upsert({
        action = "disarm", id = 3, initiator = "actor", specialist = "best", target = "target",
    })
    assertEqual(false, written, "record rejected")
    assertEqual("native_bridge_not_ready", reason, "lost bridge reason")
    assertEqual(false, bridge.IsReady(), "bridge disabled")
    assertEqual(1, warnings, "visible warning")
end)

test("client bridge correlates delegated rolls by stable UUID and publishes client handles", function()
    local clientActor = entity(actor.guid, "01c0000100000001")
    local clientSpecialist = entity(specialist.guid, "01c0000100000002")
    local clientTarget = entity(target.guid, "01c0000100000003")
    local clientRoll = entity(
        "00000000-0000-0000-0000-000000000004",
        "01c0000200000004"
    )
    local entities = {
        [clientActor] = clientActor,
        [clientSpecialist] = clientSpecialist,
        [clientTarget] = clientTarget,
        [clientRoll] = clientRoll,
        [actor.guid] = clientActor,
        [specialist.guid] = clientSpecialist,
        [target.guid] = clientTarget,
    }
    local callbacks = {}
    local entityGets = 0
    local printCalls = 0
    local saveCalls = 0
    local files = {
        ["BestOfHandsNative.actions"] = table.concat({
            "protocol=7",
            "pak_version=2.0.0",
            "probe=test",
            "native_session=44-55",
            "trace=0",
            "record=7\tdisarm\t0200000100000001\t0200000100000002"
                .. "\t0200000100000003\t0200000200000004\t0"
                .. "\t00000000-0000-0000-0000-000000000004"
                .. "\t" .. actor.guid
                .. "\t" .. specialist.guid
                .. "\t" .. target.guid
                .. "\t1",
            "end=1",
            "",
        }, "\n"),
    }
    Ext = {
        Entity = {
            Get = function(value)
                entityGets = entityGets + 1
                return entities[value] or (type(value) == "table" and value or nil)
            end,
            OnCreate = function(componentName, callback)
                callbacks[componentName .. "Create"] = callback
                return 1
            end,
            OnChange = function(componentName, callback)
                callbacks[componentName .. "Change"] = callback
                return 2
            end,
            OnDestroy = function(componentName, callback)
                callbacks[componentName .. "Destroy"] = callback
                return 3
            end,
        },
        IO = {
            LoadFile = function(path) return files[path] end,
            SaveFile = function(path, value)
                saveCalls = saveCalls + 1
                files[path] = value
                return true
            end,
        },
        Timer = { WaitFor = function() end },
        Utils = { Print = function() printCalls = printCalls + 1 end },
    }
    local bridge = NativePresentationBridge.Start({
        TRACE_EVENTS = false,
        VERSION = "2.0.0",
    })
    local component = {
        RollContext = 5,
        Roller = clientActor,
        RollUuid = clientRoll.guid,
        Subject = clientTarget,
        AdvantageType = "None",
    }
    clientRoll.RequestedRoll = component
    callbacks.RequestedRollCreate(clientRoll, nil, component)
    local record = bridge.GetRecord(clientRoll, component)
    assertEqual("delegated", record.profileMode, "delegated client classification")
    assertEqual(clientSpecialist.handle, record.specialistHandle, "client specialist mapped")
    assertEqual(1, record.presentationAdvantage, "specialist advantage retained for diagnostics")
    assertEqual("None", component.AdvantageType, "client roll component remains untouched")
    assertEqual(1, saveCalls, "initial mapping written exactly once")
    local entityGetsBeforeChanges = entityGets
    for _ = 1, 100 do
        callbacks.RequestedRollChange(clientRoll)
    end
    assertEqual(1, saveCalls, "stable roll changes do not rewrite the client bridge")
    assertEqual(100, entityGets - entityGetsBeforeChanges,
        "stable roll changes only resolve the changed roll entity")
    assertEqual(0, printCalls, "trace-disabled client bridge emits no diagnostics")
    files["BestOfHandsNative.actions"] = files["BestOfHandsNative.actions"]:gsub(
        "\t1\nend=1",
        "\t2\nend=1"
    )
    bridge.RefreshRecord(record)
    assertEqual(2, record.presentationAdvantage, "presentation state refreshes after modifier observation")
    assertContains(
        files["BestOfHandsNative.client"],
        "record=7\t" .. clientRoll.guid
            .. "\t" .. clientActor.handle
            .. "\t" .. clientSpecialist.handle
            .. "\t" .. clientTarget.handle,
        "client bridge record"
    )
    callbacks.RequestedRollDestroy(clientRoll, nil, component)
    assertEqual(nil,
        files["BestOfHandsNative.client"]:find("record=7", 1, true),
        "destroyed client mapping removed")
    assertEqual(2, saveCalls, "destroyed mapping written exactly once")
end)

test("client bridge prepares and queues BG3's stock lockpick task", function()
    local actorGuid = "10000000-0000-0000-0000-000000000001"
    local targetGuid = "10000000-0000-0000-0000-000000000002"
    local actorEntity = entity(actorGuid, "01c0000100000101")
    local targetEntity = entity(targetGuid, "01c0000100000102")
    local targetHandle = setmetatable({
        GetNetId = function() return 77 end,
    }, {
        __tostring = function() return "ComponentHandle (01c0000100000102)" end,
    })
    local task = setmetatable({ TaskType = "Lockpick" }, {
        __tostring = function() return "EclCharacterTaskLockpick (000001d000002000)" end,
    })
    local controller = setmetatable({ Tasks = { task } }, {
        __tostring = function() return "EclInputController (000001d000001000)" end,
    })
    actorEntity.ClientCharacter = { InputController = controller }
    local entities = {
        [actorGuid] = actorEntity,
        [targetGuid] = targetEntity,
        [actorEntity] = actorEntity,
        [targetEntity] = targetEntity,
        [targetHandle] = targetEntity,
    }
    local files = {
        ["BestOfHandsNative.actions"] = table.concat({
            "protocol=7",
            "pak_version=2.0.0",
            "probe=test",
            "native_session=44-55",
            "trace=0",
            "end=1",
            "",
        }, "\n"),
    }
    local handler = nil
    local serverMessages = {}
    Ext = {
        Entity = {
            Get = function(value) return entities[value] end,
            UuidToHandle = function(value)
                return value == targetGuid and targetHandle or nil
            end,
            OnCreate = function() return 1 end,
            OnChange = function() return 2 end,
            OnDestroy = function() return 3 end,
        },
        IO = {
            LoadFile = function(path) return files[path] end,
            SaveFile = function(path, value)
                files[path] = value
                return true
            end,
        },
        Utils = { Print = function() end },
    }
    local channel = {
        SetHandler = function(_, callback) handler = callback end,
        SendToServer = function(_, payload)
            serverMessages[#serverMessages + 1] = payload
        end,
    }
    NativePresentationBridge.Start({
        TRACE_EVENTS = false,
        VERSION = "2.0.0",
    }, channel)
    assertEqual("function", type(handler), "quick-lockpick client handler registered")
    handler({
        actor = actorGuid,
        operation = "start",
        request = "42-0-1",
        target = targetGuid,
    })
    assertEqual(nil, task.Item, "Lua does not write the stock task target")
    assertEqual(nil, task.ItemNetId, "Lua does not write the stock task net id")
    assertEqual(nil, controller.RunningTask,
        "Lua does not bypass the native controller lifecycle")
    assertEqual(nil, controller.IsNewTaskStarted,
        "Lua does not forge the controller new-task flag")
    assertEqual(1, #serverMessages, "queued task acknowledged once")
    assertEqual("queued", serverMessages[1].operation,
        "queue acknowledgement operation")
    assertEqual("42-0-1", serverMessages[1].request,
        "prepared acknowledgement request")
    assertContains(
        files["BestOfHandsNative.client"],
        "quick=42-0-1\t" .. actorEntity.handle
            .. "\t" .. targetEntity.handle .. "\t77",
        "validated native activation request"
    )
    handler({
        actor = actorGuid,
        operation = "start",
        request = "42-0-1",
        target = targetGuid,
    })
    assertEqual(1, #serverMessages,
        "duplicate start does not acknowledge or queue twice")
    handler({ operation = "cancel", request = "unknown" })
    assertContains(
        files["BestOfHandsNative.client"],
        "quick=42-0-1",
        "unknown cancellation cannot remove another request"
    )
    handler({ operation = "cancel", request = "42-0-1" })
    assertEqual(
        nil,
        (files["BestOfHandsNative.client"] or ""):find("quick=", 1, true),
        "cancel removes the native bridge request"
    )
end)

test("client bridge rejects malformed or unpublishable fallback requests", function()
    local actorGuid = "11000000-0000-0000-0000-000000000001"
    local targetGuid = "11000000-0000-0000-0000-000000000002"
    local actorEntity = entity(actorGuid, "01c0000100000111")
    local targetEntity = entity(targetGuid, "01c0000100000112")
    local targetNetId = 99
    targetEntity.GetNetId = function()
        if targetNetId == "throw" then
            error("simulated network ID failure")
        end
        return targetNetId
    end
    local entities = {
        [actorGuid] = actorEntity,
        [targetGuid] = targetEntity,
        [actorEntity] = actorEntity,
        [targetEntity] = targetEntity,
    }
    local files = {
        ["BestOfHandsNative.actions"] = table.concat({
            "protocol=7",
            "pak_version=2.0.0",
            "probe=test",
            "native_session=44-55",
            "trace=0",
            "end=1",
            "",
        }, "\n"),
    }
    local handler = nil
    local failSave = false
    local failAcknowledgement = false
    local messages = {}
    Ext = {
        Entity = {
            Get = function(value) return entities[value] end,
            UuidToHandle = function(value)
                return value == targetGuid and targetEntity or nil
            end,
            OnCreate = function() end,
            OnChange = function() end,
            OnDestroy = function() end,
        },
        IO = {
            LoadFile = function(path) return files[path] end,
            SaveFile = function(path, value)
                if failSave then
                    return false
                end
                files[path] = value
                return true
            end,
        },
        Utils = { Print = function() end },
    }
    local channel = {
        SetHandler = function(_, callback) handler = callback end,
        SendToServer = function(_, payload)
            if failAcknowledgement then
                error("simulated channel failure")
            end
            messages[#messages + 1] = payload
        end,
    }
    NativePresentationBridge.Start({
        TRACE_EVENTS = false,
        VERSION = "2.0.0",
    }, channel)

    local function start(request, actor, targetValue)
        handler({
            actor = actor,
            operation = "start",
            request = request,
            target = targetValue,
        })
        return messages[#messages]
    end

    assertEqual("rejected",
        start("unsafe|request", actorGuid, targetGuid).operation,
        "unsafe request token is rejected")
    assertEqual("rejected",
        start("missing-actor", "not-a-guid", targetGuid).operation,
        "malformed actor UUID is rejected")
    assertEqual("rejected",
        start("missing-target", actorGuid, "not-a-guid").operation,
        "malformed target UUID is rejected")
    assertEqual("rejected",
        start("unknown-actor",
            "11000000-0000-0000-0000-000000000099",
            targetGuid).operation,
        "unreplicated actor is rejected")
    assertEqual("rejected",
        start("unknown-target", actorGuid,
            "11000000-0000-0000-0000-000000000099").operation,
        "unreplicated target is rejected")

    targetNetId = nil
    assertEqual("rejected",
        start("missing-net-id", actorGuid, targetGuid).operation,
        "target without a network ID is rejected")
    targetNetId = 0
    assertEqual("rejected",
        start("zero-net-id", actorGuid, targetGuid).operation,
        "zero target network ID is rejected")
    targetNetId = "not-a-number"
    assertEqual("rejected",
        start("invalid-net-id", actorGuid, targetGuid).operation,
        "non-numeric target network ID is rejected")
    targetNetId = "throw"
    local messagesBeforeNetIdError = #messages
    handler({
        actor = actorGuid,
        operation = "start",
        request = "throwing-net-id",
        target = targetGuid,
    })
    assertEqual(messagesBeforeNetIdError + 1, #messages,
        "network ID read failure sends a rejection")
    assertEqual("rejected", messages[#messages].operation,
        "network ID read exception fails closed")
    targetNetId = 99
    failSave = true
    assertEqual("rejected",
        start("write-failure", actorGuid, targetGuid).operation,
        "native request publication failure is rejected")
    failSave = false
    failAcknowledgement = true
    local before = #messages
    handler({
        actor = actorGuid,
        operation = "start",
        request = "ack-failure",
        target = targetGuid,
    })
    assertEqual(before, #messages,
        "throwing channel cannot publish acknowledgement or rejection")
    assertEqual(nil,
        (files["BestOfHandsNative.client"] or ""):find(
            "quick=ack-failure", 1, true),
        "failed acknowledgement removes the published native request")
end)

test("client bridge publishes pre-use left-click interception state", function()
    local actorEntity = entity(
        "20000000-0000-0000-0000-000000000001",
        "01c0000100000201"
    )
    local targetEntity = entity(
        "20000000-0000-0000-0000-000000000002",
        "01c0000100000202"
    )
    local keyEntity = entity(
        "20000000-0000-0000-0000-000000000003",
        "01c0000100000203"
    )
    local task = setmetatable({ TaskType = "Lockpick" }, {
        __tostring = function()
            return "EclCharacterTaskLockpick (000001d000004000)"
        end,
    })
    local controller = setmetatable({ Tasks = { task } }, {
        __tostring = function()
            return "EclInputController (000001d000003000)"
        end,
    })
    actorEntity.ClientCharacter = { InputController = controller }
    targetEntity.Lock = { Key_M = "TEST_KEY" }
    targetEntity.GetNetId = function() return 88 end
    keyEntity.Key = { Key = "TEST_KEY" }
    keyEntity.InventoryTopOwner = { TopOwner = actorEntity }

    local componentEntities = {
        ClientControl = { actorEntity },
        Key = { keyEntity },
        Lock = { targetEntity },
    }
    local callbacks = {}
    local nextTicks = {}
    local files = {
        ["BestOfHandsNative.actions"] = table.concat({
            "protocol=7",
            "pak_version=2.0.0",
            "probe=test",
            "native_session=44-55",
            "trace=0",
            "end=1",
            "",
        }, "\n"),
    }
    local handler = nil
    Ext = {
        Entity = {
            Get = function(value) return value end,
            UuidToHandle = function(value)
                return value == targetEntity.guid and targetEntity or nil
            end,
            GetAllEntitiesWithComponent = function(component)
                return componentEntities[component] or {}
            end,
            OnCreate = function(component, callback)
                callbacks[component .. "Create"] = callback
            end,
            OnChange = function(component, callback)
                callbacks[component .. "Change"] = callback
            end,
            OnDestroy = function(component, callback)
                callbacks[component .. "Destroy"] = callback
            end,
        },
        Events = {
            SessionLoaded = { Subscribe = function() end },
            ResetCompleted = { Subscribe = function() end },
        },
        IO = {
            LoadFile = function(path) return files[path] end,
            SaveFile = function(path, value)
                files[path] = value
                return true
            end,
        },
        OnNextTick = function(callback)
            nextTicks[#nextTicks + 1] = callback
        end,
        Utils = { Print = function() end },
    }

    local channel = {
        SetHandler = function(_, callback) handler = callback end,
        SendToServer = function() return true end,
    }
    NativePresentationBridge.Start({
        TRACE_EVENTS = false,
        VERSION = "2.0.0",
    }, channel)
    table.remove(nextTicks, 1)()
    assertContains(
        files["BestOfHandsNative.leftclick"],
        "eligible=" .. actorEntity.handle .. "\t1",
        "eligible initiator snapshot"
    )
    assertEqual(nil,
        files["BestOfHandsNative.leftclick"]:find("locked=", 1, true),
        "matching party key preserves vanilla use")

    componentEntities.Key = {}
    callbacks.KeyDestroy()
    table.remove(nextTicks, 1)()
    assertContains(
        files["BestOfHandsNative.leftclick"],
        "locked=" .. targetEntity.handle .. "\t88",
        "keyless locked target snapshot"
    )

    handler({
        actor = actorEntity.guid,
        operation = "invalidate",
        target = targetEntity.guid,
    })
    assertEqual(nil,
        files["BestOfHandsNative.leftclick"]:find(
            "locked=" .. targetEntity.handle, 1, true),
        "successful lockpick removes the stale replicated lock immediately")
    callbacks.LockChange(targetEntity)
    table.remove(nextTicks, 1)()
    assertEqual(nil,
        files["BestOfHandsNative.leftclick"]:find(
            "locked=" .. targetEntity.handle, 1, true),
        "stale Lock changes cannot re-add an authoritatively unlocked target")
    callbacks.LockCreate(targetEntity)
    table.remove(nextTicks, 1)()
    assertContains(
        files["BestOfHandsNative.leftclick"],
        "locked=" .. targetEntity.handle .. "\t88",
        "a future Lock creation permits a genuinely relocked target")

    actorEntity.IsInCombat = {}
    callbacks.IsInCombatCreate()
    table.remove(nextTicks, 1)()
    assertContains(
        files["BestOfHandsNative.leftclick"],
        "eligible=" .. actorEntity.handle .. "\t0",
        "combat disables pre-use interception"
    )
end)

test("client left-click snapshot isolates actors, keys, targets, and sessions", function()
    local actorA = entity(
        "21000000-0000-0000-0000-000000000001",
        "01c0000100000211"
    )
    local actorB = entity(
        "21000000-0000-0000-0000-000000000002",
        "01c0000100000212"
    )
    local outsider = entity(
        "21000000-0000-0000-0000-000000000099",
        "01c0000100000299"
    )
    local keyedTarget = entity(
        "21000000-0000-0000-0000-000000000011",
        "01c0000100000311"
    )
    local freeTarget = entity(
        "21000000-0000-0000-0000-000000000012",
        "01c0000100000312"
    )
    local invalidTarget = entity(
        "21000000-0000-0000-0000-000000000013",
        "01c0000100000313"
    )
    local keyEntity = entity(
        "21000000-0000-0000-0000-000000000021",
        "01c0000100000411"
    )
    actorB.IsInTurnBasedMode = {}
    keyedTarget.Lock = { Key_M = "KEYED_TARGET" }
    freeTarget.Lock = { Key_M = "" }
    invalidTarget.Lock = { Key_M = "" }
    keyedTarget.GetNetId = function() return 111 end
    freeTarget.GetNetId = function() return 112 end
    invalidTarget.GetNetId = function() return 0 end
    keyEntity.Key = { Key = "KEYED_TARGET" }
    keyEntity.InventoryTopOwner = { TopOwner = outsider }

    local componentEntities = {
        ClientControl = { actorA, actorB },
        Key = { keyEntity },
        Lock = { keyedTarget, freeTarget, invalidTarget },
    }
    local byGuid = {
        [keyedTarget.guid] = keyedTarget,
        [freeTarget.guid] = freeTarget,
        [invalidTarget.guid] = invalidTarget,
    }
    local callbacks = {}
    local nextTicks = {}
    local timers = {}
    local files = {}
    local handler = nil
    local failSnapshotSave = false
    local snapshotSaveCount = 0
    local function actions(session)
        return table.concat({
            "protocol=7",
            "pak_version=2.0.0",
            "probe=test",
            "native_session=" .. session,
            "trace=0",
            "end=1",
            "",
        }, "\n")
    end
    files["BestOfHandsNative.actions"] = actions("session-a")
    Ext = {
        Entity = {
            Get = function(value) return value end,
            UuidToHandle = function(value) return byGuid[value] end,
            GetAllEntitiesWithComponent = function(component)
                return componentEntities[component] or {}
            end,
            OnCreate = function(component, callback)
                callbacks[component .. "Create"] = callback
            end,
            OnChange = function(component, callback)
                callbacks[component .. "Change"] = callback
            end,
            OnDestroy = function(component, callback)
                callbacks[component .. "Destroy"] = callback
            end,
        },
        Events = {
            SessionLoaded = { Subscribe = function() end },
            ResetCompleted = { Subscribe = function() end },
        },
        IO = {
            LoadFile = function(path) return files[path] end,
            SaveFile = function(path, value)
                if path == "BestOfHandsNative.leftclick"
                    and failSnapshotSave then
                    return false
                end
                if path == "BestOfHandsNative.leftclick" then
                    snapshotSaveCount = snapshotSaveCount + 1
                end
                files[path] = value
                return true
            end,
        },
        OnNextTick = function(callback)
            nextTicks[#nextTicks + 1] = callback
        end,
        Timer = {
            WaitFor = function(delay, callback)
                timers[#timers + 1] = {
                    callback = callback,
                    delay = delay,
                }
            end,
        },
        Utils = { Print = function() end },
    }
    local channel = {
        SetHandler = function(_, callback) handler = callback end,
        SendToServer = function() return true end,
    }
    NativePresentationBridge.Start({
        TRACE_EVENTS = false,
        VERSION = "2.0.0",
    }, channel)

    local function flush()
        local callback = table.remove(nextTicks, 1)
        assertEqual("function", type(callback), "snapshot refresh scheduled")
        callback()
    end
    local function snapshot()
        return files["BestOfHandsNative.leftclick"] or ""
    end

    flush()
    assertContains(snapshot(),
        "eligible=" .. actorA.handle .. "\t1",
        "ordinary controlled actor is eligible")
    assertContains(snapshot(),
        "eligible=" .. actorB.handle .. "\t0",
        "turn-based actor is ineligible")
    assertContains(snapshot(),
        "locked=" .. keyedTarget.handle .. "\t111",
        "key owned outside the controlled party does not suppress lockpicking")
    assertContains(snapshot(),
        "locked=" .. freeTarget.handle .. "\t112",
        "keyless lock is published")
    assertEqual(nil,
        snapshot():find("locked=" .. invalidTarget.handle, 1, true),
        "invalid network ID is excluded")

    keyEntity.InventoryTopOwner.TopOwner = actorA
    callbacks.InventoryTopOwnerChange(keyEntity)
    flush()
    assertEqual(nil,
        snapshot():find("locked=" .. keyedTarget.handle, 1, true),
        "matching controlled-party key restores vanilla key use")
    assertContains(snapshot(),
        "locked=" .. freeTarget.handle .. "\t112",
        "unrelated keyless target remains eligible")

    actorB.IsInTurnBasedMode = nil
    callbacks.IsInTurnBasedModeDestroy(actorB)
    flush()
    assertContains(snapshot(),
        "eligible=" .. actorB.handle .. "\t1",
        "leaving turn-based mode restores eligibility")

    callbacks.LockChange(freeTarget)
    callbacks.LockChange(freeTarget)
    callbacks.KeyChange(keyEntity)
    assertEqual(1, #nextTicks,
        "multiple component changes coalesce into one snapshot refresh")
    local savesBeforeUnchangedRefresh = snapshotSaveCount
    flush()
    assertEqual(savesBeforeUnchangedRefresh, snapshotSaveCount,
        "unchanged snapshot does not rewrite the bridge file")

    handler({
        actor = actorA.guid,
        operation = "invalidate",
        target = freeTarget.guid,
    })
    assertEqual(nil,
        snapshot():find("locked=" .. freeTarget.handle, 1, true),
        "target invalidation removes only the unlocked target")
    callbacks.LockChange(freeTarget)
    flush()
    assertEqual(nil,
        snapshot():find("locked=" .. freeTarget.handle, 1, true),
        "late changes cannot revive the invalidated target")
    callbacks.LockCreate(keyedTarget)
    flush()
    assertEqual(nil,
        snapshot():find("locked=" .. freeTarget.handle, 1, true),
        "another target's Lock creation cannot clear the tombstone")
    callbacks.LockCreate(freeTarget)
    flush()
    assertContains(snapshot(),
        "locked=" .. freeTarget.handle .. "\t112",
        "matching Lock creation permits genuine relocking")

    byGuid[freeTarget.guid] = nil
    handler({
        actor = actorA.guid,
        operation = "invalidate",
        target = freeTarget.guid,
    })
    assertEqual(nil,
        snapshot():find("locked=" .. freeTarget.handle, 1, true),
        "UUID invalidation remains immediate if handle lookup is unavailable")
    byGuid[freeTarget.guid] = freeTarget
    callbacks.LockCreate(freeTarget)
    flush()

    failSnapshotSave = true
    handler({
        actor = actorA.guid,
        operation = "invalidate",
        target = freeTarget.guid,
    })
    handler({
        actor = actorA.guid,
        operation = "invalidate",
        target = freeTarget.guid,
    })
    assertEqual(1, #nextTicks,
        "repeated failed invalidations coalesce into one snapshot refresh")
    flush()
    assertEqual(1, #timers,
        "continued invalidation write failure enters bounded backoff")
    failSnapshotSave = false
    table.remove(timers, 1).callback()
    assertEqual(nil,
        snapshot():find("locked=" .. freeTarget.handle, 1, true),
        "invalidation retry removes the target without another component event")

    files["BestOfHandsNative.actions"] = actions("session-b")
    callbacks.ClientControlChange(actorA)
    flush()
    assertContains(snapshot(),
        "locked=" .. freeTarget.handle .. "\t112",
        "new native session cannot inherit stale target tombstones")

    files["BestOfHandsNative.actions"] = nil
    callbacks.KeyChange(keyEntity)
    flush()
    assertEqual(0, #nextTicks,
        "failed refresh does not spin on every client tick")
    assertEqual(1, #timers,
        "unavailable handshake schedules one bounded retry")
    assertEqual(250, timers[1].delay,
        "handshake retry uses the configured backoff")
    files["BestOfHandsNative.actions"] = actions("session-c")
    table.remove(timers, 1).callback()
    assertContains(snapshot(), "native_session=session-c",
        "retry publishes the recovered native session")

    local beforeInvalidMessage = snapshot()
    handler({
        operation = "invalidate",
        target = "not-a-guid",
    })
    assertEqual(beforeInvalidMessage, snapshot(),
        "malformed invalidation cannot alter the target snapshot")

    failSnapshotSave = true
    actorA.IsInCombat = {}
    callbacks.IsInCombatCreate(actorA)
    flush()
    assertEqual(1, #timers,
        "snapshot write failure schedules one bounded retry")
    failSnapshotSave = false
    table.remove(timers, 1).callback()
    assertContains(snapshot(), "native_session=session-c",
        "snapshot write retry recovers without another component event")
end)

test("runtime tool precheck uses BG3 party inventory without consuming anything", function()
    local queried = {}
    local responses = {}
    local errors = {}
    Osi = {
        DB_CustomDisarmTrapResponse = function(character, target, result)
            responses[#responses + 1] = {
                action = "disarm",
                character = character,
                result = result,
                target = target,
            }
        end,
        DB_CustomLockpickItemResponse = function(character, target, result)
            responses[#responses + 1] = {
                action = "lockpick",
                character = character,
                result = result,
                target = target,
            }
        end,
        GetInventoryOwner = function() return "tool-owner" end,
        GetItemByTemplateInPartyInventory = function(template, character)
            queried[#queried + 1] = { template = template, character = character }
            if template == "opened-tools" then
                return "tool-item"
            end
            return nil
        end,
        ShowError = function(character, key)
            errors[#errors + 1] = { character = character, key = key }
        end,
    }
    local api = NativeRuntimeApi.Create({
        MISSING_TOOL_ERROR_KEY = "CannotUse",
        VANILLA_THIEVES_TOOLS_TEMPLATES = { "closed-tools", "opened-tools" },
        VANILLA_TRAP_DISARM_TOOL_TEMPLATES = { "disarm-kit" },
    }, recordingDiagnostics())
    local tool = api.FindNativeActionTool("lockpick", "actor")
    assertEqual("tool-item", tool.item, "party tool")
    assertEqual("tool-owner", tool.owner, "native inventory owner")
    assertEqual("opened-tools", tool.template, "matching template")
    assertEqual(2, #queried, "template fallbacks checked")
    assertEqual("actor", queried[1].character, "initiator anchors magic pockets")
    assertEqual(nil, api.FindNativeActionTool("disarm", "actor"), "missing kit")
    local rejected, notified =
        api.RejectNativeActionWithoutTool("lockpick", "actor", "target")
    assertEqual(true, rejected, "lockpick request rejected")
    assertEqual(true, notified, "native error notification shown")
    assertEqual("lockpick", responses[1].action, "lockpick response database")
    assertEqual(0, responses[1].result, "lockpick rejection result")
    assertEqual("CannotUse", errors[1].key, "known native error key")
    api.RejectNativeActionWithoutTool("disarm", "actor", "trap")
    assertEqual("disarm", responses[2].action, "disarm response database")
    assertEqual(0, responses[2].result, "disarm rejection result")
end)

local function makeCoordinator(options)
    options = options or {}
    installEntityMock()
    local removed = {}
    local rollCorrelations = {}
    local presentationStates = {}
    local rejections = {}
    local upserts = {}
    local bridge = {
        IsReady = function() return true end,
        Remove = function(id) removed[#removed + 1] = id return true end,
        SetRoll = function(id, roll)
            rollCorrelations[#rollCorrelations + 1] = { id = id, roll = roll }
            return true, nil, tostring(roll):match("Entity %((%x+)%)")
        end,
        SetFinishedEvent = function(_, eventEntity)
            return true, nil, tostring(eventEntity):match("Entity %((%x+)%)")
        end,
        SetPresentation = function(id, advantageType)
            presentationStates[#presentationStates + 1] = {
                id = id,
                advantageType = advantageType,
            }
            return true, nil
        end,
        Upsert = function(record)
            upserts[#upserts + 1] = record
            return true, nil, {
                initiatorHandle = actor.handle,
                specialistHandle = specialist.handle,
                targetHandle = target.handle,
            }
        end,
    }
    local resolver = {
        Resolve = function(initiator, targetValue, action, requestId)
            return {
                action = action,
                initiator = initiator,
                initiatorScore = 0,
                requestId = requestId,
                specialist = options.initiatorIsSpecialist and initiator or "best",
                specialistScore = options.initiatorIsSpecialist and 0 or 13,
                target = targetValue,
            }
        end,
    }
    local timers = {}
    local diagnostics, records = recordingDiagnostics(options.trace)
    local coordinator = NativeInteractionCoordinator.Create({
        NATIVE_ACTION_TIMEOUT_MS = 100,
    }, {
        FindNativeActionTool = function(action)
            if options.noTool then
                return nil
            end
            return {
                item = action .. "-tool",
                owner = "actor",
                template = action .. "-template",
            }
        end,
        RejectNativeActionWithoutTool = function(action, character, targetValue)
            rejections[#rejections + 1] = {
                action = action,
                character = character,
                target = targetValue,
            }
            return true, true
        end,
        Schedule = function(_, callback) timers[#timers + 1] = callback end,
    }, resolver, bridge, diagnostics)
    return coordinator, bridge, upserts, removed, records, rollCorrelations, timers,
        presentationStates, rejections
end

test("both actions use the same native delegation path without blocking vanilla", function()
    local coordinator, _, upserts = makeCoordinator()
    assertEqual(false, coordinator.OnNativeRequest("lockpick", "actor", "target", 4), "lockpick observation")
    assertEqual("lockpick", upserts[1].action, "lockpick action")
    coordinator.Clear("test")
    assertEqual(false, coordinator.OnNativeRequest("disarm", "actor", "target", 5), "disarm observation")
    assertEqual("disarm", upserts[2].action, "disarm action")
end)

test("missing tools reject both native actions before a roll can open", function()
    local coordinator, _, upserts, removed, records, _, _, _, rejections =
        makeCoordinator({ noTool = true })
    assertEqual(false, coordinator.OnNativeRequest("disarm", "actor", "target", 18),
        "observer publishes rejection")
    assertEqual(0, #upserts, "no native profile mapping")
    assertEqual(0, #removed, "nothing to remove")
    assertEqual(0, coordinator.Count(), "no pending delegation")
    assertEqual(1, #rejections, "one custom response")
    assertEqual("disarm", rejections[1].action, "disarm response")
    local skipped = findRecord(records, "native_tool_unavailable_rejected")
    assertEqual(
        1,
        skipped.fields.response_published,
        "no-tool response published"
    )
    assertEqual(1, skipped.fields.notification_shown, "native notification shown")
end)

test("requested roll is correlated without Lua changing ownership", function()
    local coordinator, _, _, removed, records, rollCorrelations, _, presentationStates =
        makeCoordinator()
    coordinator.OnNativeRequest("disarm", "actor", "target", 6)
    local rollEntity = entity(
        "00000000-0000-0000-0000-000000000005",
        "0200000200000005"
    )
    local component = {
        Entity2Uuid = "",
        EntityUuid = "",
        FixedRollBonuses = {},
        ResolvedRollBonuses = {},
        RollUuid = "00000000-0000-0000-0000-000000000004",
        Roller = actor,
        Subject = target,
    }
    rollEntity.RequestedRoll = component
    assertEqual(true, coordinator.OnRequestedRoll(rollEntity, component), "routed")
    assertEqual(actor, component.Roller, "Lua does not substitute the roller")
    assertEqual(rollEntity, rollCorrelations[1].roll, "roll entity published to native bridge")
    assertEqual(true, coordinator.OnRollModifiers(rollEntity, {
        ConsumableModifiers = {},
        DynamicModifiers = {},
        DynamicModifiers2 = {},
        DynamicModifiers3 = {},
        ItemSpellModifiers = {},
        SpellModifiers = {},
        StaticModifiers = {},
        ToggledPassiveModifiers = {},
    }), "modifier observation routed")
    assertEqual(actor, component.Roller, "profile substitution never changes ownership")
    assertEqual(0, presentationStates[1].advantageType, "neutral presentation published")
    assertEqual(0, #removed, "record remains until native result or timeout")
    local observed = findRecord(records, "native_modifiers_observed")
    assertEqual(actor.guid, observed.fields.roll_actor_at_observer,
        "observer always sees initiator ownership")
    assertEqual(0, observed.fields.observed_during_native_call,
        "profile substitution is local rather than component-wide")
end)

test("specialist advantage state is published for client presentation", function()
    local coordinator, _, _, _, _, _, _, presentationStates = makeCoordinator()
    coordinator.OnNativeRequest("disarm", "actor", "target", 20)
    local rollEntity = entity(
        "00000000-0000-0000-0000-000000000026",
        "0200000200000026"
    )
    local requestedRoll = {
        FixedRollBonuses = {},
        ResolvedRollBonuses = {},
        RollUuid = "00000000-0000-0000-0000-000000000027",
        Roller = actor,
        Subject = target,
    }
    rollEntity.RequestedRoll = requestedRoll
    coordinator.OnRequestedRoll(rollEntity, requestedRoll)
    coordinator.OnRollModifiers(rollEntity, {
        StaticModifiers = {
            {
                Disabled = false,
                Modifier = { AdvantageType = "Advantage" },
            },
        },
    })
    assertEqual(1, presentationStates[1].advantageType, "advantage published")
    coordinator.OnRollModifiers(rollEntity, {
        StaticModifiers = {
            {
                Disabled = false,
                Modifier = { AdvantageType = "Advantage" },
            },
            {
                Disabled = false,
                Modifier = { AdvantageType = "Disadvantage" },
            },
        },
    }, "changed")
    assertEqual(0, presentationStates[2].advantageType, "opposed states cancel")
end)

test("trace suppression never stops functional presentation updates", function()
    local coordinator, _, _, _, records, _, _, presentationStates =
        makeCoordinator({ trace = false })
    coordinator.OnNativeRequest("disarm", "actor", "target", 21)
    local rollEntity = entity(
        "00000000-0000-0000-0000-000000000036",
        "0200000200000036"
    )
    local requestedRoll = {
        FixedRollBonuses = {},
        ResolvedRollBonuses = {},
        RollUuid = "00000000-0000-0000-0000-000000000037",
        Roller = actor,
        Subject = target,
    }
    rollEntity.RequestedRoll = requestedRoll
    coordinator.OnRequestedRoll(rollEntity, requestedRoll)
    for index = 1, 20 do
        coordinator.OnRollModifiers(rollEntity, {
            StaticModifiers = index == 20 and {
                {
                    Disabled = false,
                    Modifier = { AdvantageType = "Advantage" },
                },
            } or {},
        }, "changed")
    end
    assertEqual(20, #presentationStates,
        "all modifier changes reach the functional bridge")
    assertEqual(1, presentationStates[20].advantageType,
        "late advantage changes remain functional")
    assertEqual(nil, findRecord(records, "native_modifier_trace_suppressed"),
        "trace-disabled runs do not maintain suppression diagnostics")
end)

test("trace-enabled suppression remains observational after its limit", function()
    local coordinator, _, _, _, records, _, _, presentationStates =
        makeCoordinator({ trace = true })
    coordinator.OnNativeRequest("lockpick", "actor", "target", 22)
    local rollEntity = entity(
        "00000000-0000-0000-0000-000000000038",
        "0200000200000038"
    )
    local requestedRoll = {
        FixedRollBonuses = {},
        ResolvedRollBonuses = {},
        RollUuid = "00000000-0000-0000-0000-000000000039",
        Roller = actor,
        Subject = target,
    }
    rollEntity.RequestedRoll = requestedRoll
    coordinator.OnRequestedRoll(rollEntity, requestedRoll)
    for index = 1, 20 do
        coordinator.OnRollModifiers(rollEntity, {
            StaticModifiers = index == 20 and {
                {
                    Disabled = false,
                    Modifier = { AdvantageType = "Disadvantage" },
                },
            } or {},
        }, "changed")
    end
    assertEqual(20, #presentationStates,
        "trace limit never suppresses functional bridge updates")
    assertEqual(2, presentationStates[20].advantageType,
        "late disadvantage remains functional with tracing enabled")
    local suppressed = findRecord(records, "native_modifier_trace_suppressed")
    assertEqual("Trace", suppressed.level, "diagnostic suppression is reported")
    assertEqual(16, suppressed.fields.limit, "diagnostic limit")
end)

test("a specialist-owned requested roll is rejected without rewriting it", function()
    local coordinator, _, _, removed, records, rollCorrelations = makeCoordinator()
    coordinator.OnNativeRequest("lockpick", "actor", "target", 8)
    local rollEntity = entity(
        "00000000-0000-0000-0000-000000000008",
        "0200000200000008"
    )
    local component = {
        Entity2Uuid = "",
        EntityUuid = "",
        FixedRollBonuses = {},
        ResolvedRollBonuses = {},
        RollUuid = "00000000-0000-0000-0000-000000000007",
        Roller = specialist,
        Subject = target,
    }
    rollEntity.RequestedRoll = component
    assertEqual(false, coordinator.OnRequestedRoll(rollEntity, component), "roll rejected")
    assertEqual(specialist, component.Roller, "Lua never rewrites roll ownership")
    assertEqual(0, #rollCorrelations, "invalid ownership is not published")
    assertEqual(1, removed[#removed], "invalid native record removed")
    assertEqual("Error", findRecord(records, "native_roll_correlation_failed").level,
        "ownership violation diagnosed")
end)

test("action stop cannot discard a correlated roll before its native result", function()
    local coordinator, _, _, removed, _, _, timers = makeCoordinator()
    coordinator.OnNativeRequest("disarm", "actor", "target", 9)
    local rollEntity = entity(
        "00000000-0000-0000-0000-000000000010",
        "0200000200000010"
    )
    local component = {
        Entity2Uuid = "",
        EntityUuid = "",
        FixedRollBonuses = {},
        ResolvedRollBonuses = {},
        RollUuid = "00000000-0000-0000-0000-000000000011",
        Roller = actor,
        Subject = target,
    }
    rollEntity.RequestedRoll = component
    coordinator.OnRequestedRoll(rollEntity, component)
    coordinator.OnNativeStopped("disarm", "actor", "target")
    assertEqual(1, coordinator.Count(), "correlated roll retained after action stop")
    assertEqual(true,
        coordinator.OnRollResult("Disarm Trap", "actor", "target", 1, 1, 0),
        "delegated result reports that it was handled")
    timers[#timers]()
    assertEqual(0, coordinator.Count(), "record cleared after native result")
    assertEqual(1, removed[#removed], "native record removed during result cleanup")
end)

test("a failed roll remains mapped for native inspiration retry", function()
    local coordinator, _, _, removed, records, _, timers = makeCoordinator()
    coordinator.OnNativeRequest("disarm", "actor", "target", 10)
    local timerCountBeforeFailure = #timers
    coordinator.OnRollResult("Disarm Trap", "actor", "target", 0, 1, 0)
    assertEqual(1, coordinator.Count(), "failed roll retained")
    assertEqual(0, #removed, "native profile mapping remains available")
    assertEqual(timerCountBeforeFailure, #timers, "no immediate failure cleanup scheduled")
    assertEqual("Trace", findRecord(records, "native_delegation_retained_for_retry").level,
        "retry retention traced")
    coordinator.OnRollResult("Disarm Trap", "actor", "target", 1, 1, 0)
    timers[#timers]()
    assertEqual(0, coordinator.Count(), "successful retry clears mapping")
    assertEqual(1, removed[#removed], "successful retry removes native record")
end)

test("a canceled roll is terminal and clears its native mapping", function()
    local coordinator, _, _, removed, records, _, timers = makeCoordinator()
    coordinator.OnNativeRequest("disarm", "actor", "target", 11)
    local timerCountBeforeCancellation = #timers
    coordinator.OnRollResult("Disarm Trap", "actor", "target", 2, 1, 0)
    assertEqual(timerCountBeforeCancellation + 1, #timers, "cancellation cleanup scheduled")
    timers[#timers]()
    assertEqual(0, coordinator.Count(), "canceled roll cleared")
    assertEqual(1, removed[#removed], "canceled roll removes native record")
    assertEqual("native_roll_canceled",
        findRecord(records, "native_delegation_cleared").fields.reason,
        "cancellation reason traced")
    assertEqual(nil, findRecord(records, "native_delegation_retained_for_retry"),
        "cancellation is not misclassified as retryable")
end)

test("a RequestedRoll Canceled flag cannot tear down a retryable native mapping", function()
    local coordinator, _, _, removed, _, _, timers = makeCoordinator()
    coordinator.OnNativeRequest("lockpick", "actor", "target", 19)
    local rollEntity = entity(
        "00000000-0000-0000-0000-000000000025",
        "0200000200000025"
    )
    local requestedRoll = {
        Canceled = true,
        Entity2Uuid = "",
        EntityUuid = "",
        FixedRollBonuses = {},
        ResolvedRollBonuses = {},
        RollUuid = "00000000-0000-0000-0000-000000000026",
        Roller = actor,
        Subject = target,
    }
    rollEntity.RequestedRoll = requestedRoll
    coordinator.OnRequestedRoll(rollEntity, requestedRoll)
    local timerCount = #timers
    assertEqual(true,
        coordinator.OnRequestedRollChanged(rollEntity, requestedRoll, 1),
        "canceled-flag change observed")
    assertEqual(timerCount, #timers, "canceled flag schedules no cleanup")
    assertEqual(1, coordinator.Count(), "mapping remains available")
    assertEqual(0, #removed, "bridge mapping remains available")
end)

test("direct specialist rolls produce bounded vanilla reference comparison traces", function()
    local coordinator, _, upserts, removed, records, _, timers = makeCoordinator({
        initiatorIsSpecialist = true,
    })
    assertEqual(false,
        coordinator.OnNativeRequest("disarm", "actor", "target", 20),
        "direct specialist request remains vanilla")
    assertEqual(0, #upserts, "reference tracing creates no native mapping")
    local rollEntity = entity(
        "00000000-0000-0000-0000-000000000027",
        "0200000200000027"
    )
    local requestedRoll = {
        Entity2Uuid = "",
        EntityUuid = "",
        FixedRollBonuses = {},
        Metadata = {
            AbilityBoosts = { Dexterity = 5 },
            FixedRollBonuses = {},
            ProficiencyBonus = 4,
            ResolvedRollBonuses = {},
            RollBonus = 13,
            SkillBonuses = { SleightOfHand = 8 },
        },
        ResolvedRollBonuses = {},
        Roll = {
            Advantage = true,
            Disadvantage = false,
            RerollConditions = {},
            Roll = {
                AmountOfDices = 1,
                DiceAdditionalValue = 0,
                DiceNegative = false,
                DiceValue = "D20",
            },
        },
        RollUuid = "00000000-0000-0000-0000-000000000028",
        Roller = actor,
        Subject = target,
    }
    rollEntity.RequestedRoll = requestedRoll
    assertEqual(true, coordinator.OnRequestedRoll(rollEntity, requestedRoll),
        "reference roll correlated")
    assertEqual(true, coordinator.OnRollModifiers(rollEntity, {
        ConsumableModifiers = {},
        DynamicModifiers = {},
        DynamicModifiers2 = {},
        DynamicModifiers3 = {},
        ItemSpellModifiers = {},
        SpellModifiers = {},
        StaticModifiers = {},
        ToggledPassiveModifiers = {},
    }), "reference modifiers observed")
    local state = findRecord(records, "native_requested_roll_state")
    assertEqual("vanilla_reference", state.fields.profile_mode, "reference profile mode")
    assertEqual(13, state.fields.metadata_roll_bonus, "reference metadata captured")
    assertEqual(1, state.fields.roll_amount_of_dice, "reference die definition captured")
    assertEqual("reference-1", state.fields.comparison_id, "stable comparison id")
    assertEqual(0, #removed, "reference tracing never touches native bridge")
    assertEqual(1, #timers, "reference trace has only its bounded timeout")
end)

test("requested roll destruction remains mapped for post-roll result and retry UI", function()
    local coordinator, _, _, removed, records, _, timers = makeCoordinator()
    coordinator.OnNativeRequest("disarm", "actor", "target", 15)
    local rollEntity = entity(
        "00000000-0000-0000-0000-000000000018",
        "0200000200000018"
    )
    local requestedRoll = {
        Entity2Uuid = "",
        EntityUuid = "",
        FixedRollBonuses = {},
        ResolvedRollBonuses = {},
        RollUuid = "00000000-0000-0000-0000-000000000019",
        Roller = actor,
        Subject = target,
    }
    rollEntity.RequestedRoll = requestedRoll
    coordinator.OnRequestedRoll(rollEntity, requestedRoll)
    assertEqual(true, coordinator.OnRequestedRollDestroyed(rollEntity, requestedRoll),
        "destruction routed")
    assertEqual(1, coordinator.Count(), "destroyed roll remains correlated")
    assertEqual(0, #removed, "post-roll profile mapping remains available")
    assertEqual("destroyed",
        findRecord(records, "native_requested_roll_state").fields.stage,
        "destruction state traced")
    assertEqual("Trace",
        findRecord(records, "native_delegation_retained_after_roll_destroy").level,
        "post-roll retention traced")
    coordinator.OnRollResult("Disarm Trap", "actor", "target", 1, 1, 0)
    timers[#timers]()
    assertEqual(0, coordinator.Count(), "later success result clears mapping")
    assertEqual(1, removed[#removed], "later success removes native record")
end)

test("destruction of a superseded roll cannot clear its replacement", function()
    local coordinator, _, _, removed, _, _, timers = makeCoordinator()
    coordinator.OnNativeRequest("lockpick", "actor", "target", 16)
    local firstRoll = entity(
        "00000000-0000-0000-0000-000000000020",
        "0200000200000020"
    )
    local firstComponent = {
        Entity2Uuid = "",
        EntityUuid = "",
        FixedRollBonuses = {},
        ResolvedRollBonuses = {},
        RollUuid = "00000000-0000-0000-0000-000000000021",
        Roller = actor,
        Subject = target,
    }
    firstRoll.RequestedRoll = firstComponent
    coordinator.OnRequestedRoll(firstRoll, firstComponent)
    coordinator.OnRequestedRollDestroyed(firstRoll, firstComponent)

    local replacementRoll = entity(
        "00000000-0000-0000-0000-000000000022",
        "0200000200000022"
    )
    local replacementComponent = {
        Entity2Uuid = "",
        EntityUuid = "",
        FixedRollBonuses = {},
        ResolvedRollBonuses = {},
        RollUuid = "00000000-0000-0000-0000-000000000023",
        Roller = actor,
        Subject = target,
    }
    replacementRoll.RequestedRoll = replacementComponent
    coordinator.OnRequestedRoll(replacementRoll, replacementComponent)
    assertEqual(1, coordinator.Count(), "replacement mapping retained")
    assertEqual(0, #removed, "stale destruction does not remove replacement")
end)

test("a specialist-owned result is diagnosed and cannot clear an initiator-owned action", function()
    local coordinator, _, _, removed, records = makeCoordinator()
    coordinator.OnNativeRequest("disarm", "actor", "target", 13)
    coordinator.OnRollResult("Disarm Trap", "best", "target", 1, 1, 0)
    assertEqual(1, coordinator.Count(), "mismatched result remains pending")
    assertEqual(0, #removed, "mismatched result does not remove native record")
    local result = findRecord(records, "native_delegated_roll_result")
    assertEqual(0, result.fields.owner_matches_initiator, "result mismatch diagnosed")
    assertEqual("Error", result.level, "result mismatch elevated")
end)

test("post-restoration modifier observation does not rewrite or add a fallback", function()
    local coordinator, _, _, removed, records = makeCoordinator()
    coordinator.OnNativeRequest("lockpick", "actor", "target", 7)
    local component = {
        Entity2Uuid = "",
        EntityUuid = "",
        FixedRollBonuses = {},
        ResolvedRollBonuses = {},
        RollUuid = "00000000-0000-0000-0000-000000000004",
        Roller = actor,
        Subject = target,
    }
    actor.RequestedRoll = component
    assertEqual(true, coordinator.OnRequestedRoll(actor, component), "roll correlated")
    assertEqual(actor, component.Roller, "initiator remains untouched")
    assertEqual(true, coordinator.OnRollModifiers(actor, {}), "modifier observation routed")
    assertEqual(actor, component.Roller, "observer does not mutate restored ownership")
    assertEqual(0, #removed, "bridge record retained for native result")
    assertEqual(actor.guid,
        findRecord(records, "native_modifiers_observed").fields.roll_actor_at_observer,
        "post-restoration timing is explicitly traced")
end)

test("entity observers capture lifecycle, profile changes, and bonus spell requests", function()
    local coordinator, _, _, _, records = makeCoordinator()
    local registrations = {}
    Ext.Entity.OnCreate = function(componentName)
        registrations[componentName] = "create"
        return componentName .. "-create"
    end
    Ext.Entity.OnCreateDeferred = function(componentName)
        registrations[componentName] = "deferred"
        return componentName .. "-deferred"
    end
    Ext.Entity.OnChange = function(componentName)
        registrations[componentName .. "Change"] = "change"
        return componentName .. "-change"
    end
    Ext.Entity.OnDestroy = function(componentName)
        registrations[componentName .. "Destroy"] = "destroy"
        return componentName .. "-destroy"
    end

    assertEqual(true, coordinator.Subscribe(), "required observer surface")
    assertEqual("create", registrations.RequestedRoll, "requested roll observer")
    assertEqual("change", registrations.RequestedRollChange, "requested roll change observer")
    assertEqual("destroy", registrations.RequestedRollDestroy, "requested roll destroy observer")
    assertEqual("deferred", registrations.ServerRollFinishedEvent, "finished-event observer")
    assertEqual("create", registrations.RollModifiers, "modifier observer")
    assertEqual("change", registrations.RollModifiersChange, "modifier change observer")
    assertEqual("create", registrations.ServerRollStartSpellRequest,
        "bonus spell request observer")
    assertEqual(nil, findRecord(records, "entity_observer_registration_failed"), "registration errors")
end)

test("bonus spell requests report whether the initiator or specialist was targeted", function()
    local coordinator, _, _, _, records = makeCoordinator()
    coordinator.OnNativeRequest("disarm", "actor", "target", 17)
    local requestEntity = entity(
        "00000000-0000-0000-0000-000000000024",
        "0200000200000024"
    )
    assertEqual(true, coordinator.OnStartSpellRequest(requestEntity, {
        Caster = actor,
        Flags = 3,
        NetGUID = "bonus-request",
        Source = actor,
        Spell = "Target_Guidance",
        StoryActionId = 42,
        Targets = {
            { Target = specialist },
        },
    }), "bonus request correlated")
    local observed = findRecord(records, "native_roll_bonus_spell_request")
    assertEqual(0, observed.fields.target_matches_initiator, "initiator target flag")
    assertEqual(1, observed.fields.target_matches_specialist, "specialist target flag")
    assertEqual(1, observed.fields.target_count, "target count")
    assertEqual(0, observed.fields.targets_retargeted, "existing specialist target retained")
    assertEqual("Target_Guidance", observed.fields.spell, "spell traced")
end)

test("accepted initiator roll bonuses are retargeted to the specialist", function()
    local coordinator, _, _, _, records = makeCoordinator()
    coordinator.OnNativeRequest("disarm", "actor", "target", 19)
    local initialTarget = { Target = actor }
    assertEqual(true, coordinator.OnStartSpellRequest(entity(
        "00000000-0000-0000-0000-000000000025",
        "0200000200000025"
    ), {
        Caster = actor,
        Flags = 17284,
        NetGUID = "",
        Source = actor,
        Spell = "Target_Guidance",
        StoryActionId = 0,
        Targets = { initialTarget },
    }), "bonus request correlated")
    assertEqual(specialist, initialTarget.Target, "effect target rewritten")
    local observed = findRecord(records, "native_roll_bonus_retargeted")
    assertEqual(1, observed.fields.target_count, "one target rewritten")
    assertEqual("actor", observed.fields.original_target, "initiator eligibility target")
    assertEqual("best", observed.fields.specialist, "specialist effect target")
end)

test("initiator-owned finished events are observed without rewriting", function()
    local coordinator, _, _, _, records = makeCoordinator()
    coordinator.OnNativeRequest("disarm", "actor", "target", 12)
    local rollEntity = entity(
        "00000000-0000-0000-0000-000000000012",
        "0200000200000012"
    )
    local requestedRoll = {
        Entity2Uuid = "",
        EntityUuid = "",
        FixedRollBonuses = {},
        ResolvedRollBonuses = {},
        RollUuid = "00000000-0000-0000-0000-000000000013",
        Roller = actor,
        Subject = target,
    }
    rollEntity.RequestedRoll = requestedRoll
    coordinator.OnRequestedRoll(rollEntity, requestedRoll)

    local finishedEvent = {
        RollUuid = requestedRoll.RollUuid,
        Roller = actor,
    }
    local finishedEntity = entity(
        "00000000-0000-0000-0000-000000000014",
        "0200000200000014"
    )
    coordinator.OnFinishedEvents(finishedEntity, { Events = { finishedEvent } }, "created")
    assertEqual(actor, finishedEvent.Roller, "event owner remains untouched")
    local observed = findRecord(records, "native_finished_event_correlated")
    assertEqual(finishedEntity.handle, observed.fields.finished_event_handle,
        "event handle published for native routing")
    assertEqual(actor.guid, observed.fields.roller_before, "initiator observed")
    assertEqual(actor.guid, observed.fields.roller_after, "initiator published unchanged")
    assertEqual(1, observed.fields.owner_matches_initiator, "native ownership asserted")
end)

test("a specialist-owned finished event is rejected without rewriting it", function()
    local coordinator, _, _, _, records = makeCoordinator()
    coordinator.OnNativeRequest("disarm", "actor", "target", 14)
    local rollEntity = entity(
        "00000000-0000-0000-0000-000000000015",
        "0200000200000015"
    )
    local requestedRoll = {
        Entity2Uuid = "",
        EntityUuid = "",
        FixedRollBonuses = {},
        ResolvedRollBonuses = {},
        RollUuid = "00000000-0000-0000-0000-000000000016",
        Roller = actor,
        Subject = target,
    }
    rollEntity.RequestedRoll = requestedRoll
    coordinator.OnRequestedRoll(rollEntity, requestedRoll)

    local finishedEvent = {
        RollUuid = requestedRoll.RollUuid,
        Roller = specialist,
    }
    local finishedEntity = entity(
        "00000000-0000-0000-0000-000000000017",
        "0200000200000017"
    )
    assertEqual(false,
        coordinator.OnFinishedEvents(finishedEntity, { Events = { finishedEvent } }, "created"),
        "invalid event owner rejected")
    assertEqual(specialist, finishedEvent.Roller, "Lua does not rewrite an invalid event owner")
    local observed = findRecord(records, "native_finished_event_owner_invalid")
    assertEqual("Error", observed.level, "ownership violation diagnosed")
    assertEqual(specialist.guid, observed.fields.roller_before, "specialist owner observed")
    assertEqual(specialist.guid, observed.fields.roller_after, "invalid owner remains unchanged")
end)

test("native implementation preserves ownership and authoritative roll results", function()
    local file = assert(io.open(BEST_OF_HANDS_ROOT .. "/native/src/BestOfHandsNative.cpp", "rb"))
    local source = file:read("*a")
    file:close()
    local hookBlock = assert(source:match(
        "constexpr std::string_view kReportedHooks =%s*(.-);"
    ), "native reported-hook declaration")
    local nativeHookParts = {}
    for part in hookBlock:gmatch('"([^"]*)"') do
        nativeHookParts[#nativeHookParts + 1] = part
    end
    assertEqual(
        NativeBridge.REQUIRED_HOOKS,
        table.concat(nativeHookParts),
        "Lua and DLL handshake hook lists remain identical"
    )
    assertContains(source, 'ProfileUiMidHook', "native UI profile hook")
    assertContains(source, 'ProfileMathMidHook', "native calculation profile hook")
    assertContains(source, 'ClientRollPresentationMidHook',
        "native client presentation hook")
    assertContains(source, 'ClientRollStartMidHook',
        "native client roll-start hook")
    assertContains(source, 'ClientRollPayloadReadyMidHook',
        "native successful payload-ready hook")
    assertContains(source, 'ClientRollPostDispatchMidHook',
        "native success-gated post-dispatch hook")
    assertContains(source, 'ClientRollAggregateMidHook',
        "native client modifier-aggregate hook")
    assertContains(source, 'ClientRollResultMidHook',
        "native client roll-result hook")
    assertContains(source, 'ClientRollBonusReconcileStartMidHook',
        "native resolved-bonus reconciliation start hook")
    assertContains(source, 'ClientRollBonusReconcileViewModelMidHook',
        "native resolved-bonus viewmodel observation hook")
    assertContains(source, 'ClientRollBonusPreserveMatchedMidHook',
        "native matched roll-bonus disable guard")
    assertContains(source, 'ClientRollBonusPreserveMissingMidHook',
        "native missing-identity roll-bonus disable guard")
    assertContains(source, 'ClientRollBonusKeepSelectedDetour',
        "native selected-bonus continuity guard")
    assertContains(source, 'SetDynamicModifierRollBonusPresentationType',
        "selected bonus is given BG3's result-facing roll-bonus type")
    assertContains(source, 'SetDynamicModifierSourceVm',
        "selected bonus source viewmodel is transferred through BG3's retained setter")
    assertContains(source, 'SetDynamicModifierNameFromPresentation',
        "selected bonus localized name is copied from its actual presentation viewmodel")
    assertContains(source, 'FindNoesisProperty',
        "selected bonus name is resolved through its concrete Noesis source class")
    assertContains(source, 'FindVmRollModifierNameProperty',
        "the target modifier name property is cached by reflected class")
    assertContains(source, 'FindSourceNameProperty',
        "source modifier name properties are cached by reflected class")
    assertEqual(nil, source:find('name_binding_result=', 1, true),
        "hot-path name binding no longer constructs diagnostic result strings")
    assertEqual(nil, source:find('name_binding_value=', 1, true),
        "hot-path localized names are not hex-encoded for diagnostics")
    local selectedNameOffset = assert(source:find(
        "viewModel, selectedViewModel", 1, true
    ), "selected viewmodel name lookup")
    local sourceNameOffset = assert(source:find(
        "viewModel, sourceVm", selectedNameOffset + 1, true
    ), "source viewmodel name fallback")
    assertEqual(true, selectedNameOffset < sourceNameOffset,
        "the visibly labeled selected row is the primary name source")
    assertEqual(nil, source:find('targetName == sourceName', 1, true),
        "localized string assignment is not rejected for using a canonicalized backing allocation")
    assertEqual(nil, source:find('translated_name_validation_failed', 1, true),
        "the invalid raw-byte localized string validation is removed")
    assertEqual(nil, source:find('kSourceVmNameValueOffset', 1, true),
        "modifier presentation does not assume a VMStatus-specific Name offset")
    assertContains(source,
        'kClientVmRollModifierSourceVmPropertySetterSignature',
        "native SourceVM setter is signature guarded")
    assertContains(source,
        'kClientVmRollModifierNameValueAssignSignature',
        "native localized-name assignment is signature guarded")
    assertContains(source, 'ClientRollBonusRendererAddMidHook',
        "persistent bonus icons are bound before their first native collection add")
    assertContains(source,
        'ArmSelectedRollBonusPresentationAfterPayload',
        "selected-wrapper continuity is armed only after BG3 materializes the roll command payload")
    assertContains(source,
        'binding_timing=after_request_payload_before_dispatch',
        "payload-safe selected-wrapper timing is traced")
    assertContains(source, 'pre_roll_synthetic_rows=0',
        "directly selected bonuses never add a placeholder result row before animation")
    assertContains(source, 'request_payload_unchanged=1',
        "selected-wrapper preparation preserves BG3's detached request payload")
    assertContains(source, 'RestoreSelectedRollBonusList',
        "the exact selected boost wrapper is restored for vanilla selected-bonus UI")
    assertContains(source, 'native_client_roll_selected_bonus_restored',
        "selected-wrapper restoration is traced at both lifecycle guards")
    assertContains(source,
        'native_client_roll_selected_bonus_removal_suppressed',
        "selected-wrapper continuity is traced across roll dispatch")
    assertContains(source, 'selected_removal_guard_armed=',
        "selected-wrapper removal suppression is armed only after payload validation")
    assertContains(source, '"post_dispatch"',
        "selected wrapper is restored after request dispatch")
    assertContains(source, '"pre_reconcile"',
        "selected wrapper is reasserted before the selected-bonus animation sequence")
    assertContains(source, 'native_client_roll_bonus_renderer_source_bound',
        "persistent bonus SourceVM binding timing is traced")
    assertContains(source, 'source_vm_transferred_count=',
        "presentation transfer traces source viewmodel completeness")
    assertEqual(nil, source:find('ReplayClientRollBonusNativeRenderer', 1, true),
        "late native renderer replay is not retained")
    assertContains(source, 'ClientRollBonusReconcileEndMidHook',
        "native resolved-bonus reconciliation completion hook")
    assertContains(source, 'ClientRollFinalizeMidHook',
        "native client roll-finalization hook")
    assertContains(source, 'context.r15 =', "UI redirects a local pointer")
    assertContains(source, 'context.r8 =', "math redirects a local pointer")
    assertContains(source, 'component_owner_unchanged=1', "ownership invariant traced")
    assertContains(source, 'requested_roll_owner_mutation=0', "ownership mutation disabled")
    assertContains(source,
        '"client_roll_aggregate,client_roll_start,"',
        "all verified hooks reported")
    assertContains(source,
        '"client_roll_payload_ready,client_roll_post_dispatch,"',
        "payload-ready and post-dispatch hooks are required by the native handshake")
    assertContains(source, 'kClientRollPayloadReadySignature',
        "successful payload-ready boundary is signature guarded")
    assertContains(source, 'kClientRollPostDispatchSignature',
        "post-dispatch presentation boundary is signature guarded")
    assertContains(source, 'kClientRollPresentationSignature',
        "client presentation signature guard")
    assertContains(source, 'context.rax =',
        "client presentation replaces only the local advantage value")
    assertContains(source, 'native_client_roll_presentation_selected',
        "client presentation selection is traced")
    assertContains(source, 'native_client_roll_start_boundary',
        "click-to-roll presentation state is traced")
    assertContains(source, 'native_client_roll_aggregate_guard',
        "modifier-aggregate presentation state is traced")
    assertContains(source, 'native_client_roll_result_consistency',
        "roll-result presentation consistency is traced")
    assertContains(source, 'native_client_roll_finalize_consistency',
        "resolved bonus presentation consistency is traced")
    assertContains(source, 'native_client_roll_bonus_viewmodel_restored',
        "retargeted resolved-bonus viewmodel restoration is traced")
    assertContains(source, 'native_client_roll_bonus_disable_suppressed',
        "pre-refresh roll-bonus preservation is traced")
    assertContains(source, 'kClientRollBonusPreserveMatchedSignature',
        "matched roll-bonus preservation signature guard")
    assertContains(source, 'kClientRollBonusPreserveMissingSignature',
        "missing-identity roll-bonus preservation signature guard")
    assertContains(source, 'authoritative_result_unchanged=1',
        "resolved-bonus repair leaves authoritative math untouched")
    assertContains(source, 'result_numeric_values_unchanged=1',
        "roll-result numeric values remain untouched")
    assertContains(source, 'kActiveRollFallbackOffset',
        "delegated result clears the presentation fallback before publication")
    assertContains(source, 'FreezeClientPresentationAdvantage',
        "presentation profile freezes when rolling begins")
    assertContains(source, 'kAdvantageVmDisabledOffset = 0x88',
        "advantage-source presentation uses VMAdvantage's distinct layout")
    assertContains(source, 'ClientAdvantagePreserveMatchedMidHook',
        "matched advantage-source disable decisions are guarded")
    assertContains(source, 'ClientAdvantagePreserveMissingMidHook',
        "missing advantage-source disable decisions are guarded")
    assertContains(source, 'ShouldPreserveAdvantageModifierPresentation',
        "advantage-source preservation requires the specialist's expected type")
    assertContains(source, 'native_client_advantage_disable_suppressed',
        "advantage-source presentation preservation remains traceable")
    assertContains(source, 'MatchDelegatedAdvantageSourceModifier',
        "the icon-bearing advantage modifier is retained separately")
    assertContains(source, 'native_client_advantage_source_modifier_preserved',
        "advantage source icon retention remains traceable")
    assertContains(source, 'native_client_advantage_source_modifier_binding',
        "icon-bearing modifier SourceVM bindings are traced")
    assertContains(source, 'native_client_advantage_viewmodel_binding',
        "dedicated advantage SourceVM bindings are traced")
    assertContains(source, 'source_icon_binding_preserved=1',
        "the native advantage SourceVM remains the icon source")
    assertContains(source, 'roll_bonus_path_unchanged=1',
        "advantage-source preservation remains isolated from roll bonuses")
    assertContains(source, 'MatchClientPresentationLease',
        "destroyed RequestedRoll presentation survives by exact roll UUID")
    assertEqual(nil, source:find('ClientRollPhaseMidHook', 1, true),
        "production does not install the trace-only phase detour")
    assertEqual(nil, source:find('ClientModifierAnimationStartMidHook', 1, true),
        "production does not install the trace-only animation-start detour")
    assertEqual(nil, source:find('ClientModifierAnimationEndMidHook', 1, true),
        "production does not install the trace-only animation-end detour")
    assertContains(source, 'kMaximumClientPresentationLeases = 64',
        "client presentation lease cache is bounded")
    assertContains(source, 'kSelectedBoostVmDiceTypeSetOffset = 0xe0',
        "selected boost DiceTypeSet uses its reflected VMBoostModifier layout")
    assertContains(source, 'kSelectedBoostVmIdentityOffset = 0x110',
        "selected boost identity remains separate from its DiceTypeSet")
    assertContains(source, 'kSelectedBoostVmSourceVmOffset = 0x48',
        "selected boost retains its pre-roll label and icon source viewmodel")
    assertContains(source, 'CreateVmRollModifierViewModel',
        "missing immediate bonus presentation uses a real VMRoll modifier")
    assertContains(source, 'SetDynamicModifierResolvedValue',
        "the result row receives BG3's authoritative resolved dice value")
    assertContains(source, 'SetSelectedRollBonusResolvedValue',
        "the visible selected row can receive BG3's authoritative resolved dice value")
    assertContains(source, 'kSelectedModifierResolvedValueOffset = 0xb0',
        "the selected-row value matches BG3's modifier-animation callback branch")
    assertContains(source, 'clientSelectedModifierValueRva',
        "the selected-row object is resolved through BG3's own guarded helper")
    assertContains(source, 'selected_authoritative_direct:',
        "a successful transfer records the direct single visible selected-row path")
    assertContains(source, 'single_numeric_presentation_path=',
        "the result trace distinguishes the single-path handoff from its fail-open fallback")
    assertContains(source, 'bonuses[index].value > 0',
        "unresolved sentinel values can never become visible modifier rows")
    assertContains(source, 'resolved_value_transferred=',
        "resolved value transfer is explicit in the presentation trace")
    assertContains(source, 'kClientVmRollModifierFactorySignature',
        "VMRoll modifier factory is guarded by the executable signature")
    assertContains(source, 'kClientVmDiceTypeSetPropertySetterSignature',
        "DiceTypeSet property setter is guarded by the executable signature")
    assertContains(source, 'source_vm_property_setter=native_noesis',
        "binding trace identifies the retained native SourceVM setter")
    assertContains(source, 'factory_class=VMRollModifier_size_1f0',
        "factory trace identifies the result-facing VMRollModifier class")
    assertContains(source, 'selected_wrapper_inserted=0',
        "a selected action wrapper is never inserted as a result wrapper")
    assertEqual(nil,
        source:find('prepared_row_role=transitional_until_resolution', 1, true),
        "the visible placeholder-producing transitional row has been removed")
    assertEqual(nil, source:find('TrackPreparedRollBonusViewModel', 1, true),
        "pre-roll placeholder rows are not tracked or inserted")
    assertContains(source, 'sameShapeBonusCount != 1',
        "cached presentation repair fails open on ambiguous dice bonuses")
    assertContains(source, 'kProfileUiSignature', "UI signature guard")
    assertContains(source, 'kProfileMathSignature', "math signature guard")
    assertEqual(nil, source:find('PatchRequestedRoll', 1, true),
        "no component-wide roller patch remains")
    assertEqual(nil, source:find('RouteFinishedEvent', 1, true),
        "no finished-event rewriting remains")
end)

test("v2 left-click path activates BG3's stock task through native lifecycle", function()
    local file = assert(io.open(luaRoot .. "Init.lua", "rb"))
    local source = file:read("*a")
    file:close()
    assertContains(source, 'listen("RequestCanLockpick"', "lockpick listener")
    assertContains(source, 'listen("RequestCanDisarmTrap"', "disarm listener")
    assertContains(source, 'listen("RequestProcessed"', "request result trace listener")
    assertContains(source, 'local function emitStatus(', "automatic status snapshot helper")
    assertContains(source, 'emitStatus("roll_result"', "handled roll emits an automatic status snapshot")
    assertContains(source, 'value == nil', "trace command without an argument enables tracing")
    assertEqual(nil, source:find('OnChange("ServerRollFinishedEvent"', 1, true), "no invalid change observer")
    local commandOffset = assert(source:find('Ext.RegisterConsoleCommand("best_of_hands_status"', 1, true))
    local observerOffset = assert(source:find("interaction.Subscribe()", 1, true))
    assertEqual(true, commandOffset < observerOffset, "diagnostic commands precede observers")
    assertEqual(nil, source:find("RequestActiveRoll", 1, true), "no custom active roll")
    assertContains(source, 'listen("UseFinished"', "failed ordinary Use entry listener")
    assertContains(source, "quickLockpick.OnUseFinished",
        "failed Use delegates to the stock-task coordinator")
    assertEqual(nil, source:find("TemplateRemove", 1, true), "no custom tool path")
    assertEqual(nil, source:find("Unlock(", 1, true), "no custom success path")

    local quickFile = assert(io.open(luaRoot .. "QuickLockpickCoordinator.lua", "rb"))
    local quickSource = quickFile:read("*a")
    quickFile:close()
    assertContains(quickSource, 'operation = operation', "targeted client task request")
    assertContains(quickSource, "OnClientMessage",
        "client acknowledgement is correlated server-side")
    assertEqual(nil, quickSource:find("RequestActiveRoll", 1, true), "coordinator owns no roll")
    assertEqual(nil, quickSource:find("TemplateRemove", 1, true), "coordinator owns no tools")
    assertEqual(nil, quickSource:find("Unlock(", 1, true), "coordinator owns no outcome")

    local clientFile = assert(io.open(
        BEST_OF_HANDS_ROOT
            .. "/src/BestOfHands/Mods/BestOfHands/ScriptExtender/Lua/Client/"
            .. "NativePresentationBridge.lua",
        "rb"
    ))
    local clientSource = clientFile:read("*a")
    clientFile:close()
    assertEqual(nil, clientSource:find("controller.RunningTask = task", 1, true),
        "Lua does not write BG3SE's read-only running-task property")
    assertEqual(nil, clientSource:find("controller.IsNewTaskStarted = true", 1, true),
        "Lua does not forge controller lifecycle state")
    assertContains(clientSource, 'operation = "queued"',
        "stock task is acknowledged after native queue publication")
    assertContains(clientSource, '"quick=" .. record.request',
        "client publishes the exact fallback request to native code")

    local nativeFile = assert(io.open(
        BEST_OF_HANDS_ROOT .. "/native/src/BestOfHandsNative.cpp", "rb"
    ))
    local nativeSource = nativeFile:read("*a")
    nativeFile:close()
    assertContains(nativeSource, "ClientTaskSelectionMidHook",
        "ordinary ItemUse is intercepted at BG3's task-selection boundary")
    assertContains(nativeSource, "kClientTaskSelectionSignature",
        "the task-selection boundary is exact-signature guarded")
    assertContains(nativeSource, "context.r15 = redirect->lockpickTask",
        "the selected stock ItemUse task is replaced before it can start")
    assertContains(nativeSource, "BG3 clears ItemUse.Ready",
        "substitution happens before non-winning task readiness is retired")
    assertEqual(nil, nativeSource:find("0x01b3a2d2", 1, true),
        "the late preparation-only hook site cannot leave ItemUse armed")
    assertEqual(nil,
        nativeSource:find("ClientSetRunningTaskDetour", 1, true),
        "the unused public SetRunningTask interception path is removed")
    assertContains(nativeSource, "ClientInputControllerUpdateDetour",
        "the failed-Use fallback is consumed at the controller update boundary")
    assertContains(nativeSource, "TryInvokeSetRunningTask",
        "the fallback alone calls BG3's validated SetRunningTask routine")
    assertContains(nativeSource, "kClientSetRunningTaskSignature",
        "the engine routine is exact-signature guarded")
    assertContains(nativeSource, "FindStockCharacterTask",
        "native code discovers the stock task owned by the real controller")

    local settingsFile = assert(io.open(luaRoot .. "Settings.lua", "rb"))
    local settingsSource = settingsFile:read("*a")
    settingsFile:close()
    assertContains(settingsSource, "TRACE_EVENTS = false",
        "production sessions start with tracing disabled")
end)

if failed > 0 then
    error(string.format("%d Lua tests failed; %d passed", failed, passed))
end

print(string.format("All %d Lua tests passed", passed))
