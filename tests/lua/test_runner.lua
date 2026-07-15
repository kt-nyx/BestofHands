-- SPDX-License-Identifier: Unlicense

local luaRoot = BEST_OF_HANDS_ROOT .. "/src/BestOfHands/Mods/BestOfHands/ScriptExtender/Lua/Server/"
local PartySkillResolver = dofile(luaRoot .. "PartySkillResolver.lua")
local LegacyAssistanceCleanup = dofile(luaRoot .. "LegacyAssistanceCleanup.lua")
local InteractionCoordinator = dofile(luaRoot .. "InteractionCoordinator.lua")
local RuntimeApi = dofile(luaRoot .. "RuntimeApi.lua")

local passed = 0
local failed = 0

local function assertEqual(expected, actual, message)
    if expected ~= actual then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)), 2)
    end
end

local function test(name, callback)
    local ok, err = xpcall(callback, debug.traceback)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. "\n" .. tostring(err))
    end
end

local diagnostics = {
    Info = function() end,
    Warn = function() end,
    Error = function() end,
    Trace = function() end,
}

local function makeResolverApi(scores, overrides)
    overrides = overrides or {}
    local api = {}
    api.GetPlayers = function() return overrides.players or { "actor", "best", "tie" } end
    api.CalculateSleightOfHand = function(character) return scores[character] end
    api.IsPartyMember = function(character) return overrides.partyMember ~= character end
    api.IsInPartyWith = function(character) return overrides.otherParty ~= character end
    api.IsDead = function(character) return overrides.dead == character end
    api.IsSummon = function(character) return overrides.summon == character end
    api.GetRegion = function(character)
        if overrides.otherRegion == character then return "B" end
        return "A"
    end
    api.HasIneligibleStatus = function(character)
        if overrides.downed == character then return true, "DOWNED" end
        return false, nil
    end
    return api
end

test("resolver selects the best eligible raw modifier", function()
    local resolver = PartySkillResolver.Create(makeResolverApi({ actor = 3, best = 9, tie = 4 }), diagnostics)
    local result = resolver.Resolve("actor", "chest", "lockpick", 12)
    assertEqual("best", result.specialist, "specialist")
    assertEqual(3, result.initiatorScore, "initiator score")
    assertEqual(9, result.specialistScore, "specialist score")
end)

test("resolver prefers initiator on a tie", function()
    local resolver = PartySkillResolver.Create(makeResolverApi({ actor = 9, best = 9, tie = 9 }), diagnostics)
    local result = resolver.Resolve("actor", "door", "lockpick", 13)
    assertEqual("actor", result.specialist, "tie winner")
end)

test("resolver filters unavailable and cross-region candidates", function()
    local resolver = PartySkillResolver.Create(makeResolverApi(
        { actor = 2, best = 20, tie = 18 },
        { downed = "best", otherRegion = "tie" }
    ), diagnostics)
    local result = resolver.Resolve("actor", "trap", "disarm", 14)
    assertEqual("actor", result.specialist, "filtered winner")
end)

test("resolver includes active companions and compares raw roll modifiers", function()
    local api = makeResolverApi({ actor = 1, best = 12, tie = 2 })
    -- Deliberately omit IsControlled: BG3 reports it only for the currently
    -- selected actor, while all active companions still pass party membership.
    local resolver = PartySkillResolver.Create(api, diagnostics)
    local result = resolver.Resolve("actor", "door", "lockpick", 15)
    assertEqual("best", result.specialist, "unselected active companion")
    assertEqual(12, result.specialistScore, "raw modifier")
end)

