-- SPDX-License-Identifier: Unlicense

local NativeBridge = {}

local ACTION_FILE = "BestOfHandsNative.actions"
local STATUS_FILE = "BestOfHandsNative.status"
local PROTOCOL = "8"
local DELEGATED_ROLL_HOOKS =
    "profile_ui,profile_math,client_roll_presentation,"
    .. "client_roll_aggregate,client_roll_start,"
    .. "client_roll_payload_ready,client_roll_post_dispatch,"
    .. "client_roll_result"
    .. ",client_roll_bonus_reconcile_start"
    .. ",client_roll_bonus_reconcile_viewmodel"
    .. ",client_roll_bonus_preserve_matched"
    .. ",client_roll_bonus_preserve_missing"
    .. ",client_advantage_preserve_matched"
    .. ",client_advantage_preserve_missing"
    .. ",client_roll_bonus_keep_selected"
    .. ",client_roll_bonus_renderer_add"
    .. ",client_roll_bonus_retain_selected"
    .. ",client_roll_bonus_presentation_transfer"
    .. ",client_roll_bonus_reconcile_end"
    .. ",client_roll_finalize"
local QUICK_LOCKPICK_HOOKS =
    "client_task_selection,client_input_controller_update,"
    .. "client_get_character_task,client_set_running_task"
local REQUIRED_FEATURES = "native_profile_substitution,quick_lockpick_task_adapter"

NativeBridge.REQUIRED_HOOKS = DELEGATED_ROLL_HOOKS
NativeBridge.DELEGATED_ROLL_HOOKS = DELEGATED_ROLL_HOOKS
NativeBridge.QUICK_LOCKPICK_HOOKS = QUICK_LOCKPICK_HOOKS
NativeBridge.REQUIRED_FEATURES = REQUIRED_FEATURES

local function parseDocument(text)
    local result = {}
    if type(text) ~= "string" then
        return result
    end
    for line in text:gmatch("[^\r\n]+") do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key ~= nil then
            if result[key] ~= nil then
                return {}
            end
            result[key] = value
        end
    end
    return result
end

local function safeField(value, field)
    local ok, result = pcall(function() return value[field] end)
    return ok and result or nil
end

local function entityHandle(value)
    if value == nil then
        return nil
    end
    local direct = tostring(value):match("Entity %((%x+)%)")
    if direct ~= nil then
        return direct
    end
    local ok, entity = pcall(Ext.Entity.Get, value)
    if not ok or entity == nil then
        return nil
    end
    return tostring(entity):match("Entity %((%x+)%)")
end

local function entityIdentity(value)
    if value == nil then
        return nil, nil
    end
    local handle = tostring(value):match("Entity %((%x+)%)")
    local uuidComponent = safeField(value, "Uuid")
    local uuid = uuidComponent
        and safeField(uuidComponent, "EntityUuid")
        or nil
    if handle ~= nil and uuid ~= nil then
        return handle, tostring(uuid)
    end
    local ok, entity = pcall(Ext.Entity.Get, value)
    if not ok or entity == nil then
        return handle, uuid ~= nil and tostring(uuid) or nil
    end
    handle = handle or tostring(entity):match("Entity %((%x+)%)")
    if uuid == nil then
        uuidComponent = safeField(entity, "Uuid")
        uuid = uuidComponent
            and safeField(uuidComponent, "EntityUuid")
            or nil
    end
    return handle, uuid ~= nil and tostring(uuid) or nil
end

