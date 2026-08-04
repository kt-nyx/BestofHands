-- SPDX-License-Identifier: Unlicense

local NativeBridge = {}

local ACTION_FILE = "BestOfHandsNative.actions"
local STATUS_FILE = "BestOfHandsNative.status"
local PROTOCOL = "7"
local REQUIRED_HOOKS =
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
local REQUIRED_FEATURES =
    "native_profile_substitution,quick_lockpick_task_adapter"

NativeBridge.REQUIRED_HOOKS = REQUIRED_HOOKS
NativeBridge.REQUIRED_FEATURES = REQUIRED_FEATURES

local function parseDocument(text)
    local result = {}
    if type(text) ~= "string" then
        return result
    end
    for line in text:gmatch("[^\r\n]+") do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key ~= nil then
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
    local trace = settings.TRACE_EVENTS == true
    local probe = nil
    local nativeSession = ""
    local state = "not_started"
    local detail = "handshake has not started"
    local warningShownGeneration = nil
    local warningExhaustedGeneration = nil
    local warningRetryGeneration = nil
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
            if visibleWarning ~= nil then
                visibleWarning()
            end
            return false
        end
        return true
    end

    visibleWarning = function()
        local generation = handshakeGeneration
        if ready
            or warningShownGeneration == generation
            or warningExhaustedGeneration == generation
            or warningRetryGeneration == generation then
            return
        end

        local attempts = math.max(1,
            tonumber(settings.NATIVE_WARNING_ATTEMPTS) or 3)
        local retryMs = math.max(1,
            tonumber(settings.NATIVE_WARNING_RETRY_MS) or 500)
        local function attempt(remaining)
            if generation ~= handshakeGeneration
                or ready
                or warningShownGeneration == generation
                or warningExhaustedGeneration == generation then
                return
            end

            local message = table.concat({
                "Best of Hands " .. tostring(settings.VERSION)
                    .. " is disabled for this session.",
                "",
                "The required BestofHands.dll did not report compatible server profile, roll-math, and client roll-presentation hooks.",
                "Install the complete archive and update Native Mod Loader after game patches.",
                "",
                "Details: " .. tostring(state) .. " - " .. tostring(detail),
            }, "\n")
            local ok, errorMessage = pcall(function()
                local host = Osi.GetHostCharacter()
                if host ~= nil and tostring(host) ~= "" then
                    Osi.OpenMessageBox(host, message)
                else
                    error("host character unavailable")
                end
            end)
            if ok then
                warningShownGeneration = generation
                warningRetryGeneration = nil
                return
            end

            diagnostics.Error("native_bridge_warning_failed", {
                error = errorMessage,
                generation = generation,
                remaining = remaining - 1,
            })
            if remaining <= 1 then
                warningRetryGeneration = nil
                warningExhaustedGeneration = generation
                return
            end
            warningRetryGeneration = generation
            api.Schedule(retryMs, function()
                if warningRetryGeneration == generation then
                    warningRetryGeneration = nil
                end
                attempt(remaining - 1)
            end)
        end
        attempt(attempts)
    end

    local function nativeStatusIsCurrent()
        local ok, text = pcall(Ext.IO.LoadFile, STATUS_FILE)
        local status = ok and parseDocument(text) or {}
        local current = status.protocol == PROTOCOL
            and status.version == settings.VERSION
            and status.state == "ready"
            and status.hooks == REQUIRED_HOOKS
            and status.features == REQUIRED_FEATURES
            and status.session == nativeSession
            and status.ack == probe
            and status["end"] == "1"
        if not current then
            ready = false
            state = status.state or "native_status_missing"
            detail = status.detail or "the native status file was not found"
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
        if generation ~= handshakeGeneration or ready then
            return
        end
        local ok, text = pcall(Ext.IO.LoadFile, STATUS_FILE)
        local status = ok and parseDocument(text) or {}
        state = status.state or "native_status_missing"
        detail = status.detail or "the native status file was not found"
        local compatible = status.protocol == PROTOCOL
            and status.version == settings.VERSION
            and status.state == "ready"
            and status.hooks == REQUIRED_HOOKS
            and status.features == REQUIRED_FEATURES
            and status.ack == probe
            and status.session ~= nil
            and status.session ~= ""
            and status["end"] == "1"
        if compatible then
            nativeSession = status.session
            ready = true
            state = "ready"
            detail = status.detail
            if not save() then
                return
            end
            diagnostics.Info("native_bridge_ready", {
                hooks = status.hooks,
                native_pid = status.pid,
                native_session = nativeSession,
                protocol = status.protocol,
                version = status.version,
            })
            return
        end
        if remaining <= 0 then
            ready = false
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
        return ready
    end

    function instance.SetTrace(enabled)
        trace = enabled == true
        return save()
    end

    function instance.Upsert(record)
        if not ready or not nativeStatusIsCurrent() then
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
        if not ready then
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
        if not ready then
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
        if not ready then
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
            detail = detail,
            nativeSession = nativeSession,
            ready = ready,
            state = state,
        }
    end

    return instance
end

return NativeBridge
