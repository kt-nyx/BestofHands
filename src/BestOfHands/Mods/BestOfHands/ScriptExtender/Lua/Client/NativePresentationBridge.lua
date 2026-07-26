-- SPDX-License-Identifier: Unlicense

local NativePresentationBridge = {}
local ACTION_FILE = "BestOfHandsNative.actions"
local CLIENT_FILE = "BestOfHandsNative.client"
local PROTOCOL = "5"
local GUID_PATTERN = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"

local function objectGuid(value)
    if value == nil then
        return nil
    end
    return tostring(value):lower():match(GUID_PATTERN)
end

local function safeField(value, field)
    local ok, result = pcall(function() return value[field] end)
    return ok and result or nil
end

local function entityHandle(value)
    local ok, entity = pcall(Ext.Entity.Get, value)
    if not ok or entity == nil then
        return nil
    end
    return tostring(entity):match("Entity %((%x+)%)")
end

local function objectPointer(value)
    if value == nil then
        return nil
    end
    return tostring(value):match("%((%x+)")
end

local function entityGuid(value)
    local ok, result = pcall(function()
        local entity = Ext.Entity.Get(value)
        return entity and entity.Uuid and tostring(entity.Uuid.EntityUuid) or nil
    end)
    return ok and result or nil
end

local function actionFromRoll(component)
    local context = tonumber(safeField(component, "RollContext"))
    if context == 5 then
        return "disarm"
    elseif context == 6 then
        return "lockpick"
    end
    return nil
end

