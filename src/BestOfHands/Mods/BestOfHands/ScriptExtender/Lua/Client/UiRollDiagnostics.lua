-- SPDX-License-Identifier: Unlicense

local UiRollDiagnostics = {}
local ACTION_FILE = "BestOfHandsNative.actions"

local function safeField(value, field)
    local ok, result = pcall(function() return value[field] end)
    return ok and result or nil
end

local function arrayLength(value)
    local ok, result = pcall(function() return #value end)
    return ok and result or 0
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

local function stableValue(value)
    if value == nil then
        return "null"
    end
    local ok, result = pcall(tostring, value)
    if not ok then
        return "<unprintable>"
    end
    return result:gsub("[\r\n|]", " ")
end

local function write(event, fields)
    local keys = {}
    for key, _ in pairs(fields or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = tostring(key) .. "=" .. stableValue(fields[key])
    end
    local line = "[best_of_hands_client]|TRACE|" .. event
    if #parts > 0 then
        line = line .. "|" .. table.concat(parts, "|")
    end
    Ext.Utils.Print(line)
end

local function describeMap(value)
    local entries = {}
    pcall(function()
        for key, entry in pairs(value or {}) do
            entries[#entries + 1] = tostring(key) .. ":" .. tostring(entry)
        end
    end)
    table.sort(entries)
    return #entries > 0 and table.concat(entries, ",") or nil
end

local function describeArray(value, fields)
    local entries = {}
    pcall(function()
        for index, entry in pairs(value or {}) do
            local parts = { tostring(index) }
            for _, field in ipairs(fields) do
                parts[#parts + 1] = field .. ":" .. tostring(safeField(entry, field))
            end
            entries[#entries + 1] = table.concat(parts, "/")
        end
    end)
    table.sort(entries)
    return #entries > 0 and table.concat(entries, ",") or nil
end

local function monotonicTime()
    local ok, result = pcall(function()
        return Ext.Utils
            and type(Ext.Utils.MonotonicTime) == "function"
            and Ext.Utils.MonotonicTime()
            or nil
    end)
    return ok and result or nil
end

local function bridgeDocument(defaultTrace)
    local ok, text = pcall(Ext.IO.LoadFile, ACTION_FILE)
    if not ok or type(text) ~= "string" then
        return defaultTrace, { all = {}, byRoll = {} }
    end
    local enabled = text:match("[\r\n]?trace=(%d)") == "1"
    local records = { all = {}, byRoll = {} }
    for line in text:gmatch("[^\r\n]+") do
        local id, action, initiator, specialist, target, roll = line:match(
            "^record=(%d+)\t([^\t]+)\t(%x+)\t(%x+)\t(%x+)\t(%x+)"
        )
        if id ~= nil then
            local record = {
                action = action,
                delegationId = id,
                initiator = initiator:lower(),
                specialist = specialist:lower(),
                target = target:lower(),
            }
            records.all[#records.all + 1] = record
            if roll ~= "0" then
                records.byRoll[roll:lower()] = record
            end
        end
    end
    return enabled, records
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

local function traceError(event, errorMessage)
    write(event, { error = errorMessage })
end

local function sameHandle(left, right)
    return left ~= nil
        and right ~= nil
        and tostring(left):lower() == tostring(right):lower()
end

function UiRollDiagnostics.Start(settings, presentationBridge)
    local tracked = {}
    local defaultTrace = settings.TRACE_EVENTS == true
    local function traceEnabled()
        if presentationBridge
            and type(presentationBridge.IsTraceEnabled) == "function" then
            return presentationBridge.IsTraceEnabled()
        end
        return defaultTrace
    end
    local activeRollElementNames = {
        "ActiveRoll",
        "ActiveRollBoosts",
        "AnimationOverlayHolder",
        "AnimSeqBase",
        "AnimSeqSelected",
        "BoostListItemsControl",
        "ContinueButton",
        "DieRollAnimation",
        "modlist",
        "prompt",
        "ResultHolder",
        "RollModSeq",
        "selectedboostmodlist",
    }
    local dataContextScalarFields = {
        "AbilityCheckText",
        "CanRespondToCommands",
        "FinalResult",
        "HasBoostsToAdd",
        "IsPureAbilityRoll",
        "NaturalRoll",
        "RollState",
        "SkippedRoll",
        "Success",
    }
    local rollScalarFields = {
        "AdditionalValue",
        "DiceAdditionalValue",
        "DiscardedDiceTotal",
        "FinalResult",
        "NaturalRoll",
        "Result",
        "RollAdvantageType",
        "Total",
    }

    local function noesisType(value)
        if value == nil then
            return nil
        end
        local direct = safeField(value, "Type")
        if direct ~= nil then
            return stableValue(direct)
        end
        local ok, result = pcall(function()
            return type(value.TypeInfo) == "function"
                and value:TypeInfo()
                or nil
        end)
        return ok and result ~= nil and stableValue(result) or nil
    end

    local function propertyCatalog(value)
        if value == nil then
            return nil, 0
        end
        local ok, properties = pcall(function()
            return type(value.GetAllProperties) == "function"
                and value:GetAllProperties()
                or nil
        end)
        if not ok or properties == nil then
            return nil, 0
        end
        local names = {}
        pcall(function()
            for key, property in pairs(properties) do
                local name = safeField(property, "Name") or key
                names[#names + 1] = stableValue(name)
            end
        end)
        table.sort(names)
        local count = #names
        while #names > 160 do
            table.remove(names)
        end
        return #names > 0 and table.concat(names, ",") or nil, count
    end

    local function scalarCatalog(value, fields)
        local entries = {}
        for _, field in ipairs(fields or {}) do
            local fieldValue = safeField(value, field)
            entries[#entries + 1] = field .. ":" .. stableValue(fieldValue)
        end
        return table.concat(entries, ",")
    end

    local function collectionItemCount(value)
        local count = arrayLength(value)
        if count > 0 then
            return count
        end
        local direct = tonumber(safeField(value, "Count"))
        return direct or 0
    end

    local function childAt(value, methodName, index)
        local ok, result = pcall(function()
            local method = value and value[methodName] or nil
            if type(method) ~= "function" then
                return nil
            end
            return method(value, index)
        end)
        return ok and result or nil, ok and nil or result
    end

    local function findActiveRollWidget(root, maxNodes)
        local queue = {
            { node = root, path = "root", depth = 0 },
        }
        local head = 1
        local visited = {}
        local report = {
            childErrors = 0,
            contextNodes = 0,
            interesting = {},
            maxDepth = 0,
            namedNodes = 0,
            nodes = 0,
            truncated = false,
        }
        local fallback = nil
        while head <= #queue and report.nodes < maxNodes do
            local entry = queue[head]
            head = head + 1
            local node = entry.node
            if node ~= nil and not visited[node] then
                visited[node] = true
                report.nodes = report.nodes + 1
                report.maxDepth = math.max(report.maxDepth, entry.depth)
                local name = safeField(node, "Name")
                local nodeType = noesisType(node)
                local dataContext = safeField(node, "DataContext")
                local dataContextType = noesisType(dataContext)
                local isActiveContext = dataContextType ~= nil
                    and dataContextType:find("DCActiveRoll", 1, true) ~= nil
                if name ~= nil and stableValue(name) ~= "" then
                    report.namedNodes = report.namedNodes + 1
                end
                if dataContext ~= nil then
                    report.contextNodes = report.contextNodes + 1
                end
                if (#report.interesting < 64)
                    and (isActiveContext
                        or name ~= nil
                        or entry.depth <= 2) then
                    report.interesting[#report.interesting + 1] = table.concat({
                        entry.path,
                        stableValue(name),
                        stableValue(nodeType),
                        stableValue(dataContextType),
                    }, "/")
                end
                local nameText = stableValue(name)
                local isWidget = nodeType ~= nil
                    and nodeType:find("UIWidget", 1, true) ~= nil
                if isActiveContext and isWidget then
                    report.foundPath = entry.path
                    report.foundName = nameText
                    report.foundType = nodeType
                    report.foundContextType = dataContextType
                    return node, report
                end
                if isActiveContext and fallback == nil then
                    fallback = node
                    report.fallbackPath = entry.path
                end
                if nameText == "ActiveRoll" and fallback == nil then
                    fallback = node
                    report.fallbackPath = entry.path
                end

                local visualCount = tonumber(
                    safeField(node, "VisualChildrenCount")
                ) or 0
                for index = 0, visualCount - 1 do
                    local child, errorMessage = childAt(
                        node,
                        "VisualChild",
                        index
                    )
                    if child ~= nil then
                        queue[#queue + 1] = {
                            depth = entry.depth + 1,
                            node = child,
                            path = entry.path .. ".v" .. tostring(index),
                        }
                    elseif errorMessage ~= nil then
                        report.childErrors = report.childErrors + 1
                    end
                end
                if visualCount == 0 then
                    local logicalCount = tonumber(
                        safeField(node, "ChildrenCount")
                    ) or 0
                    for index = 0, logicalCount - 1 do
                        local child, errorMessage = childAt(
                            node,
                            "Child",
                            index
                        )
                        if child ~= nil then
                            queue[#queue + 1] = {
                                depth = entry.depth + 1,
                                node = child,
                                path = entry.path .. ".l" .. tostring(index),
                            }
                        elseif errorMessage ~= nil then
                            report.childErrors = report.childErrors + 1
                        end
                    end
                end
            end
        end
        report.truncated = head <= #queue
        if fallback ~= nil then
            report.foundPath = report.fallbackPath
            report.foundName = safeField(fallback, "Name")
            report.foundType = noesisType(fallback)
            report.foundContextType = noesisType(
                safeField(fallback, "DataContext")
            )
        end
        return fallback, report
    end

    local function traceVisualTreeSearch(record, stage, delay, report)
        local signature = table.concat({
            stableValue(report.foundPath),
            stableValue(report.foundType),
            stableValue(report.foundContextType),
            stableValue(report.nodes),
            stableValue(report.truncated),
        }, "|")
        record.visualTreeSignatures = record.visualTreeSignatures or {}
        if record.visualTreeSignatures[signature] then
            return
        end
        record.visualTreeSignatures[signature] = true
        write("client_active_roll_visual_tree", {
            action = record.action,
            child_errors = report.childErrors,
            context_nodes = report.contextNodes,
            delegation_id = record.delegationId,
            found_context_type = report.foundContextType,
            found_name = report.foundName,
            found_path = report.foundPath,
            found_type = report.foundType,
            interesting_nodes = #report.interesting > 0
                and table.concat(report.interesting, ";") or nil,
            max_depth = report.maxDepth,
            named_nodes = report.namedNodes,
            nodes_visited = report.nodes,
            profile_mode = record.profileMode,
            snapshot_delay_ms = delay,
            stage = stage,
            truncated = report.truncated and 1 or 0,
        })
    end

    local function presentationAdvantageName(record)
        if presentationBridge ~= nil
            and type(presentationBridge.RefreshRecord) == "function" then
            presentationBridge.RefreshRecord(record)
        end
        local value = tonumber(record and record.presentationAdvantage or nil)
        if value == 0 then
            return "None", value
        elseif value == 1 then
            return "Advantage", value
        elseif value == 2 then
            return "Disadvantage", value
        end
        return nil, value
    end

    local function setNoesisProperty(value, field, desired)
        local directOk, directError = pcall(function()
            value[field] = desired
        end)
        local observed = safeField(value, field)
        if stableValue(observed) == stableValue(desired) then
            return true, "direct_assignment", observed
        end
        local methodOk, methodError = pcall(function()
            local method = value and value.SetProperty or nil
            if type(method) ~= "function" then
                error("SetProperty unavailable")
            end
            method(value, field, desired)
        end)
        observed = safeField(value, field)
        if stableValue(observed) == stableValue(desired) then
            return true, "set_property", observed
        end
        return false, table.concat({
            directOk and "direct_unchanged" or stableValue(directError),
            methodOk and "set_property_unchanged" or stableValue(methodError),
        }, ";"), observed
    end

    local function synchronizePresentationAdvantage(record, dataContext, roll, stage)
        if record == nil or record.profileMode ~= "delegated" or roll == nil then
            return
        end
        local expected, expectedCode = presentationAdvantageName(record)
        local current = safeField(roll, "RollAdvantageType")
        local rollState = dataContext and safeField(dataContext, "RollState") or nil
        if expected == nil then
            if not record.presentationAdvantagePendingTraced then
                record.presentationAdvantagePendingTraced = true
                write("client_presentation_advantage_pending", {
                    action = record.action,
                    delegation_id = record.delegationId,
                    expected_code = expectedCode,
                    observed = current,
                    roll_state = rollState,
                    stage = stage,
                })
            end
            return
        end
        if stableValue(current) == expected then
            if record.presentationAdvantageMatched ~= expected then
                record.presentationAdvantageMatched = expected
                write("client_presentation_advantage_aligned", {
                    action = record.action,
                    delegation_id = record.delegationId,
                    expected = expected,
                    expected_code = expectedCode,
                    observed = current,
                    roll_state = rollState,
                    stage = stage,
                })
            end
            return
        end
        local state = stableValue(rollState)
        local safeState = rollState == nil
            or state == "IntroductionAnimation"
            or state == "WaitForStart"
            or state == "WaitForReRoll"
        if not safeState then
            write("client_presentation_advantage_sync_skipped", {
                action = record.action,
                delegation_id = record.delegationId,
                expected = expected,
                observed = current,
                reason = "roll_state_not_safe",
                roll_state = rollState,
                stage = stage,
            })
            return
        end
        record.presentationAdvantageSyncAttempts =
            (record.presentationAdvantageSyncAttempts or 0) + 1
        if record.presentationAdvantageSyncAttempts > 4 then
            return
        end
        local succeeded, method, observed = setNoesisProperty(
            roll,
            "RollAdvantageType",
            expected
        )
        write("client_presentation_advantage_sync", {
            action = record.action,
            delegation_id = record.delegationId,
            expected = expected,
            expected_code = expectedCode,
            method = method,
            observed_after = observed,
            observed_before = current,
            roll_state = rollState,
            stage = stage,
            succeeded = succeeded and 1 or 0,
        })
    end

    local function traceViewModelCatalog(record, role, value)
        record.viewModelCatalogs = record.viewModelCatalogs or {}
        local key = role .. "|" .. tostring(noesisType(value))
        if record.viewModelCatalogs[key] then
            return
        end
        record.viewModelCatalogs[key] = true
        local properties, propertyCount = propertyCatalog(value)
        write("client_active_roll_property_catalog", {
            action = record.action,
            delegation_id = record.delegationId,
            profile_mode = record.profileMode,
            properties = properties,
            property_count = propertyCount,
            role = role,
            type = noesisType(value),
        })
    end

    local function traceViewModelCollection(record, role, collection, stage)
        local count = collectionItemCount(collection)
        write("client_active_roll_collection", {
            action = record.action,
            count = count,
            delegation_id = record.delegationId,
            profile_mode = record.profileMode,
            role = role,
            stage = stage,
            type = noesisType(collection),
        })
        local traced = 0
        pcall(function()
            for index, entry in pairs(collection or {}) do
                traced = traced + 1
                if traced > 32 then
                    break
                end
                local diceTypeSet = safeField(entry, "DiceTypeSet")
                local owner = safeField(entry, "Owner")
                local sourceViewModel = safeField(entry, "SourceVM")
                local boostModifier = safeField(entry, "BoostModifier")
                write("client_active_roll_modifier_viewmodel", {
                    action = record.action,
                    additional_value = safeField(entry, "AdditionalValue"),
                    advantage_type = safeField(entry, "AdvantageType"),
                    boost_type = safeField(entry, "BoostType"),
                    boost_modifier_count = collectionItemCount(boostModifier),
                    delegation_id = record.delegationId,
                    description = safeField(entry, "Description"),
                    dice_amount = diceTypeSet and safeField(diceTypeSet, "Amount") or nil,
                    dice_string = diceTypeSet and safeField(diceTypeSet, "Str") or nil,
                    dice_type = diceTypeSet and safeField(diceTypeSet, "DiceType") or nil,
                    entity_handle = safeField(entry, "EntityHandle"),
                    index = index,
                    is_advantage = safeField(entry, "IsAdvantage"),
                    is_disabled = safeField(entry, "IsDisabled"),
                    is_enabled = safeField(entry, "IsEnabled"),
                    is_selected = safeField(entry, "IsSelected"),
                    max_bonus = safeField(entry, "MaxBonusValue"),
                    min_bonus = safeField(entry, "MinBonusValue"),
                    name = safeField(entry, "Name"),
                    owner_entity_handle = owner and safeField(owner, "EntityHandle") or nil,
                    owner_name = owner and safeField(owner, "Name") or nil,
                    owner_type = noesisType(owner),
                    profile_mode = record.profileMode,
                    role = role,
                    source_type = safeField(entry, "SourceType"),
                    source_vm_name = sourceViewModel
                        and safeField(sourceViewModel, "Name") or nil,
                    source_vm_type = noesisType(sourceViewModel),
                    stage = stage,
                    tag_reason = safeField(entry, "TagReason"),
                    type = noesisType(entry),
                    use_type = safeField(entry, "UseType"),
                    value = safeField(entry, "Value"),
                })
                traceViewModelCatalog(record, role .. "_entry", entry)
                if diceTypeSet ~= nil then
                    traceViewModelCatalog(record, role .. "_dice", diceTypeSet)
                end
            end
        end)
    end

    local function viewModelCollectionSignature(collection)
        local entries = {}
        local observed = 0
        pcall(function()
            for index, entry in pairs(collection or {}) do
                observed = observed + 1
                if observed > 32 then
                    break
                end
                local diceTypeSet = safeField(entry, "DiceTypeSet")
                entries[#entries + 1] = table.concat({
                    stableValue(index),
                    stableValue(safeField(entry, "Name")),
                    stableValue(safeField(entry, "IsAdvantage")),
                    stableValue(safeField(entry, "IsDisabled")),
                    stableValue(safeField(entry, "IsSelected")),
                    stableValue(safeField(entry, "Value")),
                    stableValue(safeField(entry, "AdditionalValue")),
                    stableValue(safeField(entry, "MinBonusValue")),
                    stableValue(safeField(entry, "MaxBonusValue")),
                    stableValue(diceTypeSet and safeField(diceTypeSet, "Str") or nil),
                }, ":")
            end
        end)
        table.sort(entries)
        return table.concat(entries, ",")
    end

    local function traceActiveRollElements(record, widget, stage)
        for _, name in ipairs(activeRollElementNames) do
            local ok, elementOrError = pcall(function()
                return type(widget.Find) == "function"
                    and widget:Find(name)
                    or nil
            end)
            local element = ok and elementOrError or nil
            if element ~= nil then
                local context = safeField(element, "DataContext")
                write("client_active_roll_element", {
                    action = record.action,
                    actual_height = safeField(element, "ActualHeight"),
                    actual_width = safeField(element, "ActualWidth"),
                    data_context_type = noesisType(context),
                    delegation_id = record.delegationId,
                    is_enabled = safeField(element, "IsEnabled"),
                    name = name,
                    opacity = safeField(element, "Opacity"),
                    profile_mode = record.profileMode,
                    sequence_completed = safeField(element, "SequenceCompleted"),
                    stage = stage,
                    tag = safeField(element, "Tag"),
                    type = noesisType(element),
                    visibility = safeField(element, "Visibility"),
                })
            elseif not ok then
                write("client_active_roll_element_unavailable", {
                    action = record.action,
                    delegation_id = record.delegationId,
                    error = elementOrError,
                    name = name,
                    profile_mode = record.profileMode,
                    stage = stage,
                })
            end
        end
    end

    local function activeRollElementSignature(widget)
        local entries = {}
        for _, name in ipairs(activeRollElementNames) do
            local ok, element = pcall(function()
                return type(widget.Find) == "function"
                    and widget:Find(name)
                    or nil
            end)
            if ok and element ~= nil then
                entries[#entries + 1] = table.concat({
                    name,
                    stableValue(safeField(element, "Tag")),
                    stableValue(safeField(element, "SequenceCompleted")),
                    stableValue(safeField(element, "Visibility")),
                    stableValue(safeField(element, "IsEnabled")),
                }, ":")
            end
        end
        return table.concat(entries, ",")
    end

    local function traceActiveRollViewModel(record, stage, delay)
        if record == nil or record.viewModelTraceAttempts >= 48 then
            return false
        end
        record.viewModelTraceAttempts = record.viewModelTraceAttempts + 1
        local okRoot, rootOrError = pcall(function() return Ext.UI.GetRoot() end)
        if not okRoot or rootOrError == nil then
            write("client_active_roll_viewmodel_unavailable", {
                action = record.action,
                delegation_id = record.delegationId,
                error = okRoot and nil or rootOrError,
                profile_mode = record.profileMode,
                reason = "ui_root_unavailable",
                snapshot_delay_ms = delay,
                stage = stage,
            })
            return false
        end
        local root = rootOrError
        local widget = record.activeRollWidget
        local cachedContextType = noesisType(
            widget and safeField(widget, "DataContext") or nil
        )
        if cachedContextType == nil
            or cachedContextType:find("DCActiveRoll", 1, true) == nil then
            widget = nil
            record.activeRollWidget = nil
        end
        local okWidget, widgetOrError = true, widget
        if widget == nil then
            okWidget, widgetOrError = pcall(function()
                return type(root.Find) == "function"
                    and root:Find("ActiveRoll")
                    or nil
            end)
            widget = okWidget and widgetOrError or nil
        end
        local treeReport = nil
        if widget == nil then
            widget, treeReport = findActiveRollWidget(root, 16384)
            traceVisualTreeSearch(record, stage, delay, treeReport)
        end
        if widget == nil then
            write("client_active_roll_viewmodel_unavailable", {
                action = record.action,
                delegation_id = record.delegationId,
                error = okWidget and nil or widgetOrError,
                profile_mode = record.profileMode,
                reason = "active_roll_widget_unavailable_after_tree_scan",
                root_type = noesisType(root),
                snapshot_delay_ms = delay,
                stage = stage,
                tree_nodes_visited = treeReport and treeReport.nodes or nil,
                tree_truncated = treeReport and treeReport.truncated and 1 or 0,
            })
            return false
        end
        record.activeRollWidget = widget
        local dataContext = safeField(widget, "DataContext")
        local roll = dataContext and safeField(dataContext, "Roll") or nil
        synchronizePresentationAdvantage(record, dataContext, roll, stage)
        local modifiers = roll and safeField(roll, "Modifiers") or nil
        local advantages = roll and safeField(roll, "Advantages") or nil
        local selected = dataContext
            and safeField(dataContext, "SelectedBoostModifierList")
            or nil
        local available = dataContext
            and safeField(dataContext, "BoostModifierList")
            or nil
        local contextObject = dataContext
            and safeField(dataContext, "ContextObject")
            or nil
        local owner = dataContext and safeField(dataContext, "Owner") or nil
        local signature = table.concat({
            stableValue(noesisType(dataContext)),
            scalarCatalog(dataContext, dataContextScalarFields),
            scalarCatalog(roll, rollScalarFields),
            viewModelCollectionSignature(modifiers),
            viewModelCollectionSignature(advantages),
            viewModelCollectionSignature(selected),
            viewModelCollectionSignature(available),
            activeRollElementSignature(widget),
        }, "|")
        if record.lastViewModelSignature == signature then
            return true
        end
        record.lastViewModelSignature = signature
        record.viewModelTraceCount = record.viewModelTraceCount + 1
        if record.viewModelTraceCount > 16 then
            return false
        end
        write("client_active_roll_viewmodel", {
            action = record.action,
            advantages_count = collectionItemCount(advantages),
            available_count = collectionItemCount(available),
            cancel_command_present = dataContext
                and safeField(dataContext, "CancelCommand") ~= nil and 1 or 0,
            context_object_entity_handle = contextObject
                and safeField(contextObject, "EntityHandle") or nil,
            context_object_name = contextObject
                and safeField(contextObject, "Name") or nil,
            context_object_type = noesisType(contextObject),
            continue_command_present = dataContext
                and safeField(dataContext, "ContinueCommand") ~= nil and 1 or 0,
            data_context_scalars = scalarCatalog(
                dataContext,
                dataContextScalarFields
            ),
            data_context_type = noesisType(dataContext),
            dc_advantage_type = dataContext
                and safeField(dataContext, "AdvantageType") or nil,
            delegation_id = record.delegationId,
            final_result = dataContext and safeField(dataContext, "FinalResult") or nil,
            is_success = dataContext and safeField(dataContext, "IsSuccess") or nil,
            modifiers_count = collectionItemCount(modifiers),
            natural_roll = dataContext and safeField(dataContext, "NaturalRoll") or nil,
            observed_at = monotonicTime(),
            owner_entity_handle = owner and safeField(owner, "EntityHandle") or nil,
            owner_name = owner and safeField(owner, "Name") or nil,
            owner_type = noesisType(owner),
            presentation_advantage = record.presentationAdvantage,
            profile_mode = record.profileMode,
            roll_advantage_type = roll and safeField(roll, "RollAdvantageType") or nil,
            roll_natural_roll = roll and safeField(roll, "NaturalRoll") or nil,
            roll_result = roll and safeField(roll, "Result") or nil,
            roll_state = dataContext and safeField(dataContext, "RollState") or nil,
            roll_scalars = scalarCatalog(roll, rollScalarFields),
            roll_total = roll and safeField(roll, "Total") or nil,
            roll_type = noesisType(roll),
            selected_count = collectionItemCount(selected),
            snapshot_delay_ms = delay,
            stage = stage,
            try_again_command_present = dataContext
                and safeField(dataContext, "TryAgainCommand") ~= nil and 1 or 0,
            widget_type = noesisType(widget),
        })
        traceViewModelCatalog(record, "data_context", dataContext)
        traceViewModelCatalog(record, "roll", roll)
        traceViewModelCollection(record, "modifiers", modifiers, stage)
        traceViewModelCollection(record, "advantages", advantages, stage)
        traceViewModelCollection(record, "selected", selected, stage)
        traceViewModelCollection(record, "available", available, stage)
        traceActiveRollElements(record, widget, stage)
        return true
    end

    local function scheduleActiveRollSnapshots(record, stage, delays)
        -- Script Extender exposes only CanvasRoot for this page in the current
        -- game build. Keep the ECS diagnostics below, but leave active-roll
        -- presentation to the validated native client hook.
        return record, stage, delays
    end

    local function classify(entity, component)
        local action = actionFromRoll(component)
        if action == nil then
            return nil
        end
        -- The client diagnostic observers stay registered so tracing can be
        -- enabled at runtime, but ordinary play returns before any bridge-file
        -- parsing, entity correlation, or viewmodel inspection.
        if not traceEnabled() then
            return nil
        end
        local enabled, records = bridgeDocument(defaultTrace)
        if not enabled then
            return nil
        end
        local handle = entityHandle(entity)
        local delegated = presentationBridge
            and presentationBridge.GetRecord(entity, component)
            or nil
        if delegated == nil then
            delegated = handle and records.byRoll[handle:lower()] or nil
        end
        if delegated == nil then
            local rollerHandle = entityHandle(safeField(component, "Roller"))
            local subjectHandle = entityHandle(safeField(component, "Subject"))
            for _, candidate in ipairs(records.all) do
                if candidate.action == action
                    and candidate.initiator == tostring(rollerHandle):lower()
                    and candidate.target == tostring(subjectHandle):lower() then
                    delegated = candidate
                    break
                end
            end
        end
        local record = tracked[tostring(entity)] or {}
        record.action = delegated and delegated.action or action
        record.delegationId = delegated and delegated.delegationId or nil
        record.initiatorHandle = delegated
            and (delegated.initiatorHandle or delegated.initiator)
            or nil
        record.presentationAdvantage = delegated
            and delegated.presentationAdvantage
            or record.presentationAdvantage
        record.profileMode = delegated and "delegated" or "vanilla_reference"
        record.rollHandle = handle
        record.specialistHandle = delegated
            and (delegated.specialistHandle or delegated.specialist)
            or nil
        record.targetHandle = delegated
            and (delegated.targetHandle or delegated.target)
            or nil
        record.traceCount = record.traceCount or 0
        record.viewModelTraceCount = record.viewModelTraceCount or 0
        record.viewModelTraceAttempts = record.viewModelTraceAttempts or 0
        tracked[tostring(entity)] = record
        return record
    end

    local function traceRequestedRoll(entity, component, stage, changedFields)
        local record = stage == "destroyed"
            and tracked[tostring(entity)]
            or classify(entity, component)
        if record == nil then
            return false
        end
        record.traceCount = record.traceCount + 1
        if record.traceCount > 32 then
            if record.traceCount == 33 then
                write("client_requested_roll_state_suppressed", {
                    action = record.action,
                    delegation_id = record.delegationId,
                    limit = 32,
                    profile_mode = record.profileMode,
                    roll_entity = tostring(entity),
                })
            end
            return true
        end

        local result = safeField(component, "Result")
        local roll = safeField(component, "Roll")
        local rollDefinition = roll and safeField(roll, "Roll") or nil
        local metadata = safeField(component, "Metadata")
        write("client_requested_roll_state", {
            action = record.action,
            additional_value = safeField(component, "AdditionalValue"),
            ability = safeField(component, "Ability"),
            advantage_type = safeField(component, "AdvantageType"),
            canceled = safeField(component, "Canceled"),
            changed_fields = changedFields,
            consumed_inspiration = safeField(component, "ConsumedInspirationPoint"),
            dc = safeField(component, "DC"),
            delegation_id = record.delegationId,
            dice_additional_value = safeField(component, "DiceAdditionalValue"),
            discarded_dice_total = safeField(component, "DiscardedDiceTotal"),
            finished = safeField(component, "Finished"),
            fixed_bonus_count = arrayLength(safeField(component, "FixedRollBonuses")),
            initiator_handle = record.initiatorHandle,
            metadata_ability_boosts = metadata
                and describeMap(safeField(metadata, "AbilityBoosts")) or nil,
            metadata_auto_ability_check_fail = metadata
                and safeField(metadata, "AutoAbilityCheckFail") or nil,
            metadata_auto_skill_check_fail = metadata
                and safeField(metadata, "AutoSkillCheckFail") or nil,
            metadata_fixed_bonus_count = metadata
                and arrayLength(safeField(metadata, "FixedRollBonuses")) or 0,
            metadata_has_custom = metadata and safeField(metadata, "HasCustomMetadata") or nil,
            metadata_is_critical = metadata and safeField(metadata, "IsCritical") or nil,
            metadata_proficiency_bonus = metadata
                and safeField(metadata, "ProficiencyBonus") or nil,
            metadata_resolved_bonus_count = metadata
                and arrayLength(safeField(metadata, "ResolvedRollBonuses")) or 0,
            metadata_roll_bonus = metadata and safeField(metadata, "RollBonus") or nil,
            metadata_skill_bonuses = metadata
                and describeMap(safeField(metadata, "SkillBonuses")) or nil,
            natural_roll = safeField(component, "NaturalRoll"),
            observed_at = monotonicTime(),
            profile_mode = record.profileMode,
            request_stop = safeField(component, "RequestStop"),
            resolved_bonus_count = arrayLength(safeField(component, "ResolvedRollBonuses")),
            result_critical = result and safeField(result, "Critical") or nil,
            result_discarded_dice_total = result
                and safeField(result, "DiscardedDiceTotal") or nil,
            result_natural_roll = result and safeField(result, "NaturalRoll") or nil,
            result_roll_count = result and arrayLength(safeField(result, "RollsCount")) or 0,
            result_rolls = result and describeArray(safeField(result, "RollsCount"), {
                "RollValue",
                "RerollType",
            }) or nil,
            result_total = result and safeField(result, "Total") or nil,
            roll_advantage = roll and safeField(roll, "Advantage") or nil,
            roll_amount_of_dice = rollDefinition
                and safeField(rollDefinition, "AmountOfDices") or nil,
            roll_context = safeField(component, "RollContext"),
            roll_component_type = safeField(component, "RollComponentType"),
            roll_definition_additional_value = rollDefinition
                and safeField(rollDefinition, "DiceAdditionalValue") or nil,
            roll_dice_negative = rollDefinition
                and safeField(rollDefinition, "DiceNegative") or nil,
            roll_dice_value = rollDefinition and safeField(rollDefinition, "DiceValue") or nil,
            roll_disadvantage = roll and safeField(roll, "Disadvantage") or nil,
            roll_entity = tostring(entity),
            roll_component = tostring(component),
            roll_handle = record.rollHandle,
            roll_reroll_condition_count = roll
                and arrayLength(safeField(roll, "RerollConditions")) or 0,
            roll_reroll_conditions = roll and describeArray(
                safeField(roll, "RerollConditions"),
                { "RollValue", "KeepNew" }
            ) or nil,
            roll_type = safeField(component, "RollType"),
            roller = entityGuid(safeField(component, "Roller")),
            skill = safeField(component, "Skill"),
            specialist_handle = record.specialistHandle,
            stage = stage,
            subject = entityGuid(safeField(component, "Subject")),
            target_handle = record.targetHandle,
        })
        for index, bonus in pairs(safeField(component, "FixedRollBonuses") or {}) do
            write("client_fixed_roll_bonus", {
                action = record.action,
                delegation_id = record.delegationId,
                index = index,
                profile_mode = record.profileMode,
                roll_bonus = safeField(bonus, "RollBonus"),
                source_name = safeField(bonus, "SourceName"),
            })
        end
        for index, bonus in pairs(safeField(component, "ResolvedRollBonuses") or {}) do
            write("client_resolved_roll_bonus", {
                action = record.action,
                bonus = safeField(bonus, "Bonus"),
                delegation_id = record.delegationId,
                dice_size = safeField(bonus, "DiceSize"),
                index = index,
                num_dice = safeField(bonus, "NumDice"),
                profile_mode = record.profileMode,
                source_name = safeField(bonus, "SourceName"),
            })
        end
        for index, bonus in pairs(
            metadata and safeField(metadata, "FixedRollBonuses") or {}
        ) do
            write("client_metadata_fixed_roll_bonus", {
                action = record.action,
                delegation_id = record.delegationId,
                index = index,
                profile_mode = record.profileMode,
                roll_bonus = safeField(bonus, "RollBonus"),
                source_name = safeField(bonus, "SourceName"),
            })
        end
        for index, bonus in pairs(
            metadata and safeField(metadata, "ResolvedRollBonuses") or {}
        ) do
            write("client_metadata_resolved_roll_bonus", {
                action = record.action,
                bonus = safeField(bonus, "Bonus"),
                delegation_id = record.delegationId,
                dice_size = safeField(bonus, "DiceSize"),
                index = index,
                num_dice = safeField(bonus, "NumDice"),
                profile_mode = record.profileMode,
                source_name = safeField(bonus, "SourceName"),
            })
        end
        return true
    end

    local function traceModifier(
        record,
        category,
        groupIndex,
        modifierIndex,
        modifier,
        group
    )
        if modifier == nil then
            return
        end
        local source = safeField(modifier, "Source")
        write("client_roll_modifier", {
            action = record.action,
            advantage = safeField(modifier, "Advantage"),
            advantage_type = safeField(modifier, "AdvantageType"),
            amount_of_dice = safeField(modifier, "AmountOfDices"),
            boost_type = safeField(modifier, "BoostType"),
            category = category,
            delegation_id = record.delegationId,
            dice_value = safeField(modifier, "DiceValue"),
            group_disabled = safeField(group, "Disabled"),
            group_index = groupIndex,
            modifier_index = modifierIndex,
            profile_mode = record.profileMode,
            source_cause = source and safeField(source, "Cause") or nil,
            source_stack = source and safeField(source, "StackId") or nil,
            source_type = source and safeField(source, "SourceType") or nil,
            total_value = safeField(modifier, "TotalValue"),
            value = safeField(modifier, "Value"),
        })
    end

    local function traceModifierGroups(record, category, groups)
        for groupIndex, group in pairs(groups or {}) do
            local nested = safeField(group, "Modifiers")
            if nested ~= nil then
                for modifierIndex, modifier in pairs(nested) do
                    traceModifier(
                        record,
                        category,
                        groupIndex,
                        modifierIndex,
                        modifier,
                        group
                    )
                end
            else
                traceModifier(
                    record,
                    category,
                    groupIndex,
                    1,
                    safeField(group, "Modifier"),
                    group
                )
            end
        end
    end

    local function traceModifiers(entity, component, stage, changedFields)
        local rollEntity = Ext.Entity.Get(entity)
        local requestedRoll = rollEntity and rollEntity.RequestedRoll or nil
        local record = requestedRoll and classify(entity, requestedRoll)
            or tracked[tostring(entity)]
        if record == nil then
            return false
        end
        local profileEntity = safeField(component, "Entity")
        local profileEntityHandle = entityHandle(profileEntity)
        write("client_roll_modifiers", {
            action = record.action,
            changed_fields = changedFields,
            consumable = arrayLength(safeField(component, "ConsumableModifiers")),
            delegation_id = record.delegationId,
            dynamic = arrayLength(safeField(component, "DynamicModifiers"))
                + arrayLength(safeField(component, "DynamicModifiers2"))
                + arrayLength(safeField(component, "DynamicModifiers3")),
            item_spell = arrayLength(safeField(component, "ItemSpellModifiers")),
            observed_at = monotonicTime(),
            profile_entity = profileEntity,
            profile_entity_guid = entityGuid(profileEntity),
            profile_entity_handle = profileEntityHandle,
            profile_matches_initiator = sameHandle(
                profileEntityHandle,
                record.initiatorHandle
            ) and 1 or 0,
            profile_matches_specialist = sameHandle(
                profileEntityHandle,
                record.specialistHandle
            ) and 1 or 0,
            profile_mode = record.profileMode,
            roll_entity = tostring(entity),
            spell = arrayLength(safeField(component, "SpellModifiers")),
            stage = stage,
            static = arrayLength(safeField(component, "StaticModifiers")),
            toggled_passive = arrayLength(safeField(component, "ToggledPassiveModifiers")),
        })
        traceModifierGroups(record, "static", safeField(component, "StaticModifiers"))
        traceModifierGroups(record, "consumable", safeField(component, "ConsumableModifiers"))
        traceModifierGroups(record, "item_spell", safeField(component, "ItemSpellModifiers"))
        traceModifierGroups(record, "spell", safeField(component, "SpellModifiers"))
        traceModifierGroups(
            record,
            "toggled_passive",
            safeField(component, "ToggledPassiveModifiers")
        )
        return true
    end

    local function protected(event, callback)
        return function(...)
            local arguments = { ... }
            local ok, errorMessage = xpcall(function()
                callback(table.unpack(arguments))
            end, debug.traceback)
            if not ok then
                traceError(event, errorMessage)
            end
        end
    end

    Ext.Entity.OnCreate("RequestedRoll", protected(
        "client_requested_roll_create_failed",
        function(entity, _, component)
            traceRequestedRoll(entity, component, "created", nil)
            scheduleActiveRollSnapshots(
                tracked[tostring(entity)],
                "requested_roll_created",
                { 0, 16, 50, 100, 250, 500, 1000, 2000 }
            )
        end
    ))
    Ext.Entity.OnChange("RequestedRoll", protected(
        "client_requested_roll_change_failed",
        function(entity, _, changedFields)
            local rollEntity = Ext.Entity.Get(entity)
            local component = rollEntity and rollEntity.RequestedRoll or nil
            if component ~= nil then
                traceRequestedRoll(entity, component, "changed", changedFields)
                local record = tracked[tostring(entity)]
                if record ~= nil then
                    record.viewModelChangeSchedules =
                        (record.viewModelChangeSchedules or 0) + 1
                    if record.viewModelChangeSchedules <= 4 then
                        scheduleActiveRollSnapshots(
                            record,
                            "requested_roll_changed_"
                                .. tostring(record.viewModelChangeSchedules),
                            {
                                0, 16, 50, 100, 250, 500, 750,
                                1000, 1500, 2500,
                            }
                        )
                    end
                end
            end
        end
    ))
    Ext.Entity.OnDestroy("RequestedRoll", protected(
        "client_requested_roll_destroy_failed",
        function(entity, _, component)
            traceRequestedRoll(entity, component, "destroyed", nil)
            tracked[tostring(entity)] = nil
        end
    ))
    Ext.Entity.OnCreate("RollModifiers", protected(
        "client_roll_modifiers_create_failed",
        function(entity, _, component)
            traceModifiers(entity, component, "created", nil)
            scheduleActiveRollSnapshots(
                tracked[tostring(entity)],
                "roll_modifiers_created",
                { 0, 16, 50, 100, 250, 500, 1000 }
            )
        end
    ))
    Ext.Entity.OnChange("RollModifiers", protected(
        "client_roll_modifiers_change_failed",
        function(entity, _, changedFields)
            local rollEntity = Ext.Entity.Get(entity)
            local component = rollEntity and rollEntity.RollModifiers or nil
            if component ~= nil then
                traceModifiers(entity, component, "changed", changedFields)
                local record = tracked[tostring(entity)]
                if record ~= nil then
                    record.viewModelModifierSchedules =
                        (record.viewModelModifierSchedules or 0) + 1
                    if record.viewModelModifierSchedules <= 4 then
                        scheduleActiveRollSnapshots(
                            record,
                            "roll_modifiers_changed_"
                                .. tostring(record.viewModelModifierSchedules),
                            {
                                0, 16, 50, 100, 250, 500, 750,
                                1000, 1500, 2500,
                            }
                        )
                    end
                end
            end
        end
    ))
    if traceEnabled() then
        write("client_roll_ui_observers_ready", {
            active_roll_viewmodel_trace = 0,
            active_roll_visual_tree_trace = 0,
            default_trace = defaultTrace and 1 or 0,
            delegated_advantage_ui_sync = 0,
            native_client_roll_aggregate = 1,
            native_client_roll_finalize = 1,
            native_client_roll_phase = 1,
            native_client_roll_presentation = 1,
            native_client_roll_result = 1,
            native_client_roll_start = 1,
            native_client_modifier_animation = 1,
        })
    end
end

return UiRollDiagnostics
