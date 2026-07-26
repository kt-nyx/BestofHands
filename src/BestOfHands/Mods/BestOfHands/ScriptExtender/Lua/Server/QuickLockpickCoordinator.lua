-- SPDX-License-Identifier: Unlicense

local QuickLockpickCoordinator = {}

local function objectKey(actor, target)
    return tostring(actor) .. "|" .. tostring(target)
end

function QuickLockpickCoordinator.Create(
    settings,
    api,
    bridge,
    channel,
    diagnostics
)
    local instance = {}
    local pending = {}
    local forcedTurnBased = {}
    local generation = 0
    local sequence = 0

    local function requestId()
        sequence = sequence + 1
        local clock = api.MonotonicTime()
        return table.concat({
            tostring(clock or "no-clock"),
            tostring(generation),
            tostring(sequence),
        }, "-")
    end

    local function send(record, operation)
        local sent = api.SendQuickLockpick(channel, {
            actor = record.actorUuid,
            operation = operation,
            request = record.id,
            target = record.targetUuid,
        }, record.userId)
        if not sent then
            diagnostics.Warn("quick_lockpick_client_message_failed", {
                actor = record.actor,
                operation = operation,
                request = record.id,
                target = record.target,
            })
        end
        return sent
    end

    local function clearRecord(record, reason)
        local key = objectKey(record.actor, record.target)
        if pending[key] ~= record then
            return false
        end
        pending[key] = nil
        send(record, "cancel")
        diagnostics.Trace("quick_lockpick_cleared", {
            actor = record.actor,
            reason = reason,
            request = record.id,
            target = record.target,
        })
        return true
    end

    function instance.OnUseFinished(actor, target, success)
        if success ~= 0
            or not bridge.IsReady()
            or not api.IsPlayer(actor)
            or not api.IsLocked(target)
            or api.IsInCombat(actor)
            or forcedTurnBased[actor] == true then
            return false
        end

        local key = objectKey(actor, target)
        if pending[key] ~= nil then
            diagnostics.Trace("quick_lockpick_duplicate_ignored", {
                actor = actor,
                target = target,
            })
            return false
        end

        local actorUuid = api.GetEntityUuid(actor)
        local targetUuid = api.GetEntityUuid(target)
        local userId = api.GetReservedUserId(actor)
        if actorUuid == nil or targetUuid == nil or userId == nil then
            diagnostics.Warn("quick_lockpick_skipped", {
                actor = actor,
                reason = "client_route_unavailable",
                target = target,
            })
            return false
        end

        local record = {
            actor = actor,
            actorUuid = actorUuid,
            id = requestId(),
            target = target,
            targetUuid = targetUuid,
            userId = userId,
        }
        pending[key] = record

        -- Let the failed vanilla Use callback unwind before asking the owning
        -- client to activate BG3's stock lockpick task.
        api.Schedule(0, function()
            if pending[key] ~= record then
                return
            end
            if not bridge.IsReady()
                or not api.IsLocked(target)
                or api.IsInCombat(actor)
                or forcedTurnBased[actor] == true then
                clearRecord(record, "conditions_changed")
                return
            end
            if not send(record, "start") then
                clearRecord(record, "client_message_failed")
                return
            end
            diagnostics.Info("quick_lockpick_task_requested", {
                actor = actor,
                request = record.id,
                target = target,
                user_id = userId,
            })
        end)

        api.Schedule(settings.QUICK_LOCKPICK_TIMEOUT_MS, function()
            clearRecord(record, "timeout")
        end)
        return true
    end

    function instance.OnNativeRequest(actor, target)
        local record = pending[objectKey(actor, target)]
        if record == nil then
            return false
        end
        return clearRecord(record, "native_request_started")
    end

    function instance.OnEnteredForceTurnBased(actor)
        forcedTurnBased[actor] = true
    end

    function instance.OnLeftForceTurnBased(actor)
        forcedTurnBased[actor] = nil
    end

    function instance.Clear(reason)
        generation = generation + 1
        local records = {}
        for _, record in pairs(pending) do
            records[#records + 1] = record
        end
        pending = {}
        forcedTurnBased = {}
        for _, record in ipairs(records) do
            send(record, "cancel")
        end
        diagnostics.Trace("quick_lockpick_reset", {
            reason = reason,
            records = #records,
        })
    end

    function instance.Count()
        local count = 0
        for _ in pairs(pending) do
            count = count + 1
        end
        return count
    end

    return instance
end

return QuickLockpickCoordinator