local function makeLegacyCleanupApi()
    local state = {}
    local removeSucceeds = true
    local calls = { remove = {}, saved = {} }
    local api = {}
    api.RemoveSkillBoost = function(actor, delta, source)
        calls.remove[#calls.remove + 1] = { actor, delta, source }
        return removeSucceeds
    end
    api.SaveAssistanceState = function(value)
        state = value
        calls.saved[#calls.saved + 1] = value
        return true
    end
    api.LoadAssistanceState = function() return state end
    return api, calls,
        function(value) state = value end,
        function(value) removeSucceeds = value end
end

test("legacy cleanup removes a persisted temporary boost", function()
    local api, calls, setState = makeLegacyCleanupApi()
    setState({ actor = {
        action = "lockpick", actor = "actor", delta = 4,
        requestId = 30, source = "BestOfHands_Assistance_4", target = "chest",
    } })
    local cleanup = LegacyAssistanceCleanup.Create(api, diagnostics)
    cleanup.RecoverPersisted()
    assertEqual(1, #calls.remove, "recovery remove count")
    assertEqual(4, calls.remove[1][2], "recovered modifier")
    assertEqual(0, cleanup.Count(), "retained count")
    assertEqual(nil, next(calls.saved[#calls.saved]), "persisted state cleared")
end)

test("legacy cleanup retains ownership until exact removal succeeds", function()
    local api, calls, setState, setRemoveSucceeds = makeLegacyCleanupApi()
    setState({ actor = {
        actor = "actor", delta = 3, source = "BestOfHands_Assistance_3",
    } })
    setRemoveSucceeds(false)
    local cleanup = LegacyAssistanceCleanup.Create(api, diagnostics)
    cleanup.RecoverPersisted()
    assertEqual(1, cleanup.Count(), "failed cleanup retained")
    setRemoveSucceeds(true)
    cleanup.RecoverPersisted()
    assertEqual(0, cleanup.Count(), "retry cleanup cleared")
    assertEqual(2, #calls.remove, "exact removal retried")
end)

test("runtime tool sourcing honors holder priority across tool states", function()
    local inventory = {
        ["specialist|opened"] = "specialist-opened-tools",
        ["actor|closed"] = "actor-closed-tools",
        ["camp|closed"] = "camp-tools",
        ["other|opened"] = "other-tools",
    }
    _G.Ext = {}
    _G.Osi = {
        DB_Players = { Get = function() return {
            { "specialist" }, { "actor" }, { "camp" }, { "other" },
        } end },
        GetItemByTemplateInInventory = function(template, holder)
            return inventory[holder .. "|" .. template] or ""
        end,
        GetItemByTemplateInPartyInventory = function() return "" end,
        GetInventoryOwner = function(item) return item:match("^([^-]+)") end,
        IsInPartyWith = function() return 1 end,
        IsPartyMember = function(character) return character == "camp" and 0 or 1 end,
    }
    local api = RuntimeApi.Create({
        THIEVES_TOOLS_TEMPLATES = { "closed", "opened" },
        TRAP_DISARM_TOOL_TEMPLATES = { "disarm" },
    }, diagnostics)

    local tool = api.FindActionTool("lockpick", "specialist", "actor")
    assertEqual("specialist-opened-tools", tool.item, "specialist before actor")

    inventory["specialist|opened"] = nil
    inventory["actor|closed"] = nil
    tool = api.FindActionTool("lockpick", "specialist", "actor")
    assertEqual("other-tools", tool.item, "active party fallback excludes camp")
end)

test("runtime difficulty lookup uses template then component fallback", function()
    local templateDifficulty = "template-dc"
    _G.Osi = { GetTemplate = function() return "root-template" end }
    _G.Ext = {
        Template = {
            GetRootTemplate = function() return {
                LockDifficultyClassID = templateDifficulty,
            } end,
            GetTemplate = function() return nil end,
        },
        Entity = { Get = function() return {
            Lock = { field_8 = "runtime-dc" },
        } end },
    }
    local api = RuntimeApi.Create({}, diagnostics)
    assertEqual("template-dc", api.GetActionDifficultyClass(
        "lockpick", "chest"
    ), "template difficulty")

    templateDifficulty = "00000000-0000-0000-0000-000000000000"
    assertEqual("runtime-dc", api.GetActionDifficultyClass(
        "lockpick", "chest"
    ), "runtime fallback difficulty")
end)

local function makeInteractionApi()
    local calls = {
        blocks = {},
        complete = {},
        consume = {},
        permission = {},
        rolls = {},
        targetUse = {},
        timers = {},
    }
    local state = {
        actionAvailable = { lockpick = true, disarm = true },
        combat = false,
        difficulty = "dc-15",
        specialist = "best",
        tool = { item = "tools", owner = "best", template = "template" },
    }
    local api = {}
    api.IsActionAvailable = function(action) return state.actionAvailable[action] end
    api.IsInCombat = function() return state.combat end
    api.FindActionTool = function() return state.tool end
    api.GetActionDifficultyClass = function() return state.difficulty end
    api.BlockNativeAction = function(action, actor, target)
        calls.blocks[#calls.blocks + 1] = { action, actor, target }
        return true
    end
    api.ProcessActionPermission = function(action, actor, target, requestId)
        calls.permission[#calls.permission + 1] = { action, actor, target, requestId }
        return true
    end
    api.RequestActiveSleightRoll = function(actor, target, difficulty, event)
        calls.rolls[#calls.rolls + 1] = { actor, target, difficulty, event }
        return true
    end
    api.CompleteAction = function(action, target, actor)
        calls.complete[#calls.complete + 1] = { action, target, actor }
        state.actionAvailable[action] = false
        return true
    end
    api.UseTarget = function(actor, target)
        calls.targetUse[#calls.targetUse + 1] = { actor, target }
        return true
    end
    api.ConsumeActionTool = function(tool)
        calls.consume[#calls.consume + 1] = tool
        return true
    end
    api.Schedule = function(_, callback) calls.timers[#calls.timers + 1] = callback end

    local resolver = {
        Resolve = function(actor, target, action, requestId)
            local specialist = state.specialist
            return {
                action = action,
                initiator = actor,
                initiatorScore = specialist == actor and 12 or 1,
                requestId = requestId,
                specialist = specialist,
                specialistScore = 12,
                target = target,
            }
        end,
    }
    return api, resolver, calls, state
end

local delegationSettings = {
    ACTION_PERMISSION_TIMEOUT_MS = 100,
    DELEGATION_ROLL_TIMEOUT_MS = 100,
    DELEGATED_DISARM_ROLL_EVENT = "BestOfHands_DelegatedDisarm",
    DELEGATED_LOCKPICK_ROLL_EVENT = "BestOfHands_DelegatedLockpick",
    QUICK_LOCKPICK_OPEN_TIMEOUT_MS = 100,
}

local function startAcceptedRoll(coordinator, calls, permissionActor)
    local permission = calls.permission[#calls.permission]
    coordinator.OnRequestProcessed(permissionActor, permission[4], 1)
    calls.timers[#calls.timers]()
end

local function runQueuedQuickPermission(calls)
    calls.timers[#calls.timers]()
end

test("quick lockpick asks vanilla permission and rolls as the specialist", function()
    local api, resolver, calls = makeInteractionApi()
    local coordinator = InteractionCoordinator.Create(delegationSettings, api, resolver, diagnostics)
    assertEqual(true, coordinator.OnUseFinished("actor", "chest", 0), "first request")
    assertEqual(false, coordinator.OnUseFinished("actor", "chest", 0), "duplicate request")
    assertEqual(0, #calls.permission, "permission deferred outside UseFinished")
    runQueuedQuickPermission(calls)
    assertEqual(1, #calls.permission, "permission count")
    assertEqual("actor", calls.permission[1][2], "permission actor")
    assertEqual("chest", calls.permission[1][3], "permission target")
    assertEqual(false, coordinator.OnRequestProcessed(
        "best", calls.permission[1][4], 1
    ), "specialist cannot satisfy initiator permission")
    assertEqual(0, #calls.rolls, "no roll before initiator response")
    startAcceptedRoll(coordinator, calls, "actor")
    assertEqual(1, #calls.rolls, "active roll count")
    assertEqual("best", calls.rolls[1][1], "actual roller")
    assertEqual("dc-15", calls.rolls[1][3], "lock DC")
    assertEqual(true, coordinator.OnRollResult(
        "BestOfHands_DelegatedLockpick", "best", "chest", 1
    ), "success result")
    assertEqual("lockpick", calls.complete[1][1], "completed action")
    assertEqual("best", calls.complete[1][3], "completion specialist")
    assertEqual("actor", calls.targetUse[1][1], "opening initiator")
    assertEqual(0, #calls.consume, "success consumption")
    assertEqual(0, coordinator.Count(), "pending after success")
end)

test("one action reserves a target across all initiating characters", function()
    local api, resolver, calls = makeInteractionApi()
    local coordinator = InteractionCoordinator.Create(delegationSettings, api, resolver, diagnostics)

    assertEqual(true, coordinator.OnUseFinished("actor-a", "chest", 0), "first actor queued")
    assertEqual(false, coordinator.OnUseFinished("actor-b", "chest", 0), "second actor rejected")
    assertEqual(1, coordinator.Count(), "single target reservation")
    runQueuedQuickPermission(calls)
    assertEqual("actor-a", calls.permission[1][2], "first actor owns permission")

    assertEqual(true, coordinator.OnNativeRequest(
        "lockpick", "actor-b", "chest", 46
    ), "competing native request blocked")
    assertEqual("actor-b", calls.blocks[1][2], "competing actor blocked")
    assertEqual(1, coordinator.Count(), "original delegation retained")
end)

test("different targets can be delegated concurrently", function()
    local api, resolver = makeInteractionApi()
    local coordinator = InteractionCoordinator.Create(delegationSettings, api, resolver, diagnostics)
    assertEqual(true, coordinator.OnUseFinished("actor-a", "chest-a", 0), "first target")
    assertEqual(true, coordinator.OnUseFinished("actor-b", "chest-b", 0), "second target")
    assertEqual(2, coordinator.Count(), "independent target reservations")
end)

test("a competing native start clears a same-target reservation", function()
    local api, resolver = makeInteractionApi()
    local coordinator = InteractionCoordinator.Create(delegationSettings, api, resolver, diagnostics)
    coordinator.OnUseFinished("actor-a", "chest", 0)
    assertEqual(true, coordinator.OnNativeStarted(
        "lockpick", "actor-b", "chest"
    ), "competing start observed")
    assertEqual(0, coordinator.Count(), "reservation cleared")
end)

test("quick lockpick preserves vanilla success and guarded cases", function()
    local api, resolver, calls, state = makeInteractionApi()
    local coordinator = InteractionCoordinator.Create(delegationSettings, api, resolver, diagnostics)
    assertEqual(false, coordinator.OnUseFinished("actor", "chest", 1), "successful vanilla use")
    state.actionAvailable.lockpick = false
    assertEqual(false, coordinator.OnUseFinished("actor", "chest", 0), "unlocked target")
    state.actionAvailable.lockpick = true
    state.combat = true
    assertEqual(false, coordinator.OnUseFinished("actor", "chest", 0), "combat")
    state.combat = false
    coordinator.OnEnteredForceTurnBased("actor")
    assertEqual(false, coordinator.OnUseFinished("actor", "chest", 0), "forced turn-based")
    coordinator.OnLeftForceTurnBased("actor")
    state.tool = nil
    assertEqual(false, coordinator.OnUseFinished("actor", "chest", 0), "no tools")
    state.tool = { item = "tools", owner = "best", template = "template" }
    state.difficulty = nil
    assertEqual(false, coordinator.OnUseFinished("actor", "chest", 0), "missing lock DC")
    assertEqual(0, #calls.permission, "skipped permission count")
end)

test("delegated failure consumes the selected tool and cancellation consumes none", function()
    local api, resolver, calls = makeInteractionApi()
    local coordinator = InteractionCoordinator.Create(delegationSettings, api, resolver, diagnostics)
    coordinator.OnUseFinished("actor", "door", 0)
    runQueuedQuickPermission(calls)
    startAcceptedRoll(coordinator, calls, "actor")
    coordinator.OnRollResult("BestOfHands_DelegatedLockpick", "best", "door", 0)
    assertEqual(1, #calls.consume, "failed roll consumption")
    assertEqual("best", calls.consume[1].owner, "selected owner consumed")
    assertEqual(0, #calls.complete, "failed roll completion")

    coordinator.OnUseFinished("actor", "door", 0)
    runQueuedQuickPermission(calls)
    startAcceptedRoll(coordinator, calls, "actor")
    coordinator.OnRollResult("BestOfHands_DelegatedLockpick", "best", "door", 2)
    assertEqual(1, #calls.consume, "cancelled roll consumption")
end)

test("manual native request is blocked then delegated through vanilla permission", function()
    local api, resolver, calls = makeInteractionApi()
    local coordinator = InteractionCoordinator.Create(delegationSettings, api, resolver, diagnostics)
    assertEqual(true, coordinator.OnNativeRequest("lockpick", "actor", "door", 42), "delegated")
    assertEqual(1, #calls.blocks, "native block count")
    assertEqual(true, coordinator.OnRequestProcessed("actor", 42, 0), "native rejection observed")
    calls.timers[#calls.timers]()
    assertEqual("actor", calls.permission[1][2], "permission initiator")
    startAcceptedRoll(coordinator, calls, "actor")
    assertEqual("best", calls.rolls[1][1], "manual actual roller")
    assertEqual("BestOfHands_DelegatedLockpick", calls.rolls[1][4], "delegated event")
end)

test("native request stays vanilla when the initiator is already best", function()
    local api, resolver, calls, state = makeInteractionApi()
    state.specialist = "actor"
    local coordinator = InteractionCoordinator.Create(delegationSettings, api, resolver, diagnostics)
    assertEqual(false, coordinator.OnNativeRequest("lockpick", "actor", "door", 43), "not delegated")
    assertEqual(0, #calls.blocks, "native request untouched")
end)

test("quick delegation suppresses an overtaking native initiator roll", function()
    local api, resolver, calls = makeInteractionApi()
    local coordinator = InteractionCoordinator.Create(delegationSettings, api, resolver, diagnostics)
    coordinator.OnUseFinished("actor", "door", 0)
    runQueuedQuickPermission(calls)
    local privateRequest = calls.permission[1][4]

    assertEqual(true, coordinator.OnNativeRequest(
        "lockpick", "actor", "door", 45
    ), "native roll suppressed")
    assertEqual(1, #calls.blocks, "native block count")
    assertEqual(false, coordinator.OnRequestProcessed(
        "actor", 45, 0
    ), "native rejection is not the private response")
    assertEqual(1, coordinator.Count(), "quick record retained")

    coordinator.OnRequestProcessed("actor", privateRequest, 1)
    calls.timers[#calls.timers]()
    assertEqual("best", calls.rolls[1][1], "specialist still rolls")
end)

test("trap disarm is delegated and completed as the specialist", function()
    local api, resolver, calls = makeInteractionApi()
    local coordinator = InteractionCoordinator.Create(delegationSettings, api, resolver, diagnostics)
    coordinator.OnNativeRequest("disarm", "actor", "trap", 44)
    coordinator.OnRequestProcessed("actor", 44, 0)
    calls.timers[#calls.timers]()
    startAcceptedRoll(coordinator, calls, "actor")
    coordinator.OnRollResult("BestOfHands_DelegatedDisarm", "best", "trap", 1)
    assertEqual("disarm", calls.complete[1][1], "completed disarm")
    assertEqual("best", calls.complete[1][3], "disarm specialist")
    assertEqual(0, #calls.targetUse, "trap not opened")
end)

test("blocked initiator permission and timeout clean delegation state", function()
    local api, resolver, calls = makeInteractionApi()
    local coordinator = InteractionCoordinator.Create(delegationSettings, api, resolver, diagnostics)
    coordinator.OnUseFinished("actor", "door", 0)
    runQueuedQuickPermission(calls)
    coordinator.OnRequestProcessed("actor", calls.permission[1][4], 0)
    assertEqual(0, coordinator.Count(), "pending after block")
    assertEqual(0, #calls.rolls, "no blocked roll")

    coordinator.OnUseFinished("actor", "door", 0)
    runQueuedQuickPermission(calls)
    calls.timers[#calls.timers]()
    assertEqual(0, coordinator.Count(), "pending after timeout")
    assertEqual(2, #calls.permission, "no permission retry")
end)

test("server bootstrap registers the narrow event surface", function()
    local listeners = {}
    local commands = {}
    local function event()
        return { Subscribe = function(_, callback) return callback end }
    end

    _G.Ext = {
        Require = function(path) return dofile(BEST_OF_HANDS_ROOT .. "/src/BestOfHands/Mods/BestOfHands/ScriptExtender/Lua/" .. path) end,
        Vars = {
            RegisterModVariable = function() end,
            GetModVariables = function() return {} end,
        },
        Osiris = {
            RegisterListener = function(name, arity, timing, callback)
                listeners[name] = { arity = arity, timing = timing, callback = callback }
            end,
        },
        Events = { SessionLoaded = event(), ResetCompleted = event() },
        RegisterConsoleCommand = function(name, callback) commands[name] = callback end,
        Utils = { Print = function() end },
        Timer = { WaitFor = function() end },
    }
    _G.Osi = { DB_Players = { Get = function() return {} end } }

    dofile(luaRoot .. "Init.lua")
    assertEqual(3, listeners.RequestCanLockpick.arity, "lockpick request arity")
    assertEqual(3, listeners.RequestCanDisarmTrap.arity, "disarm request arity")
    assertEqual(6, listeners.RollResult.arity, "roll result arity")
    assertEqual(3, listeners.UseFinished.arity, "use finished arity")
    assertEqual(3, listeners.RequestProcessed.arity, "request processed arity")
    assertEqual(1, listeners.EnteredForceTurnBased.arity, "forced turn-based arity")
    assertEqual("before", listeners.UseFinished.timing, "use-finished ordering")
    assertEqual("after", listeners.RequestProcessed.timing, "request-processed ordering")
    assertEqual("before", listeners.RequestCanLockpick.timing, "delegation ordering")
    assertEqual(true, commands.best_of_hands_trace ~= nil, "trace command")
    assertEqual(true, commands.best_of_hands_status ~= nil, "status command")
end)

if failed > 0 then
    error(string.format("%d Lua tests failed; %d passed", failed, passed))
end

print(string.format("Lua behavior tests passed: %d", passed))