local function splitTabs(value)
    local fields = {}
    for field in (value .. "\t"):gmatch("(.-)\t") do
        fields[#fields + 1] = field
    end
    return fields
end

local function stableValue(value)
    if value == nil then
        return "null"
    end
    return tostring(value):gsub("[\r\n|]", " ")
end

local function write(event, fields)
    local keys = {}
    for key, _ in pairs(fields or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    local values = {}
    for _, key in ipairs(keys) do
        values[#values + 1] = tostring(key) .. "=" .. stableValue(fields[key])
    end
    local line = "[best_of_hands_client]|TRACE|" .. event
    if #values > 0 then
        line = line .. "|" .. table.concat(values, "|")
    end
    Ext.Utils.Print(line)
end

function NativePresentationBridge.Start(settings, quickLockpickChannel)
    local instance = {}
    local tracked = {}
    local clientRecords = {}
    local quickRequests = {}
    local lastSession = ""
    local lastProbe = ""
    local traceEnabled = settings.TRACE_EVENTS == true

    local function loadActions()
        local ok, text = pcall(Ext.IO.LoadFile, ACTION_FILE)
        if not ok or type(text) ~= "string" then
            return nil
        end
        local protocol = text:match("[\r\n]?protocol=([^\r\n]+)")
        local version = text:match("[\r\n]?pak_version=([^\r\n]+)")
        local probe = text:match("[\r\n]?probe=([^\r\n]+)") or ""
        local session = text:match("[\r\n]?native_session=([^\r\n]+)") or ""
        local complete = text:match("[\r\n]end=1[\r\n]?") ~= nil
        traceEnabled = text:match("[\r\n]?trace=(%d)") == "1"
        if protocol ~= PROTOCOL
            or version ~= settings.VERSION
            or probe == ""
            or session == ""
            or not complete then
            return nil
        end
        if lastSession ~= session or lastProbe ~= probe then
            lastSession = session
            lastProbe = probe
            tracked = {}
            clientRecords = {}
            quickRequests = {}
        end
        local records = { all = {}, byDelegationId = {}, byRollUuid = {} }
        for line in text:gmatch("[^\r\n]+") do
            if line:sub(1, 7) == "record=" then
                local fields = splitTabs(line:sub(8))
                if #fields >= 12 then
                    local record = {
                        action = fields[2],
                        delegationId = fields[1],
                        initiatorUuid = objectGuid(fields[9]),
                        specialistUuid = objectGuid(fields[10]),
                        targetUuid = objectGuid(fields[11]),
                        rollUuid = objectGuid(fields[8]),
                        presentationAdvantage = tonumber(fields[12]),
                    }
                    if record.initiatorUuid ~= nil
                        and record.specialistUuid ~= nil
                        and record.targetUuid ~= nil then
                        records.all[#records.all + 1] = record
                        records.byDelegationId[record.delegationId] = record
                        if record.rollUuid ~= nil then
                            records.byRollUuid[record.rollUuid] = record
                        end
                    end
                end
            end
        end
        return records
    end

    local function saveClientRecords()
        if lastSession == "" then
            return false
        end
        local values = {}
        for _, record in pairs(clientRecords) do
            values[#values + 1] = record
        end
        table.sort(values, function(left, right)
            return tonumber(left.delegationId) < tonumber(right.delegationId)
        end)
        local lines = {
            "protocol=" .. PROTOCOL,
            "pak_version=" .. settings.VERSION,
            "native_session=" .. lastSession,
            "trace=" .. (traceEnabled and "1" or "0"),
        }
        for _, record in ipairs(values) do
            lines[#lines + 1] = table.concat({
                "record=" .. record.delegationId,
                record.rollUuid,
                record.initiatorHandle,
                record.specialistHandle,
                record.targetHandle,
            }, "\t")
        end
        local quickValues = {}
        for _, record in pairs(quickRequests) do
            quickValues[#quickValues + 1] = record
        end
        table.sort(quickValues, function(left, right)
            return left.request < right.request
        end)
        for _, record in ipairs(quickValues) do
            lines[#lines + 1] = table.concat({
                "quick=" .. record.request,
                record.controller,
                record.task,
                record.initiator,
                record.target,
            }, "\t")
        end
        lines[#lines + 1] = "end=1"
        local ok, result = pcall(
            Ext.IO.SaveFile,
            CLIENT_FILE,
            table.concat(lines, "\n") .. "\n"
        )
        if not ok or result == false then
            write("client_profile_bridge_write_failed", {
                error = ok and "save_returned_false" or result,
                file = CLIENT_FILE,
            })
            return false
        end
        return true
    end

    local function classify(entity, component)
        local key = tostring(entity)
        if tracked[key] ~= nil then
            return tracked[key]
        end
        local action = actionFromRoll(component)
        if action == nil then
            return nil
        end
        local records = loadActions()
        if records == nil then
            return nil
        end
        local rollUuid = objectGuid(safeField(component, "RollUuid"))
        local record = rollUuid and records.byRollUuid[rollUuid] or nil
        if record == nil then
            local initiatorUuid = objectGuid(entityGuid(safeField(component, "Roller")))
            local targetUuid = objectGuid(entityGuid(safeField(component, "Subject")))
            for _, candidate in ipairs(records.all) do
                if candidate.action == action
                    and candidate.initiatorUuid == initiatorUuid
                    and candidate.targetUuid == targetUuid then
                    record = candidate
                    break
                end
            end
        end
        if record == nil or record.action ~= action then
            return nil
        end
        record.profileMode = "delegated"
        tracked[key] = record
        return record
    end

    local function mapClientProfile(entity, component)
        local record = classify(entity, component)
        if record == nil or record.rollUuid == nil then
            return nil
        end
        local previous = clientRecords[record.delegationId]
        if previous ~= nil and previous.rollUuid == record.rollUuid then
            record.initiatorHandle = previous.initiatorHandle
            record.specialistHandle = previous.specialistHandle
            record.targetHandle = previous.targetHandle
            return record
        end
        local initiatorHandle = entityHandle(safeField(component, "Roller"))
        local targetHandle = entityHandle(safeField(component, "Subject"))
        local specialistHandle = entityHandle(record.specialistUuid)
        if initiatorHandle == nil
            or specialistHandle == nil
            or targetHandle == nil then
            write("client_profile_mapping_failed", {
                action = record.action,
                delegation_id = record.delegationId,
                initiator_handle = initiatorHandle,
                reason = "client_entity_handle_unavailable",
                roll_uuid = record.rollUuid,
                specialist_handle = specialistHandle,
                target_handle = targetHandle,
            })
            return record
        end
        local mapped = {
            action = record.action,
            delegationId = record.delegationId,
            initiatorHandle = initiatorHandle:lower(),
            presentationAdvantage = record.presentationAdvantage,
            rollUuid = record.rollUuid,
            specialistHandle = specialistHandle:lower(),
            targetHandle = targetHandle:lower(),
        }
        clientRecords[record.delegationId] = mapped
        if previous == nil
            or previous.rollUuid ~= mapped.rollUuid
            or previous.initiatorHandle ~= mapped.initiatorHandle
            or previous.specialistHandle ~= mapped.specialistHandle
            or previous.targetHandle ~= mapped.targetHandle then
            if saveClientRecords() and traceEnabled then
                write("client_profile_mapping_written", {
                    action = record.action,
                    delegation_id = record.delegationId,
                    initiator_handle = mapped.initiatorHandle,
                    roll_uuid = mapped.rollUuid,
                    specialist = record.specialistUuid,
                    specialist_handle = mapped.specialistHandle,
                    target_handle = mapped.targetHandle,
                })
            end
        end
        record.initiatorHandle = mapped.initiatorHandle
        record.rollHandle = entityHandle(entity)
        record.specialistHandle = mapped.specialistHandle
        record.targetHandle = mapped.targetHandle
        return record
    end

    local function removeClientProfile(entity, component)
        local key = tostring(entity)
        local record = tracked[key]
        local rollUuid = objectGuid(
            component and safeField(component, "RollUuid") or nil
        )
        if record == nil and rollUuid ~= nil then
            for _, candidate in pairs(clientRecords) do
                if candidate.rollUuid == rollUuid then
                    record = candidate
                    break
                end
            end
        end
        tracked[key] = nil
        if record == nil then
            return false
        end
        local removed = clientRecords[record.delegationId]
        clientRecords[record.delegationId] = nil
        local saved = removed == nil or saveClientRecords()
        if traceEnabled then
            write("client_profile_mapping_removed", {
                action = record.action,
                delegation_id = record.delegationId,
                reason = "requested_roll_destroyed",
                roll_entity = tostring(entity),
                roll_uuid = rollUuid or record.rollUuid,
                saved = saved and 1 or 0,
            })
        end
        return true
    end

    function instance.GetRecord(entity, component)
        return mapClientProfile(entity, component)
    end

    function instance.RefreshRecord(record)
        if record == nil or record.delegationId == nil then
            return record
        end
        local records = loadActions()
        local fresh = records
            and records.byDelegationId[tostring(record.delegationId)]
            or nil
        if fresh == nil
            or fresh.action ~= record.action
            or (record.rollUuid ~= nil
                and fresh.rollUuid ~= nil
                and fresh.rollUuid ~= record.rollUuid) then
            return record
        end
        record.presentationAdvantage = fresh.presentationAdvantage
        return record
    end

    function instance.IsTraceEnabled()
        return traceEnabled
    end

    local function protected(event, callback)
        return function(...)
            local ok, errorMessage = xpcall(
                callback, debug.traceback, ...)
            if not ok then
                write(event, { error = errorMessage })
            end
        end
    end

    local function prepareQuickLockpick(data)
        if type(data) ~= "table"
            or type(data.request) ~= "string"
            or not data.request:match("^[%w%.%-]+$")
            or objectGuid(data.actor) == nil
            or objectGuid(data.target) == nil then
            return false, "invalid_request"
        end
        if loadActions() == nil or lastSession == "" then
            return false, "native_session_unavailable"
        end

        local actorEntity = Ext.Entity.Get(objectGuid(data.actor))
        local targetHandle = Ext.Entity.UuidToHandle(objectGuid(data.target))
        local clientCharacter = actorEntity
            and safeField(actorEntity, "ClientCharacter")
            or nil
        local controller = clientCharacter
            and safeField(clientCharacter, "InputController")
            or nil
        if actorEntity == nil
            or targetHandle == nil
            or controller == nil then
            return false, "client_entity_unavailable"
        end

        local task = nil
        for _, candidate in pairs(safeField(controller, "Tasks") or {}) do
            local taskType = safeField(candidate, "TaskType")
            if tostring(taskType) == "Lockpick"
                or tonumber(taskType) == 15 then
                task = candidate
                break
            end
        end
        local controllerPointer = objectPointer(controller)
        local taskPointer = objectPointer(task)
        local initiatorHandle = entityHandle(actorEntity)
        local targetEntityHandle = entityHandle(targetHandle)
        local targetNetId = targetHandle:GetNetId()
        if task == nil
            or controllerPointer == nil
            or taskPointer == nil
            or initiatorHandle == nil
            or targetEntityHandle == nil
            or targetNetId == nil then
            return false, "lockpick_task_unavailable"
        end

        -- These are BG3SE-mapped fields on BG3's reusable stock Lockpick
        -- task. Native code invokes only InputController::SetRunningTask;
        -- the task itself performs the normal permission, movement, roll,
        -- result, tool, and crime pipeline.
        task.Item = targetHandle
        task.ItemNetId = targetNetId
        task.LockpickingStarted = false
        task.TargetSelected = true
        task.CanLockpick = false

        quickRequests[data.request] = {
            controller = controllerPointer:lower(),
            initiator = initiatorHandle:lower(),
            request = data.request,
            target = targetEntityHandle:lower(),
            task = taskPointer:lower(),
        }
        if not saveClientRecords() then
            quickRequests[data.request] = nil
            return false, "native_request_write_failed"
        end
        if traceEnabled then
            write("client_quick_lockpick_requested", {
                actor = data.actor,
                controller = controllerPointer,
                request = data.request,
                target = data.target,
                task = taskPointer,
            })
        end
        return true, nil
    end

    if quickLockpickChannel ~= nil then
        quickLockpickChannel:SetHandler(protected(
            "client_quick_lockpick_message_failed",
            function(data)
                if type(data) ~= "table" or type(data.request) ~= "string" then
                    return
                end
                if data.operation == "cancel" then
                    if quickRequests[data.request] ~= nil then
                        quickRequests[data.request] = nil
                        saveClientRecords()
                    end
                    return
                end
                if data.operation ~= "start"
                    or quickRequests[data.request] ~= nil then
                    return
                end
                local started, reason = prepareQuickLockpick(data)
                if not started then
                    write("client_quick_lockpick_rejected", {
                        actor = data.actor,
                        reason = reason,
                        request = data.request,
                        target = data.target,
                    })
                end
            end
        ))
    end

    Ext.Entity.OnCreate("RequestedRoll", protected(
        "client_profile_mapping_create_failed",
        function(entity, _, component)
            mapClientProfile(entity, component)
        end
    ))
    Ext.Entity.OnChange("RequestedRoll", protected(
        "client_profile_mapping_change_failed",
        function(entity)
            local rollEntity = Ext.Entity.Get(entity)
            local component = rollEntity and rollEntity.RequestedRoll or nil
            if component ~= nil then
                mapClientProfile(entity, component)
            end
        end
    ))
    Ext.Entity.OnDestroy("RequestedRoll", protected(
        "client_profile_mapping_destroy_failed",
        function(entity, _, component)
            removeClientProfile(entity, component)
        end
    ))
    if traceEnabled then
        write("client_profile_bridge_ready", {
            file = CLIENT_FILE,
            protocol = PROTOCOL,
            presentation_probe = "dc_active_roll_trace",
        })
    end
    return instance
end

return NativePresentationBridge
