-- SPDX-License-Identifier: Unlicense

local NativePresentationBridge = {}
local ACTION_FILE = "BestOfHandsNative.actions"
local CLIENT_FILE = "BestOfHandsNative.client"
local PROTOCOL = "9"
local GUID_PATTERN = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"
local SAVE_RETRY_DELAYS_MS = { 250, 1000, 5000 }

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

local function entityGuid(value)
    local directUuid = safeField(value, "Uuid")
    local directGuid = directUuid
        and safeField(directUuid, "EntityUuid")
        or nil
    if directGuid ~= nil then
        return tostring(directGuid)
    end
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

local function positiveInteger(value)
    local number = tonumber(value)
    if number == nil
        or number <= 0
        or number >= math.huge
        or number % 1 ~= 0 then
        return nil
    end
    return number
end

local function sameActionIdentity(left, right)
    return left ~= nil and right ~= nil and left.action == right.action
        and (objectGuid(left.rollUuid) or "0") == (objectGuid(right.rollUuid) or "0")
        and objectGuid(left.initiatorUuid) == objectGuid(right.initiatorUuid)
        and objectGuid(left.specialistUuid) == objectGuid(right.specialistUuid)
        and objectGuid(left.targetUuid) == objectGuid(right.targetUuid)
end

local function sameActionRecord(left, right)
    return sameActionIdentity(left, right)
        and (tonumber(left.presentationAdvantage) or -1) == (tonumber(right.presentationAdvantage) or -1)
end

