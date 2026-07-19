-- SPDX-License-Identifier: Unlicense

local InteractionCoordinator = {}

function InteractionCoordinator.Create(settings, api, resolver, diagnostics)
    local pendingByTarget = {}
    local pendingByNativeRequest = {}
    local pendingByPermissionRequest = {}
    local pendingByRoll = {}
    local opening = {}
    local forcedTurnBased = {}
    local nextRequestId = 1000000000
    -- One initial permission attempt plus a single correlated re-drive. A
    -- competing same-target Use can make vanilla reject the private permission
    -- response; when that contention is observed, re-drive once rather than
    -- aborting and letting a trailing UseFinished restart from scratch.
    local MAX_PERMISSION_ATTEMPTS = 2
    local instance = {}

    local function actionTargetKey(action, target)
        return tostring(action) .. "|" .. tostring(target)
    end

    local function requestKey(actor, requestId)
        return tostring(actor) .. "|" .. tostring(requestId)
    end

    local function rollKey(eventName, actor, target)
        return table.concat({ tostring(eventName), tostring(actor), tostring(target) }, "|")
    end

    local function openingKey(actor, target)
        return tostring(actor) .. "|" .. tostring(target)
    end

    local function clearFrom(map, record)
        for key, value in pairs(map) do
            if value == record then
                map[key] = nil
            end
        end
    end

    local function clear(record)
        clearFrom(pendingByTarget, record)
        clearFrom(pendingByNativeRequest, record)
        clearFrom(pendingByPermissionRequest, record)
        clearFrom(pendingByRoll, record)
    end

    local function abort(record, reason)
        clear(record)
        diagnostics.Trace("delegation_aborted", {
            action = record.action,
            actor = record.initiator,
            origin = record.origin,
            reason = reason,
            request_id = record.requestId,
            specialist = record.specialist,
            target = record.target,
        })
    end

    local function allocateRequestId()
        local result = nextRequestId
        nextRequestId = nextRequestId + 1
        if nextRequestId > 2000000000 then
            nextRequestId = 1000000000
        end
        return result
    end

    local function eventFor(action)
        if action == "disarm" then
            return settings.DELEGATED_DISARM_ROLL_EVENT
        end
        return settings.DELEGATED_LOCKPICK_ROLL_EVENT
    end

    local function prepare(action, initiator, target, requestId, origin, requireDifferent)
        local resolution = resolver.Resolve(initiator, target, action, requestId)
        if resolution == nil then
            return nil, "specialist_unavailable"
        end
        if requireDifferent and resolution.specialist == initiator then
            diagnostics.Trace("delegation_not_needed", {
                action = action,
                actor = initiator,
                request_id = requestId,
                target = target,
            })
            return nil, "initiator_is_specialist"
        end

        local tool = api.FindActionTool(action, resolution.specialist, initiator)
        if tool == nil then
            return nil, "required_tool_unavailable"
        end

        local difficultyClass = api.GetActionDifficultyClass(action, target)
        if difficultyClass == nil then
            return nil, "difficulty_unavailable"
        end

        return {
            action = action,
            difficultyClass = difficultyClass,
            eventName = eventFor(action),
            initiator = initiator,
            initiatorScore = resolution.initiatorScore,
            origin = origin,
            originalRequestId = requestId,
            phase = "prepared",
            requestId = nil,
            specialist = resolution.specialist,
            specialistScore = resolution.specialistScore,
            target = target,
            tool = tool,
        }, nil
    end

    local function startRoll(record)
        if pendingByTarget[actionTargetKey(record.action, record.target)] ~= record
            or record.phase ~= "roll_pending" then
            return
        end
        if not api.IsActionAvailable(record.action, record.target) then
            abort(record, "target_no_longer_available")
            return
        end

        record.phase = "roll"
        pendingByRoll[rollKey(record.eventName, record.specialist, record.target)] = record
        local started = api.RequestActiveSleightRoll(
            record.specialist,
            record.target,
            record.difficultyClass,
            record.eventName
        )
        if not started then
            abort(record, "roll_request_failed")
            return
        end

        diagnostics.Info("delegated_roll_started", {
            action = record.action,
            actor = record.initiator,
            difficulty_class = record.difficultyClass,
            origin = record.origin,
            request_id = record.requestId,
            specialist = record.specialist,
            specialist_score = record.specialistScore,
            target = record.target,
            tool_owner = record.tool.owner,
        })

        api.Schedule(settings.DELEGATION_ROLL_TIMEOUT_MS, function()
            if record.phase == "roll"
                and pendingByRoll[rollKey(record.eventName, record.specialist, record.target)] == record then
                abort(record, "roll_timeout")
            end
        end)
    end

    local function beginPermission(record)
        if pendingByTarget[actionTargetKey(record.action, record.target)] ~= record then
            return false
        end
        if not api.IsActionAvailable(record.action, record.target) then
            abort(record, "target_no_longer_available")
            return false
        end

        -- Each attempt watches for a competing same-target interaction.
        -- Contention seen during this specific attempt is what distinguishes a
        -- concurrency-corrupted rejection from a genuine permission denial.
        record.contended = false
        record.permissionAttempts = (record.permissionAttempts or 0) + 1

        local requestId = allocateRequestId()
        record.phase = "permission"
        record.requestId = requestId
        -- Permission/crime remains owned by the initiating character so
        -- stealth, visibility, and ownership checks use the player's active
        -- interaction context. Only the eventual skill roll is delegated.
        pendingByPermissionRequest[requestKey(record.initiator, requestId)] = record

        diagnostics.Info("delegated_permission_requested", {
            action = record.action,
            actor = record.initiator,
            origin = record.origin,
            permission_actor = record.initiator,
            request_id = requestId,
            specialist = record.specialist,
            target = record.target,
            tool = record.tool.item,
            tool_owner = record.tool.owner,
            tool_template = record.tool.template,
        })

        if not api.ProcessActionPermission(record.action, record.initiator, record.target, requestId) then
            abort(record, "permission_request_failed")
            return false
        end

        api.Schedule(settings.ACTION_PERMISSION_TIMEOUT_MS, function()
            if record.phase == "permission"
                and pendingByPermissionRequest[requestKey(record.initiator, requestId)] == record then
                abort(record, "permission_timeout")
            end
        end)
        return true
    end

    function instance.OnNativeRequest(action, actor, target, requestId)
        local key = actionTargetKey(action, target)
        local existing = pendingByTarget[key]
        if existing ~= nil then
            -- A failed normal interaction may be followed by an engine-native
            -- lockpick request before the private permission response arrives.
            -- Reject that initiator-owned roll without replacing the quick
            -- record; the correlated specialist path remains authoritative.
            if existing.origin == "quick" or existing.initiator ~= actor then
                local blocked = api.BlockNativeAction(action, actor, target)
                diagnostics.Trace("native_roll_suppressed", {
                    action = action,
                    actor = actor,
                    blocked = blocked and 1 or 0,
                    existing_actor = existing.initiator,
                    existing_origin = existing.origin,
                    phase = existing.phase,
                    request_id = requestId,
                    specialist = existing.specialist,
                    target = target,
                })
                return blocked
            end
            diagnostics.Trace("delegation_duplicate_ignored", {
                action = action,
                actor = actor,
                request_id = requestId,
                target = target,
            })
            return false
        end

        local record, reason = prepare(action, actor, target, requestId, "native", true)
        if record == nil then
            if reason ~= "initiator_is_specialist" then
                diagnostics.Warn("delegation_skipped", {
                    action = action,
                    actor = actor,
                    reason = reason,
                    request_id = requestId,
                    target = target,
                })
            end
            return false
        end

        if not api.BlockNativeAction(action, actor, target) then
            return false
        end

        record.phase = "native_block"
        pendingByTarget[key] = record
        pendingByNativeRequest[requestKey(actor, requestId)] = record
        diagnostics.Info("native_roll_delegated", {
            action = action,
            actor = actor,
            actor_score = record.initiatorScore,
            request_id = requestId,
            specialist = record.specialist,
            specialist_score = record.specialistScore,
            target = target,
        })

        api.Schedule(settings.ACTION_PERMISSION_TIMEOUT_MS, function()
            if record.phase == "native_block"
                and pendingByNativeRequest[requestKey(actor, requestId)] == record then
                abort(record, "native_response_timeout")
            end
        end)
        return true
    end

    function instance.OnUseFinished(actor, target, success)
        local openKey = openingKey(actor, target)
        if opening[openKey] == true then
            opening[openKey] = nil
            diagnostics.Trace("quick_lockpick_open_finished", {
                actor = actor,
                success = success,
                target = target,
            })
            return false
        end
        if success ~= 0 or not api.IsActionAvailable("lockpick", target) then
            return false
        end
        if api.IsInCombat(actor) then
            diagnostics.Trace("quick_lockpick_skipped", {
                actor = actor,
                reason = "combat",
                target = target,
            })
            return false
        end
        if forcedTurnBased[actor] == true then
            diagnostics.Trace("quick_lockpick_skipped", {
                actor = actor,
                reason = "forced_turn_based",
                target = target,
            })
            return false
        end

        local key = actionTargetKey("lockpick", target)
        if pendingByTarget[key] ~= nil then
            diagnostics.Trace("quick_lockpick_duplicate_ignored", {
                actor = actor,
                target = target,
            })
            return false
        end

        local record, reason = prepare("lockpick", actor, target, 0, "quick", false)
        if record == nil then
            diagnostics.Warn("quick_lockpick_skipped", {
                actor = actor,
                reason = reason,
                target = target,
            })
            return false
        end

        pendingByTarget[key] = record
        record.phase = "permission_queued"
        -- Do not enter story crime procedures from inside the UseFinished
        -- callback stack. Let the event unwind, then request permission on the
        -- next timer turn so RequestProcessed can be delivered normally.
        api.Schedule(0, function()
            if record.phase == "permission_queued"
                and pendingByTarget[key] == record then
                beginPermission(record)
            end
        end)
        return true
    end

    function instance.OnCompetingUse(target)
        -- A queued Use order (for example, from spam-clicking) that lands on a
        -- target while its delegated permission request is in flight makes
        -- vanilla reject that private response. Record the contention so the
        -- rejection can be told apart from a genuine permission denial and the
        -- delegation re-driven once rather than torn down.
        for _, record in pairs(pendingByTarget) do
            if record.target == target and record.phase == "permission" then
                record.contended = true
            end
        end
    end

    function instance.OnRequestProcessed(actor, requestId, accepted)
        local key = requestKey(actor, requestId)
        local native = pendingByNativeRequest[key]
        if native ~= nil and native.phase == "native_block" then
            pendingByNativeRequest[key] = nil
            if accepted ~= 0 then
                abort(native, "native_block_not_honoured")
                return true
            end

            native.phase = "native_blocked"
            -- Wait until vanilla has removed the one-shot custom response row
            -- before rerunning the permission pipeline as the initiator; only
            -- the active roll that follows is delegated to the specialist.
            api.Schedule(0, function()
                if native.phase == "native_blocked" then
                    beginPermission(native)
                end
            end)
            return true
        end

        local permission = pendingByPermissionRequest[key]
        if permission == nil or permission.phase ~= "permission" then
            return false
        end
        pendingByPermissionRequest[key] = nil
        if accepted == 0 then
            -- A competing same-target Use that landed during this permission
            -- window can make vanilla reject the private response even though
            -- the initiator was never actually denied. When that contention is
            -- what happened, keep the target reserved and re-drive the same
            -- delegation once the queued Use has drained, instead of aborting
            -- and letting a trailing UseFinished restart from scratch (which
            -- reads on screen as the check opening and immediately closing).
            -- A genuine denial carries no contention and still aborts here.
            if permission.contended
                and permission.permissionAttempts < MAX_PERMISSION_ATTEMPTS
                and api.IsActionAvailable(permission.action, permission.target)
                and pendingByTarget[actionTargetKey(permission.action, permission.target)] == permission then
                permission.phase = "permission_queued"
                diagnostics.Trace("delegated_permission_redrive", {
                    action = permission.action,
                    actor = permission.initiator,
                    attempt = permission.permissionAttempts,
                    origin = permission.origin,
                    specialist = permission.specialist,
                    target = permission.target,
                })
                api.Schedule(0, function()
                    if permission.phase == "permission_queued"
                        and pendingByTarget[actionTargetKey(permission.action, permission.target)] == permission then
                        beginPermission(permission)
                    end
                end)
                return true
            end
            abort(permission, "permission_blocked")
            return true
        end

        permission.phase = "roll_pending"
        -- Leave the nested story-procedure/RequestProcessed stack before
        -- opening active-roll UI.
        api.Schedule(0, function()
            startRoll(permission)
        end)
        return true
    end

    function instance.OnRollResult(eventName, actor, target, result)
        local record = pendingByRoll[rollKey(eventName, actor, target)]
        if record == nil or record.phase ~= "roll" then
            return false
        end
        clear(record)
        record.phase = "finished"

        if result == 1 then
            local completed = api.CompleteAction(record.action, record.target, record.specialist)
            local disarmNotified = false
            if completed and record.action == "disarm" then
                -- The custom active roll does not emit vanilla's disarm
                -- outcome event. Preserve the initiating character as the
                -- story actor while allowing the trap's own scripts to handle
                -- destruction, persistence, and other success behavior.
                disarmNotified = api.NotifyDisarmAttempt(
                    record.target,
                    record.initiator,
                    record.tool.item,
                    true
                )
            end
            local opened = false
            if completed and record.action == "lockpick" then
                local key = openingKey(record.initiator, record.target)
                opening[key] = true
                opened = api.UseTarget(record.initiator, record.target, "BestOfHands_Delegated_Open")
                if not opened then
                    opening[key] = nil
                else
                    api.Schedule(settings.QUICK_LOCKPICK_OPEN_TIMEOUT_MS, function()
                        opening[key] = nil
                    end)
                end
            end
            diagnostics.Info("delegated_action_succeeded", {
                action = record.action,
                actor = record.initiator,
                completed = completed and 1 or 0,
                disarm_notified = disarmNotified and 1 or 0,
                opened = opened and 1 or 0,
                origin = record.origin,
                specialist = record.specialist,
                target = record.target,
            })
        elseif result == 0 then
            local disarmNotified = false
            if record.action == "disarm" then
                -- Notify while the concrete toolkit still exists so native
                -- trap failure handlers receive the same event payload as a
                -- normal failed attempt. Resource consumption remains paired
                -- with the recorded owner/template immediately afterward.
                disarmNotified = api.NotifyDisarmAttempt(
                    record.target,
                    record.initiator,
                    record.tool.item,
                    false
                )
            end
            local consumed = api.ConsumeActionTool(record.tool)
            diagnostics.Info("delegated_action_failed", {
                action = record.action,
                actor = record.initiator,
                disarm_notified = disarmNotified and 1 or 0,
                origin = record.origin,
                specialist = record.specialist,
                target = record.target,
                tool_consumed = consumed and 1 or 0,
                tool_owner = record.tool.owner,
                tool_template = record.tool.template,
            })
        else
            diagnostics.Info("delegated_action_cancelled", {
                action = record.action,
                actor = record.initiator,
                origin = record.origin,
                specialist = record.specialist,
                target = record.target,
            })
        end
        return true
    end

    function instance.OnNativeStarted(action, actor, target)
        for _, record in pairs(pendingByTarget) do
            if record.action == action
                and record.target == target then
                abort(record, "native_action_started")
                return true
            end
        end
        return false
    end

    function instance.OnNativeStopped(action, actor, target)
        -- A native request that Best of Hands deliberately rejects may still
        -- report its task stopping while the delegated permission request is
        -- queued. Started* is the authoritative duplicate-action signal;
        -- Stopped* is retained for trace visibility only.
        return false
    end

    function instance.OnEnteredForceTurnBased(actor)
        forcedTurnBased[actor] = true
    end

    function instance.OnLeftForceTurnBased(actor)
        forcedTurnBased[actor] = nil
    end

    function instance.Count()
        local count = 0
        for _, _ in pairs(pendingByTarget) do
            count = count + 1
        end
        return count
    end

    return instance
end

return InteractionCoordinator
