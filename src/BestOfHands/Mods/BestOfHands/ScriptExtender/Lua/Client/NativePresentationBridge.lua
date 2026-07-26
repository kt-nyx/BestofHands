-- SPDX-License-Identifier: Unlicense

local NativePresentationBridge = {}
local ACTION_FILE = "BestOfHandsNative.actions"
local CLIENT_FILE = "BestOfHandsNative.client"
local LEFT_CLICK_FILE = "BestOfHandsNative.leftclick"
local PROTOCOL = "7"
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
    local leftClickInitiators = {}
    local lockedTargets = {}
    local invalidatedLockedTargets = {}
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
            leftClickInitiators = {}
            lockedTargets = {}
            invalidatedLockedTargets = {}
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
                record.initiator,
                record.target,
                tostring(record.targetNetId),
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

    local function saveLeftClickSnapshot()
        if lastSession == "" then
            return false
        end
        local lines = {
            "protocol=" .. PROTOCOL,
            "pak_version=" .. settings.VERSION,
            "native_session=" .. lastSession,
            "trace=" .. (traceEnabled and "1" or "0"),
        }
        local initiatorValues = {}
        for _, record in pairs(leftClickInitiators) do
            initiatorValues[#initiatorValues + 1] = record
        end
        table.sort(initiatorValues, function(left, right)
            return left.initiator < right.initiator
        end)
        for _, record in ipairs(initiatorValues) do
            lines[#lines + 1] = table.concat({
                "eligible=" .. record.initiator,
                record.eligible and "1" or "0",
            }, "\t")
        end
        local targetValues = {}
        for _, record in pairs(lockedTargets) do
            targetValues[#targetValues + 1] = record
        end
        table.sort(targetValues, function(left, right)
            return left.target < right.target
        end)
        for _, record in ipairs(targetValues) do
            lines[#lines + 1] = table.concat({
                "locked=" .. record.target,
                tostring(record.netId),
            }, "\t")
        end
        lines[#lines + 1] = "end=1"
        local ok, result = pcall(
            Ext.IO.SaveFile,
            LEFT_CLICK_FILE,
            table.concat(lines, "\n") .. "\n"
        )
        if not ok or result == false then
            write("client_left_click_bridge_write_failed", {
                error = ok and "save_returned_false" or result,
                file = LEFT_CLICK_FILE,
            })
            return false
        end
        return true
    end

    local function fixedString(value)
        if value == nil then
            return ""
        end
        return tostring(value)
    end

    local function refreshLeftClickSnapshot()
        if loadActions() == nil then
            return false
        end

        local initiators = {}
        local controlledHandles = {}
        local controlled = Ext.Entity.GetAllEntitiesWithComponent(
            "ClientControl"
        ) or {}
        for _, entity in pairs(controlled) do
            local initiator = entityHandle(entity)
            if initiator ~= nil then
                controlledHandles[initiator:lower()] = true
            end
            if initiator ~= nil then
                initiators[initiator:lower()] = {
                    eligible = safeField(entity, "IsInCombat") == nil
                        and safeField(entity, "IsInTurnBasedMode") == nil,
                    initiator = initiator:lower(),
                }
            end
        end

        -- Preserve vanilla automatic key use. A locked target is intercepted
        -- only when no key with the matching key identifier is currently
        -- owned by a locally controlled party character.
        local availableKeys = {}
        for _, entity in pairs(
            Ext.Entity.GetAllEntitiesWithComponent("Key") or {}
        ) do
            local key = safeField(entity, "Key")
            local topOwner = safeField(entity, "InventoryTopOwner")
            local owner = topOwner and entityHandle(
                safeField(topOwner, "TopOwner")
            ) or nil
            if owner ~= nil and controlledHandles[owner:lower()] then
                local keyId = fixedString(safeField(key, "Key"))
                if availableKeys[keyId] ~= true then
                    availableKeys[keyId] = true
                end
            end
        end

        local targets = {}
        local lockEntities =
            Ext.Entity.GetAllEntitiesWithComponent("Lock") or {}
        for _, entity in pairs(lockEntities) do
            local handle = entityHandle(entity)
            local lock = safeField(entity, "Lock")
            local key = fixedString(lock and safeField(lock, "Key_M"))
            local ok, netId = pcall(function()
                return entity:GetNetId()
            end)
            local guid = objectGuid(entityGuid(entity))
            local handleKey = handle and handle:lower() or nil
            local invalidated = (handleKey ~= nil
                    and invalidatedLockedTargets[handleKey] == true)
                or (guid ~= nil
                    and invalidatedLockedTargets[guid] == true)
            -- An authoritative successful lockpick can arrive before the
            -- replicated client Lock component is destroyed. Keep the target
            -- excluded until a future Lock OnCreate proves that it was
            -- genuinely locked again.
            local excluded = (key ~= "" and availableKeys[key] == true)
                or invalidated
            if not excluded
                and handle ~= nil
                and ok
                and tonumber(netId) ~= nil
                and tonumber(netId) > 0 then
                targets[handle:lower()] = {
                    netId = tonumber(netId),
                    target = handle:lower(),
                }
            end
        end

        leftClickInitiators = initiators
        lockedTargets = targets
        return saveLeftClickSnapshot()
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
        if actorEntity == nil
            or targetHandle == nil then
            return false, "client_entity_unavailable"
        end

        local initiatorHandle = entityHandle(actorEntity)
        local targetEntityHandle = entityHandle(targetHandle)
        local targetNetId = targetHandle:GetNetId()
        if initiatorHandle == nil
            or targetEntityHandle == nil
            or targetNetId == nil then
            return false, "lockpick_identity_unavailable"
        end

        quickRequests[data.request] = {
            initiator = initiatorHandle:lower(),
            request = data.request,
            target = targetEntityHandle:lower(),
            targetNetId = tonumber(targetNetId),
        }
        if not saveClientRecords() then
            quickRequests[data.request] = nil
            return false, "native_request_write_failed"
        end
        local acknowledged, acknowledgementResult = pcall(function()
            quickLockpickChannel:SendToServer({
                operation = "queued",
                request = data.request,
            })
        end)
        if not acknowledged or acknowledgementResult == false then
            quickRequests[data.request] = nil
            saveClientRecords()
            return false, "server_ack_failed"
        end
        if traceEnabled then
            write("client_quick_lockpick_queued", {
                actor = data.actor,
                request = data.request,
                target = data.target,
                actor_entity = tostring(actorEntity),
                target_entity = tostring(targetHandle),
                target_handle = targetEntityHandle,
                target_net_id = targetNetId,
            })
        end
        return true, nil
    end

    local function invalidateLockedTarget(data)
        local targetGuid = type(data) == "table"
            and objectGuid(data.target)
            or nil
        if targetGuid == nil then
            return false
        end
        invalidatedLockedTargets[targetGuid] = true
        local ok, targetHandle = pcall(
            Ext.Entity.UuidToHandle,
            targetGuid
        )
        local handle = ok and targetHandle and entityHandle(targetHandle) or nil
        if handle ~= nil then
            handle = handle:lower()
            invalidatedLockedTargets[handle] = true
            lockedTargets[handle] = nil
        end
        local saved = saveLeftClickSnapshot()
        if traceEnabled then
            write("client_left_click_target_invalidated", {
                saved = saved and 1 or 0,
                target = targetGuid,
                target_handle = handle,
            })
        end
        return saved
    end

    if quickLockpickChannel ~= nil then
        quickLockpickChannel:SetHandler(protected(
            "client_quick_lockpick_message_failed",
            function(data)
                if type(data) ~= "table" then
                    return
                end
                if data.operation == "invalidate" then
                    invalidateLockedTarget(data)
                    return
                end
                if type(data.request) ~= "string" then
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
                    pcall(function()
                        quickLockpickChannel:SendToServer({
                            operation = "rejected",
                            reason = reason,
                            request = data.request,
                        })
                    end)
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

    local snapshotRefreshPending = false
    local function scheduleLeftClickSnapshot()
        if snapshotRefreshPending then
            return
        end
        snapshotRefreshPending = true
        Ext.OnNextTick(function()
            snapshotRefreshPending = false
            local ok, refreshed = xpcall(
                refreshLeftClickSnapshot,
                debug.traceback
            )
            if not ok then
                write("client_left_click_snapshot_failed", {
                    error = refreshed,
                })
            end
            if not ok or not refreshed then
                scheduleLeftClickSnapshot()
            end
        end)
    end

    if type(Ext.OnNextTick) == "function"
        and Ext.Events ~= nil then
        local snapshotComponents = {
            "ClientControl",
            "IsInCombat",
            "IsInTurnBasedMode",
            "Key",
            "InventoryTopOwner",
        }
        for _, componentName in ipairs(snapshotComponents) do
            Ext.Entity.OnCreate(componentName, protected(
                "client_left_click_snapshot_create_failed",
                scheduleLeftClickSnapshot
            ))
            Ext.Entity.OnChange(componentName, protected(
                "client_left_click_snapshot_change_failed",
                scheduleLeftClickSnapshot
            ))
            Ext.Entity.OnDestroy(componentName, protected(
                "client_left_click_snapshot_destroy_failed",
                scheduleLeftClickSnapshot
            ))
        end
        Ext.Entity.OnCreate("Lock", protected(
            "client_left_click_lock_create_failed",
            function(entity)
                local handle = entityHandle(entity)
                local guid = objectGuid(entityGuid(entity))
                if handle ~= nil then
                    invalidatedLockedTargets[handle:lower()] = nil
                end
                if guid ~= nil then
                    invalidatedLockedTargets[guid] = nil
                end
                scheduleLeftClickSnapshot()
            end
        ))
        Ext.Entity.OnChange("Lock", protected(
            "client_left_click_lock_change_failed",
            scheduleLeftClickSnapshot
        ))
        Ext.Entity.OnDestroy("Lock", protected(
            "client_left_click_lock_destroy_failed",
            scheduleLeftClickSnapshot
        ))
        Ext.Events.SessionLoaded:Subscribe(scheduleLeftClickSnapshot)
        Ext.Events.ResetCompleted:Subscribe(scheduleLeftClickSnapshot)
        scheduleLeftClickSnapshot()
    end

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