local function write(level, event, fields)
    local keys = {}
    for key, _ in pairs(fields or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    local values = {}
    for _, key in ipairs(keys) do
        values[#values + 1] = tostring(key) .. "=" .. stableValue(fields[key])
    end
    local line = "[best_of_hands_client]|" .. level .. "|" .. event
    if #values > 0 then
        line = line .. "|" .. table.concat(values, "|")
    end
    Ext.Utils.Print(line)
end

function NativePresentationBridge.Start(settings, quickLockpickChannel, features,
    nativeSession, actionChannel)
    local instance = {}
    local tracked = {}
    local clientRecords = {}
    local quickRequests = {}
    local lastSession = ""
    local lastProbe = ""
    local traceEnabled = settings.TRACE_EVENTS == true
    local saveClientRecords
    local clientRecordsSaveRetryPending = false
    local clientRecordsSaveRetryAttempt = 0
    local remoteSnapshot = nil
    local observedRolls = {}
    local needsFullResync = true
    local lastClientPayload = nil

    local function clientFileIsCurrent(payload)
        local ok, contents = pcall(Ext.IO.LoadFile, CLIENT_FILE)
        return ok and contents == payload
    end

    local function scheduleClientRecordsSaveRetry()
        if clientRecordsSaveRetryPending then
            return
        end
        clientRecordsSaveRetryPending = true
        clientRecordsSaveRetryAttempt = math.min(
            clientRecordsSaveRetryAttempt + 1,
            #SAVE_RETRY_DELAYS_MS
        )
        local function retry()
            clientRecordsSaveRetryPending = false
            saveClientRecords(true)
        end
        if Ext.Timer ~= nil
            and type(Ext.Timer.WaitFor) == "function" then
            Ext.Timer.WaitFor(
                SAVE_RETRY_DELAYS_MS[clientRecordsSaveRetryAttempt],
                retry
            )
        elseif clientRecordsSaveRetryAttempt == 1
            and type(Ext.OnNextTick) == "function" then
            Ext.OnNextTick(retry)
        else
            clientRecordsSaveRetryPending = false
            clientRecordsSaveRetryAttempt = 0
        end
    end

    local function loadActionText()
        local ok, text
        if nativeSession ~= nil then
            local localSession = nativeSession.GetSession()
            if localSession == "" then return nil end
            local snapshot = remoteSnapshot
            -- Guests cannot read the host's filesystem. Even before the host
            -- snapshot arrives, the local session can enable personal clicks.
            if snapshot ~= nil or not Ext.Net.IsHost() then
                local lines = {"protocol=" .. PROTOCOL, "pak_version=" .. settings.VERSION,
                    "probe=" .. (snapshot and snapshot.probe or "client-local"),
                    "native_session=" .. localSession,
                    "trace=" .. (snapshot and snapshot.trace and "1" or "0")}
                for _, record in ipairs(snapshot and snapshot.records or {}) do
                    lines[#lines + 1] = table.concat({"record=" .. record.id, record.action,
                        "0", "0", "0", "0", "0", record.rollUuid or "0",
                        record.initiatorUuid, record.specialistUuid, record.targetUuid,
                        tostring(record.presentationAdvantage or -1)}, "\t")
                end
                lines[#lines + 1] = "end=1"
                text, ok = table.concat(lines, "\n") .. "\n", true
            else
                ok, text = pcall(Ext.IO.LoadFile, ACTION_FILE)
                if ok and type(text) == "string" then
                    text = text:gsub("native_session=[^\r\n]*", "native_session=" .. localSession)
                end
            end
        else
            ok, text = pcall(Ext.IO.LoadFile, ACTION_FILE)
        end
        if not ok or type(text) ~= "string" then
            traceEnabled = false
            return nil
        end
        local protocol = text:match("[\r\n]?protocol=([^\r\n]+)")
        local version = text:match("[\r\n]?pak_version=([^\r\n]+)")
        local probe = text:match("[\r\n]?probe=([^\r\n]+)") or ""
        local session = text:match("[\r\n]?native_session=([^\r\n]+)") or ""
        local complete = text:match("[\r\n]end=1[\r\n]?") ~= nil
        local requestedTrace = text:match("[\r\n]?trace=(%d)") == "1"
        if protocol ~= PROTOCOL
            or version ~= settings.VERSION
            or probe == ""
            or session == ""
            or not complete then
            traceEnabled = false
            return nil
        end
        traceEnabled = requestedTrace
        if lastSession ~= session or lastProbe ~= probe then
            lastSession = session
            lastProbe = probe
            tracked = {}
            clientRecords = {}
            quickRequests = {}
            needsFullResync = true
            lastClientPayload = nil
        end
        return text
    end

    local function trace(event, fields)
        if not traceEnabled then
            return
        end
        -- The server console command writes the authoritative trace flag to
        -- the action document. Revalidate it before every opt-in client trace
        -- so `best_of_hands_trace off` cannot leave stale client tracing active.
        if loadActionText() ~= nil and traceEnabled then
            write("TRACE", event, fields)
        end
    end

    local function loadActions()
        local text = loadActionText()
        if text == nil then
            return nil
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

    saveClientRecords = function(force)
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
            "probe=" .. lastProbe,
            "trace=" .. (traceEnabled and "1" or "0"),
        }
        for _, record in ipairs(values) do
            lines[#lines + 1] = table.concat({
                "record=" .. record.delegationId,
                record.rollUuid,
                record.initiatorHandle,
                record.specialistHandle,
                record.targetHandle,
                record.action,
                tostring(record.presentationAdvantage or -1),
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
        local payload = table.concat(lines, "\n") .. "\n"
        if not force and payload == lastClientPayload and clientFileIsCurrent(payload) then return true end
        local ok, result = pcall(
            Ext.IO.SaveFile,
            CLIENT_FILE,
            payload
        )
        if not ok or result == false then
            lastClientPayload = nil
            write("ERROR", "client_profile_bridge_write_failed", {
                error = ok and "save_returned_false" or result,
                file = CLIENT_FILE,
            })
            scheduleClientRecordsSaveRetry()
            return false
        end
        clientRecordsSaveRetryAttempt = 0
        lastClientPayload = payload
        return true
    end

    local function automaticEligible(entity)
        local darkness = safeField(entity, "Darkness")
        local sneaking = darkness ~= nil and safeField(darkness, "CharacterSneaking") == true
        if features ~= nil and not features.IsEnabled("left_click_lockpick", sneaking) then return false end
        if safeField(entity, "IsInCombat") ~= nil
            or safeField(entity, "IsInTurnBasedMode") ~= nil then return false end
        local dialog = safeField(entity, "ClientCharacter")
        if dialog ~= nil and safeField(dialog, "InDialog") == true then return false end
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
        local action = actionFromRoll(component)
        if action ~= nil then
            observedRolls[tostring(entity)] = {
                entity = entity, action = action,
                rollUuid = objectGuid(safeField(component, "RollUuid")),
                initiatorUuid = objectGuid(entityGuid(safeField(component, "Roller"))),
                targetUuid = objectGuid(entityGuid(safeField(component, "Subject"))),
            }
        end
        local record = classify(entity, component)
        if record == nil or record.rollUuid == nil then
            return nil
        end
        local previous = clientRecords[record.delegationId]
        if previous ~= nil and previous.rollUuid == record.rollUuid then
            record.initiatorHandle = previous.initiatorHandle
            record.specialistHandle = previous.specialistHandle
            record.targetHandle = previous.targetHandle
            if previous.presentationAdvantage ~= record.presentationAdvantage then
                previous.presentationAdvantage = record.presentationAdvantage
                saveClientRecords()
            end
            return record
        end
        local initiatorHandle = entityHandle(safeField(component, "Roller"))
        local targetHandle = entityHandle(safeField(component, "Subject"))
        local specialistHandle = entityHandle(record.specialistUuid)
        if initiatorHandle == nil
            or specialistHandle == nil
            or targetHandle == nil then
            write("ERROR", "client_profile_mapping_failed", {
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
                trace("client_profile_mapping_written", {
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
        observedRolls[key] = nil
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
            trace("client_profile_mapping_removed", {
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
        local mapped = clientRecords[tostring(record.delegationId)]
        if mapped ~= nil and mapped.rollUuid == record.rollUuid
            and mapped.presentationAdvantage ~= fresh.presentationAdvantage then
            mapped.presentationAdvantage = fresh.presentationAdvantage
            saveClientRecords()
        end
        return record
    end

    function instance.IsTraceEnabled()
        if traceEnabled then
            loadActionText()
        end
        return traceEnabled
    end

    local function protected(event, callback)
        return function(...)
            local ok, errorMessage = xpcall(
                callback, debug.traceback, ...)
            if not ok then
                write("ERROR", event, { error = errorMessage })
            end
        end
    end

    local function prepareQuickLockpick(data)
        if features ~= nil and type(features.GetMode) == "function"
            and features.GetMode("left_click_lockpick") == "Off" then
            return false, "feature_disabled"
        end
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

        local eligible = automaticEligible(actorEntity)
        if traceEnabled and features ~= nil and type(features.GetMode) == "function" then
            trace("client_automatic_mode", {
                actor = data.actor,
                enabled = eligible and 1 or 0,
                mode = features.GetMode("left_click_lockpick"),
                request = data.request,
            })
        end
        if not eligible then
            return false, "automatic_conditions_not_met"
        end
        local initiatorHandle = entityHandle(actorEntity)
        local targetEntityHandle = entityHandle(targetHandle)
        local netIdOk, rawTargetNetId = pcall(function()
            return targetHandle:GetNetId()
        end)
        local targetNetId = netIdOk
            and positiveInteger(rawTargetNetId)
            or nil
        if initiatorHandle == nil
            or targetEntityHandle == nil
            or targetNetId == nil then
            return false, "lockpick_identity_unavailable"
        end

        quickRequests[data.request] = {
            initiator = initiatorHandle:lower(),
            request = data.request,
            target = targetEntityHandle:lower(),
            targetNetId = targetNetId,
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
            trace("client_quick_lockpick_queued", {
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

    if quickLockpickChannel ~= nil then
        quickLockpickChannel:SetHandler(protected(
            "client_quick_lockpick_message_failed",
            function(data)
                if type(data) ~= "table" then
                    return
                end
                if data.operation == "invalidate" then
                    -- No target routing cache remains; admission rechecks the real target.
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
                    if reason ~= "feature_disabled" and reason ~= "automatic_conditions_not_met" then
                        write("WARN", "client_quick_lockpick_rejected", {
                            actor = data.actor,
                            reason = reason,
                            request = data.request,
                            target = data.target,
                        })
                    end
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

    local function resyncClientProfiles(full, changedRecords)
        if full then
            -- Bootstrap and recovery discover rolls that predate this observer.
            -- Ordinary metadata updates use our create/change/destroy cache.
            needsFullResync = true
            tracked, clientRecords, observedRolls = {}, {}, {}
            for _, roll in pairs(Ext.Entity.GetAllEntitiesWithComponent("RequestedRoll") or {}) do
                if roll.RequestedRoll ~= nil then mapClientProfile(roll, roll.RequestedRoll) end
            end
            needsFullResync = false
        else
            for key, observed in pairs(observedRolls) do
                local affected = false
                for _, record in ipairs(changedRecords) do
                    if record.action == observed.action and (
                        (observed.rollUuid ~= nil and observed.rollUuid == objectGuid(record.rollUuid))
                        or (observed.initiatorUuid == objectGuid(record.initiatorUuid)
                            and observed.targetUuid == objectGuid(record.targetUuid))) then
                        affected = true
                        break
                    end
                end
                if affected then
                    tracked[key] = nil
                    local roll = Ext.Entity.Get(observed.entity)
                    if roll ~= nil and roll.RequestedRoll ~= nil then
                        mapClientProfile(observed.entity, roll.RequestedRoll)
                    else
                        observedRolls[key] = nil
                    end
                end
            end
        end
        return saveClientRecords(full)
    end

    if actionChannel ~= nil then
        actionChannel:SetHandler(protected("client_native_action_sync_failed", function(data)
            if type(data) ~= "table" or data.protocol ~= PROTOCOL
                or data.version ~= settings.VERSION or type(data.probe) ~= "string"
                or data.probe == "" or type(data.records) ~= "table"
                or type(data.revision) ~= "number" then return end
            if remoteSnapshot ~= nil and remoteSnapshot.probe == data.probe
                and data.revision <= remoteSnapshot.revision then return end
            for _, record in ipairs(data.records) do
                if type(record) ~= "table" or positiveInteger(record.id) == nil
                    or (record.action ~= "lockpick" and record.action ~= "disarm")
                    or objectGuid(record.initiatorUuid) == nil
                    or objectGuid(record.specialistUuid) == nil
                    or objectGuid(record.targetUuid) == nil then return end
            end
            local previous = remoteSnapshot
            local before, after, changedIds, changedRecords = {}, {}, {}, {}
            for _, record in ipairs(previous and previous.records or {}) do before[tostring(record.id)] = record end
            for _, record in ipairs(data.records) do after[tostring(record.id)] = record end
            for id, record in pairs(before) do
                if not sameActionRecord(record, after[id]) then
                    changedIds[id] = true
                    changedRecords[#changedRecords + 1] = record
                end
            end
            for id, record in pairs(after) do
                if not sameActionRecord(before[id], record) then
                    changedIds[id] = true
                    changedRecords[#changedRecords + 1] = record
                end
            end
            remoteSnapshot = data
            if loadActionText() == nil then needsFullResync = true; return end
            local full = needsFullResync or previous == nil or previous.probe ~= data.probe
            if not full and next(changedIds) == nil and lastClientPayload ~= nil
                and (not not previous.trace) == (not not data.trace) then
                -- Equal metadata needs no entity work. Confirm storage before
                -- skipping publication so deletion/replacement still repairs.
                if not clientFileIsCurrent(lastClientPayload) then saveClientRecords(true) end
                return
            end
            for id in pairs(clientRecords) do
                if after[tostring(id)] == nil
                    or not sameActionIdentity(before[tostring(id)], after[tostring(id)]) then
                    clientRecords[id] = nil
                end
            end
            for key, record in pairs(tracked) do
                if changedIds[tostring(record.delegationId)] then tracked[key] = nil end
            end
            resyncClientProfiles(full, changedRecords)
        end))
        local function subscribe()
            remoteSnapshot = nil
            tracked, clientRecords, quickRequests, observedRolls = {}, {}, {}, {}
            lastProbe, lastSession = "", ""
            needsFullResync, lastClientPayload = true, nil
            pcall(function() actionChannel:SendToServer({operation = "subscribe"}) end)
        end
        Ext.Events.SessionLoaded:Subscribe(subscribe)
        Ext.Events.ResetCompleted:Subscribe(subscribe)
        nativeSession.Subscribe(protected("client_native_resync_failed", function()
            needsFullResync, lastClientPayload = true, nil
            if loadActionText() ~= nil then resyncClientProfiles(true) end
        end))
    end

    if traceEnabled then
        trace("client_profile_bridge_ready", {
            file = CLIENT_FILE,
            protocol = PROTOCOL,
            presentation_probe = "dc_active_roll_trace",
        })
    end
    return instance
end

return NativePresentationBridge