local function stableRecords(records)
    local values = {}
    for _, record in pairs(records) do
        values[#values + 1] = record
    end
    table.sort(values, function(left, right)
        return left.id < right.id
    end)
    return values
end

local function uniqueProbe(generation)
    local clock = "no-clock"
    if Ext.Utils ~= nil and type(Ext.Utils.MonotonicTime) == "function" then
        local ok, value = pcall(Ext.Utils.MonotonicTime)
        if ok then
            clock = tostring(value)
        end
    end
    return table.concat({
        clock,
        tostring(generation),
        tostring({}):gsub("[^%x]", ""),
    }, "-")
end

function NativeBridge.Create(settings, api, diagnostics)
    local instance = {}
    local records = {}
    local ready = false
    local capabilities = {
        delegated_roll = { ready = false, reason = "not_started", source = "none" },
        quick_lockpick = { ready = false, reason = "not_started", source = "none" },
    }
    local trace = settings.TRACE_EVENTS == true
    local probe = nil
    local nativeSession = ""
    local state = "not_started"
    local detail = "handshake has not started"
    local warningShownGeneration = {}
    local warningExhaustedGeneration = {}
    local warningRetryGeneration = {}
    local handshakeGeneration = 0
    local visibleWarning

    local function save()
        local lines = {
            "protocol=" .. PROTOCOL,
            "pak_version=" .. settings.VERSION,
            "probe=" .. tostring(probe or "not-started"),
            "native_session=" .. nativeSession,
            "trace=" .. (trace and "1" or "0"),
        }
        for _, record in ipairs(stableRecords(records)) do
            lines[#lines + 1] = table.concat({
                "record=" .. tostring(record.id),
                record.action,
                record.initiatorHandle,
                record.specialistHandle,
                record.targetHandle,
                record.rollHandle or "0",
                record.finishedEventHandle or "0",
                record.rollUuid or "0",
                record.initiatorUuid,
                record.specialistUuid,
                record.targetUuid,
                tostring(record.presentationAdvantage or -1),
            }, "\t")
        end
        lines[#lines + 1] = "end=1"
        local ok, result = pcall(Ext.IO.SaveFile, ACTION_FILE, table.concat(lines, "\n") .. "\n")
        if not ok or result == false then
            diagnostics.Error("native_bridge_write_failed", {
                error = ok and "save_returned_false" or result,
                file = ACTION_FILE,
            })
            ready = false
            state = "bridge_write_failed"
            detail = "Script Extender could not write the native bridge file"
            for _, capability in pairs(capabilities) do
                capability.ready = false
                capability.state = "unavailable"
                capability.reason = "bridge_write_failed"
            end
            if visibleWarning ~= nil then
                visibleWarning()
            end
            return false
        end
        return true
    end

    local function capabilityMessage(name)
        local capability = capabilities[name]
        local label = name == "quick_lockpick"
            and "Quick Lockpick / left-click integration"
            or "Best-in-party delegated rolls"
        local otherName = name == "quick_lockpick" and "delegated_roll" or "quick_lockpick"
        local fallback = capabilities[otherName].ready
            and "Other validated Best of Hands features remain enabled."
            or "Normal Baldur's Gate 3 behavior remains available for affected actions."
        return table.concat({
            "Best of Hands " .. tostring(settings.VERSION) .. ": " .. label
                .. " is unavailable for this session.",
            fallback,
            "Reason: " .. tostring(capability.reason or state),
            "Detected game: " .. tostring(capability.executable or "unknown")
                .. " (" .. tostring(capability.gameVersion or "version unavailable") .. ")",
            "Update Best of Hands after a BG3 patch, and verify Native Mod Loader is current.",
        }, "\n")
    end

    visibleWarning = function()
        local generation = handshakeGeneration
        local function warnCapability(name)
            local warningKey = tostring(capabilities[name].reason)
                .. "|" .. tostring(capabilities[name].executable)
            if capabilities[name].ready
                or capabilities[name].state == "pending"
                or warningShownGeneration[name] == warningKey
                or warningExhaustedGeneration[name] == generation
                or warningRetryGeneration[name] == generation then
                return
            end
            local attempts = math.max(1,
                tonumber(settings.NATIVE_WARNING_ATTEMPTS) or 3)
            local retryMs = math.max(1,
                tonumber(settings.NATIVE_WARNING_RETRY_MS) or 500)
            local function attempt(remaining)
                if generation ~= handshakeGeneration
                    or capabilities[name].ready
                    or warningShownGeneration[name] == warningKey
                    or warningExhaustedGeneration[name] == generation then
                    return
                end

                local message = capabilityMessage(name)
                local ok, errorMessage = pcall(function()
                    local host = Osi.GetHostCharacter()
                    if host ~= nil and tostring(host) ~= "" then
                        Osi.OpenMessageBox(host, message)
                    else
                        error("host character unavailable")
                    end
                end)
                if ok then
                    warningShownGeneration[name] = warningKey
                    warningRetryGeneration[name] = nil
                    return
                end

                diagnostics.Error("native_bridge_warning_failed", {
                    error = errorMessage,
                    capability = name,
                    generation = generation,
                    remaining = remaining - 1,
                })
                if remaining <= 1 then
                    warningRetryGeneration[name] = nil
                    warningExhaustedGeneration[name] = generation
                    return
                end
                warningRetryGeneration[name] = generation
                api.Schedule(retryMs, function()
                    if warningRetryGeneration[name] == generation then
                        warningRetryGeneration[name] = nil
                    end
                    attempt(remaining - 1)
                end)
            end
            attempt(attempts)
        end
        warnCapability("quick_lockpick")
        warnCapability("delegated_roll")
    end

    local function readCapabilities(status)
        local common = {
            executable = status.executable,
            gameVersion = status.product_version or status.file_version,
        }
        for _, name in ipairs({ "quick_lockpick", "delegated_roll" }) do
            local prefix = "cap_" .. name
            local declaredState = status[prefix] or "unavailable"
            local expectedHooks = name == "quick_lockpick"
                and QUICK_LOCKPICK_HOOKS or DELEGATED_ROLL_HOOKS
            local source = status[prefix .. "_source"] or "none"
            local validReady = declaredState == "ready"
                and status[prefix .. "_hooks"] == expectedHooks
                and (source == "exact_table" or source == "structural_compatibility")
            capabilities[name] = {
                ready = validReady,
                state = declaredState == "ready" and not validReady
                    and "unavailable" or declaredState,
                reason = declaredState == "ready" and not validReady
                    and "capability_manifest_invalid"
                    or status[prefix .. "_reason"] or status.detail or status.state,
                source = source,
                executable = common.executable,
                gameVersion = common.gameVersion,
            }
        end
    end

    local function statusEnvelopeIsCurrent(status, requireSession)
        local validState = status.state == "ready"
            or status.state == "partial"
            or status.state == "unavailable"
        return status.protocol == PROTOCOL
            and status.version == settings.VERSION
            and validState
            and status.features == REQUIRED_FEATURES
            and status.ack == probe
            and (not requireSession or (status.session ~= nil and status.session ~= ""))
            and status["end"] == "1"
    end

    local function invalidateCapabilities(reason)
        for _, capability in pairs(capabilities) do
            capability.ready = false
            capability.state = "unavailable"
            capability.reason = reason
        end
    end

    local function nativeStatusIsCurrent()
        local ok, text = pcall(Ext.IO.LoadFile, STATUS_FILE)
        local status = ok and parseDocument(text) or {}
        readCapabilities(status)
        local current = statusEnvelopeIsCurrent(status, false)
            and status.session == nativeSession
        if not current then
            ready = false
            state = status.state or "native_status_missing"
            detail = status.detail or "the native status file was not found"
            invalidateCapabilities("native_status_not_current")
            diagnostics.Error("native_bridge_lost", {
                detail = detail,
                hooks = status.hooks,
                native_session = status.session,
                state = state,
            })
            visibleWarning()
        end
        return current
    end

    local function poll(generation, remaining)
        if generation ~= handshakeGeneration then
            return
        end
        local ok, text = pcall(Ext.IO.LoadFile, STATUS_FILE)
        local status = ok and parseDocument(text) or {}
        state = status.state or "native_status_missing"
        detail = status.detail or "the native status file was not found"
        readCapabilities(status)
        local compatible = statusEnvelopeIsCurrent(status, true)
        if compatible then
            local wasReady = ready
            nativeSession = status.session
            ready = true
            state = "ready"
            detail = status.detail
            if not save() then
                return
            end
            if not wasReady then
                diagnostics.Info("native_bridge_ready", {
                    hooks = status.hooks,
                    delegated_roll = capabilities.delegated_roll.ready and 1 or 0,
                    native_pid = status.pid,
                    native_session = nativeSession,
                    protocol = status.protocol,
                    quick_lockpick = capabilities.quick_lockpick.ready and 1 or 0,
                    version = status.version,
                })
            end
            visibleWarning()
            if remaining > 0 and (capabilities.quick_lockpick.state == "pending"
                or capabilities.delegated_roll.state == "pending") then
                api.Schedule(settings.NATIVE_HANDSHAKE_POLL_MS, function()
                    poll(generation, remaining - 1)
                end)
            end
            return
        end
        if remaining <= 0 then
            ready = false
            invalidateCapabilities("native_handshake_unavailable")
            diagnostics.Error("native_bridge_unavailable", {
                detail = detail,
                hooks = status.hooks,
                protocol = status.protocol,
                state = state,
                version = status.version,
            })
            visibleWarning()
            return
        end
        api.Schedule(settings.NATIVE_HANDSHAKE_POLL_MS, function()
            poll(generation, remaining - 1)
        end)
    end

    function instance.BeginHandshake()
        handshakeGeneration = handshakeGeneration + 1
        ready = false
        capabilities = {
            delegated_roll = { ready = false, reason = "waiting_for_native_ack", source = "none" },
            quick_lockpick = { ready = false, reason = "waiting_for_native_ack", source = "none" },
        }
        records = {}
        nativeSession = ""
        state = "waiting_for_native_ack"
        detail = "waiting for BestofHands.dll"
        probe = uniqueProbe(handshakeGeneration)
        if not save() then
            return false
        end
        poll(handshakeGeneration, settings.NATIVE_HANDSHAKE_ATTEMPTS)
        return true
    end

    function instance.IsReady()
        return ready and capabilities.delegated_roll.ready
    end

    function instance.IsCapabilityReady(name)
        if ready then
            nativeStatusIsCurrent()
        end
        local capability = capabilities[name]
        return ready and capability ~= nil and capability.ready == true
    end

    function instance.SetTrace(enabled)
        trace = enabled == true
        return save()
    end

    function instance.Upsert(record)
        if not ready or not capabilities.delegated_roll.ready
            or not nativeStatusIsCurrent() then
            return false, "native_bridge_not_ready"
        end
        local initiatorHandle, initiatorUuid = entityIdentity(record.initiator)
        local specialistHandle, specialistUuid = entityIdentity(record.specialist)
        local targetHandle, targetUuid = entityIdentity(record.target)
        if initiatorHandle == nil
            or specialistHandle == nil
            or targetHandle == nil
            or initiatorUuid == nil
            or specialistUuid == nil
            or targetUuid == nil then
            return false, "entity_handle_unavailable"
        end
        records[record.id] = {
            action = record.action,
            id = record.id,
            initiatorHandle = initiatorHandle,
            specialistHandle = specialistHandle,
            targetHandle = targetHandle,
            rollHandle = "0",
            finishedEventHandle = "0",
            rollUuid = "0",
            initiatorUuid = initiatorUuid,
            specialistUuid = specialistUuid,
            targetUuid = targetUuid,
            presentationAdvantage = -1,
        }
        if not save() then
            records[record.id] = nil
            return false, "native_bridge_write_failed"
        end
        return true, nil, records[record.id]
    end

    function instance.SetRoll(id, roll, rollUuid)
        if not ready or not capabilities.delegated_roll.ready then
            return false, "native_bridge_not_ready"
        end
        local record = records[id]
        if record == nil then
            return false, "native_record_unavailable"
        end
        local stableRollUuid = tostring(rollUuid or "0")
        if stableRollUuid ~= "0"
            and record.rollUuid == stableRollUuid
            and record.rollHandle ~= nil
            and record.rollHandle ~= "0" then
            return true, nil, record.rollHandle
        end
        if not nativeStatusIsCurrent() then
            return false, "native_bridge_not_ready"
        end
        local rollHandle = entityHandle(roll)
        if rollHandle == nil then
            return false, "roll_handle_unavailable"
        end
        record.rollHandle = rollHandle
        record.rollUuid = stableRollUuid
        if not save() then
            return false, "native_bridge_write_failed"
        end
        return true, nil, rollHandle
    end

    function instance.SetPresentation(id, advantageType)
        if not ready or not capabilities.delegated_roll.ready then
            return false, "native_bridge_not_ready"
        end
        local record = records[id]
        if record == nil then
            return false, "native_record_unavailable"
        end
        local value = tonumber(advantageType)
        if value == nil or value < 0 or value > 2 then
            return false, "presentation_advantage_invalid"
        end
        if record.presentationAdvantage == value then
            return true, nil
        end
        if not nativeStatusIsCurrent() then
            return false, "native_bridge_not_ready"
        end
        record.presentationAdvantage = value
        if not save() then
            return false, "native_bridge_write_failed"
        end
        return true, nil
    end

    function instance.SetFinishedEvent(id, eventEntity)
        if not ready or not capabilities.delegated_roll.ready then
            return false, "native_bridge_not_ready"
        end
        local record = records[id]
        if record == nil then
            return false, "native_record_unavailable"
        end
        local finishedEventHandle = entityHandle(eventEntity)
        if finishedEventHandle == nil then
            return false, "finished_event_handle_unavailable"
        end
        if record.finishedEventHandle == finishedEventHandle then
            return true, nil, finishedEventHandle
        end
        if not nativeStatusIsCurrent() then
            return false, "native_bridge_not_ready"
        end
        record.finishedEventHandle = finishedEventHandle
        if not save() then
            return false, "native_bridge_write_failed"
        end
        return true, nil, finishedEventHandle
    end

    function instance.Remove(id)
        local record = records[id]
        if record == nil then
            return false
        end
        records[id] = nil
        if not save() then
            records[id] = record
            return false
        end
        return true
    end

    function instance.Clear()
        local previous = records
        records = {}
        if not save() then
            records = previous
            return false
        end
        return true
    end

    function instance.GetStatus()
        return {
            capabilities = capabilities,
            detail = detail,
            nativeSession = nativeSession,
            ready = ready and capabilities.delegated_roll.ready,
            state = state,
        }
    end

    return instance
end

return NativeBridge
