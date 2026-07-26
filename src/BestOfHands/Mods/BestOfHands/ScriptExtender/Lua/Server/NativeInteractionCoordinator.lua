-- SPDX-License-Identifier: Unlicense

local NativeInteractionCoordinator = {}
local GUID_PATTERN = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"

local function objectGuid(value)
    if value == nil then
        return nil
    end
    return tostring(value):lower():match(GUID_PATTERN)
end

local function sameObject(left, right)
    local leftGuid = objectGuid(left)
    local rightGuid = objectGuid(right)
    if leftGuid ~= nil and rightGuid ~= nil then
        return leftGuid == rightGuid
    end
    return tostring(left) == tostring(right)
end

local function entityGuid(value)
    local ok, result = pcall(function()
        local entity = Ext.Entity.Get(value)
        return entity and entity.Uuid and tostring(entity.Uuid.EntityUuid) or nil
    end)
    return ok and result or nil
end

local function arrayLength(value)
    local ok, result = pcall(function() return #value end)
    return ok and result or 0
end

local function safeField(value, field)
    local ok, result = pcall(function() return value[field] end)
    return ok and result or nil
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

local function profileMode(record)
    return record.isReference and "vanilla_reference" or "delegated"
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

local function traceRequestedRollState(diagnostics, record, entity, component, stage, changedFields)
    if type(diagnostics.IsTraceEnabled) == "function"
        and not diagnostics.IsTraceEnabled() then
        return
    end
    local result = safeField(component, "Result")
    local roll = safeField(component, "Roll")
    local rollDefinition = roll and safeField(roll, "Roll") or nil
    local metadata = safeField(component, "Metadata")
    diagnostics.Trace("native_requested_roll_state", {
        action = record.action,
        additional_value = safeField(component, "AdditionalValue"),
        ability = safeField(component, "Ability"),
        advantage_type = safeField(component, "AdvantageType"),
        canceled = safeField(component, "Canceled"),
        changed_fields = changedFields,
        comparison_id = record.comparisonId,
        consumed_inspiration = safeField(component, "ConsumedInspirationPoint"),
        dc = safeField(component, "DC"),
        delegation_id = record.delegationId,
        dice_additional_value = safeField(component, "DiceAdditionalValue"),
        discarded_dice_total = safeField(component, "DiscardedDiceTotal"),
        entity_2_uuid = safeField(component, "Entity2Uuid"),
        entity_uuid = safeField(component, "EntityUuid"),
        finished = safeField(component, "Finished"),
        fixed_bonus_count = arrayLength(safeField(component, "FixedRollBonuses")),
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
        profile_mode = profileMode(record),
        request_stop = safeField(component, "RequestStop"),
        reference_id = record.referenceId,
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
        roll_amount_of_dice = rollDefinition
            and safeField(rollDefinition, "AmountOfDices") or nil,
        roll_advantage = roll and safeField(roll, "Advantage") or nil,
        roll_component_type = safeField(component, "RollComponentType"),
        roll_context = safeField(component, "RollContext"),
        roll_definition_additional_value = rollDefinition
            and safeField(rollDefinition, "DiceAdditionalValue") or nil,
        roll_dice_negative = rollDefinition
            and safeField(rollDefinition, "DiceNegative") or nil,
        roll_dice_value = rollDefinition and safeField(rollDefinition, "DiceValue") or nil,
        roll_disadvantage = roll and safeField(roll, "Disadvantage") or nil,
        roll_entity = tostring(entity),
        roll_reroll_condition_count = roll
            and arrayLength(safeField(roll, "RerollConditions")) or 0,
        roll_reroll_conditions = roll and describeArray(
            safeField(roll, "RerollConditions"),
            { "RollValue", "KeepNew" }
        ) or nil,
        roll_type = safeField(component, "RollType"),
        roller = entityGuid(safeField(component, "Roller")),
        skill = safeField(component, "Skill"),
        specialist = record.specialist,
        stage = stage,
        subject = entityGuid(safeField(component, "Subject")),
        target = record.target,
    })
end

local function traceModifier(diagnostics, record, category, groupIndex, modifierIndex, modifier)
    if modifier == nil then
        return
    end
    local source = safeField(modifier, "Source")
    diagnostics.Trace("native_profile_modifier", {
        action = record.action,
        advantage = safeField(modifier, "Advantage"),
        advantage_type = safeField(modifier, "AdvantageType"),
        amount_of_dice = safeField(modifier, "AmountOfDices"),
        boost_type = safeField(modifier, "BoostType"),
        category = category,
        comparison_id = record.comparisonId,
        critical_hit_type = safeField(modifier, "CriticalHitType"),
        delegation_id = record.delegationId,
        dice_value = safeField(modifier, "DiceValue"),
        group_index = groupIndex,
        modifier_index = modifierIndex,
        profile_mode = profileMode(record),
        reference_id = record.referenceId,
        source_cause = source and safeField(source, "Cause") or nil,
        source_entity = source and safeField(source, "Source") or nil,
        source_equipment = source and safeField(source, "Equipment") or nil,
        source_stack = source and safeField(source, "StackId") or nil,
        source_type = source and safeField(source, "SourceType") or nil,
        total_value = safeField(modifier, "TotalValue"),
        value = safeField(modifier, "Value"),
    })
end

local function traceModifierGroup(diagnostics, record, category, groupIndex, group)
    diagnostics.Trace("native_profile_modifier_group", {
        action = record.action,
        category = category,
        comparison_id = record.comparisonId,
        concentration = safeField(group, "Concentration"),
        delegation_id = record.delegationId,
        disabled = safeField(group, "Disabled"),
        group_index = groupIndex,
        item = safeField(group, "Item"),
        modifier_guid = safeField(group, "ModifierGuid"),
        passive = safeField(group, "Passive"),
        passive_entity = safeField(group, "PassiveEntity"),
        profile_mode = profileMode(record),
        reference_id = record.referenceId,
        source = safeField(group, "Source"),
        spell = safeField(group, "Spell"),
        target_type = safeField(group, "TargetType"),
    })
end

local function traceModifierGroups(diagnostics, record, category, groups)
    for groupIndex, group in pairs(groups or {}) do
        traceModifierGroup(diagnostics, record, category, groupIndex, group)
        local nested = safeField(group, "Modifiers")
        if nested ~= nil then
            for modifierIndex, modifier in pairs(nested) do
                traceModifier(diagnostics, record, category, groupIndex, modifierIndex, modifier)
            end
        else
            traceModifier(
                diagnostics,
                record,
                category,
                groupIndex,
                1,
                safeField(group, "Modifier")
            )
        end
    end
end

local function aggregateAdvantageType(component)
    local hasAdvantage = false
    local hasDisadvantage = false
    local function observe(modifier, group)
        if modifier == nil or safeField(group, "Disabled") == true then
            return
        end
        local value = tostring(safeField(modifier, "AdvantageType") or "None")
        if value == "Advantage" or value == "1" then
            hasAdvantage = true
        elseif value == "Disadvantage" or value == "2" then
            hasDisadvantage = true
        end
    end
    local function observeGroups(groups)
        for _, group in pairs(groups or {}) do
            local nested = safeField(group, "Modifiers")
            if nested ~= nil then
                for _, modifier in pairs(nested) do
                    observe(modifier, group)
                end
            else
                observe(safeField(group, "Modifier"), group)
            end
        end
    end
    observeGroups(safeField(component, "StaticModifiers"))
    observeGroups(safeField(component, "ConsumableModifiers"))
    observeGroups(safeField(component, "ItemSpellModifiers"))
    observeGroups(safeField(component, "SpellModifiers"))
    observeGroups(safeField(component, "ToggledPassiveModifiers"))
    if hasAdvantage == hasDisadvantage then
        return 0
    end
    return hasAdvantage and 1 or 2
end

function NativeInteractionCoordinator.Create(settings, api, resolver, bridge, diagnostics)
    local instance = {}
    local pendingByTarget = {}
    local pendingByRollUuid = {}
    local pendingByRollEntity = {}
    local referencesByTarget = {}
    local referencesByRollUuid = {}
    local referencesByRollEntity = {}
    local nextDelegationId = 1
    local nextReferenceId = 1

    local function targetKey(action, target)
        return tostring(action) .. "|" .. tostring(target)
    end

    local function traceEnabled()
        return type(diagnostics.IsTraceEnabled) ~= "function"
            or diagnostics.IsTraceEnabled()
    end

    local function clearReference(record, reason)
        if record == nil or record.cleared then
            return
        end
        record.cleared = true
        local key = targetKey(record.action, record.target)
        if referencesByTarget[key] == record then
            referencesByTarget[key] = nil
        end
        if record.rollUuid ~= nil
            and referencesByRollUuid[record.rollUuid] == record then
            referencesByRollUuid[record.rollUuid] = nil
        end
        if record.rollEntityKey ~= nil
            and referencesByRollEntity[record.rollEntityKey] == record then
            referencesByRollEntity[record.rollEntityKey] = nil
        end
        diagnostics.Trace("native_reference_cleared", {
            action = record.action,
            actor = record.initiator,
            comparison_id = record.comparisonId,
            reason = reason,
            reference_id = record.referenceId,
            target = record.target,
        })
    end

    local function clear(record, reason)
        if record == nil or record.cleared then
            return
        end
        record.cleared = true
        local key = targetKey(record.action, record.target)
        if pendingByTarget[key] == record then
            pendingByTarget[key] = nil
        end
        if record.rollUuid ~= nil and pendingByRollUuid[record.rollUuid] == record then
            pendingByRollUuid[record.rollUuid] = nil
        end
        if record.rollEntityKey ~= nil
            and pendingByRollEntity[record.rollEntityKey] == record then
            pendingByRollEntity[record.rollEntityKey] = nil
        end
        bridge.Remove(record.delegationId)
        diagnostics.Trace("native_delegation_cleared", {
            action = record.action,
            actor = record.initiator,
            delegation_id = record.delegationId,
            reason = reason,
            specialist = record.specialist,
            target = record.target,
        })
    end

    local function findInBySubjects(records, subjects)
        for _, record in pairs(records) do
            for _, subject in ipairs(subjects or {}) do
                if sameObject(record.target, subject)
                    or sameObject(entityGuid(record.target), subject) then
                    return record
                end
            end
        end
        return nil
    end

    local function findBySubjects(subjects)
        return findInBySubjects(pendingByTarget, subjects)
    end

    local function findReferenceBySubjects(subjects)
        return findInBySubjects(referencesByTarget, subjects)
    end

    local function armReference(action, actor, target, requestId, score)
        if not traceEnabled() then
            return
        end
        local key = targetKey(action, target)
        clearReference(referencesByTarget[key], "superseded_reference_request")
        local referenceId = nextReferenceId
        nextReferenceId = nextReferenceId + 1
        local record = {
            action = action,
            comparisonId = "reference-" .. tostring(referenceId),
            initiator = actor,
            initiatorScore = score,
            isReference = true,
            phase = "awaiting_reference_roll",
            referenceId = referenceId,
            requestId = requestId,
            specialist = actor,
            specialistScore = score,
            target = target,
        }
        referencesByTarget[key] = record
        diagnostics.Trace("native_reference_armed", {
            action = action,
            actor = actor,
            comparison_id = record.comparisonId,
            reference_id = referenceId,
            request_id = requestId,
            score = score,
            target = target,
        })
        api.Schedule(settings.NATIVE_REFERENCE_TRACE_TIMEOUT_MS or 30000, function()
            if referencesByTarget[key] == record then
                clearReference(record, "reference_trace_timeout")
            end
        end)
    end

    local function matchesParticipant(record, value)
        if value == nil then
            return false
        end
        for _, participant in ipairs({
            record.initiator,
            record.specialist,
            record.target,
            entityGuid(record.initiator),
            entityGuid(record.specialist),
            entityGuid(record.target),
        }) do
            if participant ~= nil
                and (sameObject(value, participant)
                    or sameObject(entityGuid(value), participant)) then
                return true
            end
        end
        return false
    end

    function instance.OnNativeRequest(action, actor, target, requestId)
        if not bridge.IsReady() then
            diagnostics.Warn("native_delegation_skipped", {
                action = action,
                actor = actor,
                reason = "native_bridge_not_ready",
                request_id = requestId,
                target = target,
            })
            return false
        end

        local tool = api.FindNativeActionTool(action, actor)
        if tool == nil then
            local responsePublished, notificationShown =
                api.RejectNativeActionWithoutTool(action, actor, target)
            local trace = responsePublished and diagnostics.Info or diagnostics.Error
            trace("native_tool_unavailable_rejected", {
                action = action,
                actor = actor,
                notification_shown = notificationShown and 1 or 0,
                request_id = requestId,
                response_published = responsePublished and 1 or 0,
                target = target,
            })
            -- Do not arm delegation. The custom result is consumed by the
            -- existing vanilla PROC_Process* rule, which reports
            -- RequestProcessed(..., 0) and prevents an empty-tool roll.
            return false
        end
        diagnostics.Trace("native_tool_observed", {
            action = action,
            actor = actor,
            item = tool.item,
            owner = tool.owner,
            request_id = requestId,
            target = target,
            template = tool.template,
        })

        local key = targetKey(action, target)
        local previous = pendingByTarget[key]
        if previous ~= nil then
            clear(previous, "superseded_by_native_request")
        end

        local resolution = resolver.Resolve(actor, target, action, requestId)
        if resolution == nil then
            diagnostics.Warn("native_delegation_skipped", {
                action = action,
                actor = actor,
                reason = "specialist_unavailable",
                request_id = requestId,
                target = target,
            })
            return false
        end
        if sameObject(resolution.specialist, actor) then
            diagnostics.Trace("native_delegation_not_needed", {
                action = action,
                actor = actor,
                request_id = requestId,
                target = target,
            })
            armReference(
                action,
                actor,
                target,
                requestId,
                resolution.specialistScore or resolution.initiatorScore
            )
            return false
        end

        local record = {
            action = action,
            comparisonId = "delegation-" .. tostring(nextDelegationId),
            delegationId = nextDelegationId,
            initiator = actor,
            initiatorScore = resolution.initiatorScore,
            phase = "awaiting_native_profile",
            requestId = requestId,
            specialist = resolution.specialist,
            specialistScore = resolution.specialistScore,
            target = target,
        }
        nextDelegationId = nextDelegationId + 1
        local written, reason, handles = bridge.Upsert({
            action = action,
            id = record.delegationId,
            initiator = actor,
            specialist = record.specialist,
            target = target,
        })
        if not written then
            diagnostics.Error("native_delegation_skipped", {
                action = action,
                actor = actor,
                reason = reason,
                request_id = requestId,
                target = target,
            })
            return false
        end
        record.handles = handles
        pendingByTarget[key] = record
        diagnostics.Info("native_delegation_armed", {
            action = action,
            actor = actor,
            actor_handle = handles.initiatorHandle,
            actor_score = record.initiatorScore,
            delegation_id = record.delegationId,
            request_id = requestId,
            specialist = record.specialist,
            specialist_handle = handles.specialistHandle,
            specialist_score = record.specialistScore,
            target = target,
            target_handle = handles.targetHandle,
        })

        api.Schedule(settings.NATIVE_ACTION_TIMEOUT_MS, function()
            if pendingByTarget[key] == record then
                clear(record, "native_action_timeout")
            end
        end)
        -- Observation only: vanilla's original permission, task, tool, crime,
        -- roll and outcome pipelines remain authoritative.
        return false
    end

    function instance.OnNativeStarted(action, actor, target)
        local record = pendingByTarget[targetKey(action, target)]
        if record ~= nil then
            record.phase = "native_action_started"
            diagnostics.Trace("native_action_started", {
                action = action,
                actor = actor,
                delegation_id = record.delegationId,
                specialist = record.specialist,
                target = target,
            })
        end
    end

    function instance.OnNativeStopped(action, actor, target)
        local record = pendingByTarget[targetKey(action, target)]
        if record ~= nil then
            if record.rollEntityKey ~= nil then
                diagnostics.Trace("native_action_stopped_deferred", {
                    action = action,
                    actor = actor,
                    delegation_id = record.delegationId,
                    phase = record.phase,
                    specialist = record.specialist,
                    target = target,
                })
                return
            end
            clear(record, "native_action_stopped_before_roll")
        end
    end

    function instance.OnRollResult(eventName, actor, target, result, isActive, criticality)
        local record = findBySubjects({ target })
        if record == nil then
            return false
        end
        local ownerMatchesInitiator = sameObject(actor, record.initiator)
            or sameObject(entityGuid(actor), record.initiator)
            or sameObject(actor, entityGuid(record.initiator))
        local trace = ownerMatchesInitiator and diagnostics.Info or diagnostics.Error
        trace("native_delegated_roll_result", {
            action = record.action,
            actor = actor,
            criticality = criticality,
            delegation_id = record.delegationId,
            event_name = eventName,
            is_active = isActive,
            owner_matches_initiator = ownerMatchesInitiator and 1 or 0,
            result = result,
            specialist = record.specialist,
            target = target,
        })
        if not ownerMatchesInitiator then
            -- This result cannot complete the initiator-owned native action.
            -- Retain the record so a subsequent correct result can be observed,
            -- otherwise the normal timeout will remove it.
            return false
        end
        local numericResult = tonumber(result)
        if numericResult == 1 then
            api.Schedule(0, function()
                if pendingByTarget[targetKey(record.action, record.target)] == record then
                    clear(record, "native_roll_success")
                end
            end)
        elseif numericResult == 2 then
            -- BG3's RollResult contract uses 2 for a canceled active roll.
            -- It is terminal and cannot become an Inspiration retry.
            api.Schedule(0, function()
                if pendingByTarget[targetKey(record.action, record.target)] == record then
                    clear(record, "native_roll_canceled")
                end
            end)
        else
            -- Inspiration retries reuse the same RequestedRoll. Keep its native
            -- profile mapping alive after failure; an accepted failure is later
            -- superseded by a new request or removed by the normal timeout.
            record.phase = "awaiting_native_retry_or_completion"
            diagnostics.Trace("native_delegation_retained_for_retry", {
                action = record.action,
                actor = record.initiator,
                delegation_id = record.delegationId,
                specialist = record.specialist,
                target = record.target,
            })
        end
        return true
    end

    function instance.OnRequestedRoll(entity, component)
        local subjects = {}
        for _, candidate in ipairs({
            entityGuid(component.Subject),
            tostring(component.EntityUuid or ""),
            tostring(component.Entity2Uuid or ""),
        }) do
            local guid = objectGuid(candidate)
            if guid ~= nil then
                subjects[#subjects + 1] = guid
            end
        end
        local record = findBySubjects(subjects)
        if record == nil then
            local reference = findReferenceBySubjects(subjects)
            if reference == nil then
                return false
            end
            local observedAction = actionFromRoll(component)
            if observedAction ~= nil and observedAction ~= reference.action then
                return false
            end
            reference.rollEntity = tostring(entity)
            reference.rollEntityKey = tostring(entity)
            referencesByRollEntity[reference.rollEntityKey] = reference
            reference.rollUuid = objectGuid(component.RollUuid)
            if reference.rollUuid ~= nil then
                referencesByRollUuid[reference.rollUuid] = reference
            end
            reference.phase = "reference_roll_correlated"
            diagnostics.Trace("native_reference_roll_correlated", {
                action = reference.action,
                actor = reference.initiator,
                comparison_id = reference.comparisonId,
                reference_id = reference.referenceId,
                roll_actor = entityGuid(component.Roller),
                roll_entity = reference.rollEntity,
                roll_uuid = reference.rollUuid,
                target = reference.target,
            })
            traceRequestedRollState(
                diagnostics,
                reference,
                entity,
                component,
                "created",
                nil
            )
            return true
        end

        local observedActor = entityGuid(component.Roller)
        local initiatorGuid = entityGuid(record.initiator)
        if not sameObject(observedActor, record.initiator)
            and not sameObject(observedActor, initiatorGuid) then
            diagnostics.Error("native_roll_correlation_failed", {
                action = record.action,
                actor = record.initiator,
                delegation_id = record.delegationId,
                observed_roll_actor = observedActor,
                reason = "unexpected_roll_actor",
                specialist = record.specialist,
                target = record.target,
            })
            bridge.Remove(record.delegationId)
            record.phase = "roll_correlation_failed"
            return false
        end

        local previousRollEntityKey = record.rollEntityKey
        local previousRollUuid = record.rollUuid
        record.rollEntity = tostring(entity)
        record.rollEntityKey = tostring(entity)
        if previousRollEntityKey ~= nil
            and pendingByRollEntity[previousRollEntityKey] == record then
            pendingByRollEntity[previousRollEntityKey] = nil
        end
        pendingByRollEntity[record.rollEntityKey] = record
        if previousRollUuid ~= nil and pendingByRollUuid[previousRollUuid] == record then
            pendingByRollUuid[previousRollUuid] = nil
        end
        record.rollUuid = objectGuid(component.RollUuid)
        if record.rollUuid ~= nil then
            pendingByRollUuid[record.rollUuid] = record
        end
        local written, reason, rollHandle = bridge.SetRoll(
            record.delegationId,
            entity,
            record.rollUuid
        )
        if not written then
            diagnostics.Error("native_roll_correlation_failed", {
                action = record.action,
                actor = record.initiator,
                delegation_id = record.delegationId,
                reason = reason,
                specialist = record.specialist,
                target = record.target,
            })
            record.phase = "roll_correlation_failed"
            bridge.Remove(record.delegationId)
            return false
        end
        record.phase = "roll_correlated"
        diagnostics.Info("native_roll_correlated", {
            action = record.action,
            actor = record.initiator,
            delegation_id = record.delegationId,
            roll_actor_after = entityGuid(component.Roller),
            roll_actor_before = observedActor,
            roll_entity = record.rollEntity,
            roll_handle = rollHandle,
            roll_uuid = record.rollUuid,
            specialist = record.specialist,
            target = record.target,
        })
        traceRequestedRollState(diagnostics, record, entity, component, "created", nil)
        return true
    end

    function instance.OnRequestedRollChanged(entity, component, changedFields)
        local record = pendingByRollEntity[tostring(entity)]
            or referencesByRollEntity[tostring(entity)]
        if record == nil then
            return false
        end
        record.requestedRollTraceCount = (record.requestedRollTraceCount or 0) + 1
        if record.requestedRollTraceCount <= 24 then
            traceRequestedRollState(
                diagnostics,
                record,
                entity,
                component,
                "changed",
                changedFields
            )
        elseif record.requestedRollTraceCount == 25 then
            diagnostics.Trace("native_requested_roll_state_suppressed", {
                action = record.action,
                delegation_id = record.delegationId,
                limit = 24,
                roll_entity = tostring(entity),
            })
        end
        -- RequestedRoll.Canceled is also observed during ordinary completed
        -- rolls and cannot safely own lifecycle teardown. The Osiris
        -- RollResult contract (2 = canceled), supersession, and timeout are
        -- the authoritative terminal paths.
        return true
    end

    function instance.OnRequestedRollDestroyed(entity, component)
        local rollEntityKey = tostring(entity)
        local record = pendingByRollEntity[rollEntityKey]
            or referencesByRollEntity[rollEntityKey]
        if record == nil then
            return false
        end
        traceRequestedRollState(diagnostics, record, entity, component, "destroyed", nil)
        if record.isReference then
            referencesByRollEntity[rollEntityKey] = nil
            record.phase = "reference_roll_destroyed_awaiting_finished_event"
            diagnostics.Trace("native_reference_retained_after_roll_destroy", {
                action = record.action,
                actor = record.initiator,
                comparison_id = record.comparisonId,
                reference_id = record.referenceId,
                result_total = safeField(safeField(component, "Result"), "Total"),
                target = record.target,
            })
            return true
        end
        pendingByRollEntity[rollEntityKey] = nil
        -- RequestedRoll is destroyed before BG3's later RollResult/post-roll
        -- UI path, including ordinary failures. Keep the bridge record alive
        -- so native Inspiration and lockpick Try Again retain the specialist
        -- profile. RollResult, a superseding request, or the bounded action
        -- timeout owns terminal cleanup.
        record.phase = "roll_component_destroyed_awaiting_result"
        diagnostics.Trace("native_delegation_retained_after_roll_destroy", {
            action = record.action,
            actor = record.initiator,
            dc = safeField(component, "DC"),
            delegation_id = record.delegationId,
            result_total = safeField(safeField(component, "Result"), "Total"),
            specialist = record.specialist,
            target = record.target,
        })
        return true
    end

    function instance.OnRollModifiers(entity, component, stage, changedFields)
        local record = pendingByRollEntity[tostring(entity)]
            or referencesByRollEntity[tostring(entity)]
        if record == nil then
            return false
        end
        local tracing = traceEnabled()
        local traceThisChange = tracing
        if tracing then
            record.modifierTraceCount = (record.modifierTraceCount or 0) + 1
            if record.modifierTraceCount > 16 then
                if record.modifierTraceCount == 17 then
                    diagnostics.Trace("native_modifier_trace_suppressed", {
                        action = record.action,
                        delegation_id = record.delegationId,
                        limit = 16,
                        roll_entity = tostring(entity),
                    })
                end
                traceThisChange = false
            end
        end
        local requestedRoll = nil
        local observedActor = nil
        local observedDuringNativeCall = false
        if traceThisChange or not record.modifiersObservedLogged then
            pcall(function()
                local rollEntity = Ext.Entity.Get(entity)
                requestedRoll = rollEntity and rollEntity.RequestedRoll or nil
            end)
            observedActor = requestedRoll and entityGuid(requestedRoll.Roller) or nil
            observedDuringNativeCall = sameObject(observedActor, record.specialist)
                or sameObject(observedActor, entityGuid(record.specialist))
        end
        local presentationAdvantage = aggregateAdvantageType(component)
        if not record.isReference then
            local written, reason = bridge.SetPresentation(
                record.delegationId,
                presentationAdvantage
            )
            if not written then
                diagnostics.Warn("native_presentation_state_write_failed", {
                    action = record.action,
                    advantage_type = presentationAdvantage,
                    delegation_id = record.delegationId,
                    reason = reason,
                })
            end
        end
        record.phase = "modifiers_observed"
        if not record.modifiersObservedLogged then
            record.modifiersObservedLogged = true
            diagnostics.Info("native_modifiers_observed", {
                action = record.action,
                actor = record.initiator,
                changed_fields = changedFields,
                comparison_id = record.comparisonId,
                delegation_id = record.delegationId,
                fixed_bonus_count = requestedRoll
                    and arrayLength(requestedRoll.FixedRollBonuses) or 0,
                resolved_bonus_count = requestedRoll
                    and arrayLength(requestedRoll.ResolvedRollBonuses) or 0,
                observed_during_native_call = observedDuringNativeCall and 1 or 0,
                presentation_advantage_type = presentationAdvantage,
                profile_mode = profileMode(record),
                profile_entity = safeField(component, "Entity"),
                reference_id = record.referenceId,
                roll_actor_at_observer = observedActor,
                roll_entity = record.rollEntity,
                roll_uuid = record.rollUuid,
                specialist = record.specialist,
                stage = stage or "observed",
                target = record.target,
            })
        end
        if traceThisChange then
            for index, bonus in pairs(
                requestedRoll and requestedRoll.FixedRollBonuses or {}
            ) do
                diagnostics.Trace("native_profile_fixed_bonus", {
                    action = record.action,
                    comparison_id = record.comparisonId,
                    delegation_id = record.delegationId,
                    description = safeField(bonus, "Description"),
                    index = index,
                    profile_mode = profileMode(record),
                    reference_id = record.referenceId,
                    roll_bonus = safeField(bonus, "RollBonus"),
                    source_name = safeField(bonus, "SourceName"),
                })
            end
            for index, bonus in pairs(
                requestedRoll and requestedRoll.ResolvedRollBonuses or {}
            ) do
                diagnostics.Trace("native_profile_resolved_bonus", {
                    action = record.action,
                    bonus = safeField(bonus, "Bonus"),
                    comparison_id = record.comparisonId,
                    delegation_id = record.delegationId,
                    description = safeField(bonus, "Description"),
                    dice_size = safeField(bonus, "DiceSize"),
                    index = index,
                    num_dice = safeField(bonus, "NumDice"),
                    profile_mode = profileMode(record),
                    reference_id = record.referenceId,
                    resolved_bonus = safeField(bonus, "ResolvedRollBonus"),
                    source_name = safeField(bonus, "SourceName"),
                })
            end
            diagnostics.Trace("native_profile_modifier_counts", {
                action = record.action,
                comparison_id = record.comparisonId,
                consumable = arrayLength(component.ConsumableModifiers),
                delegation_id = record.delegationId,
                dynamic = arrayLength(component.DynamicModifiers)
                    + arrayLength(component.DynamicModifiers2)
                    + arrayLength(component.DynamicModifiers3),
                item_spell = arrayLength(component.ItemSpellModifiers),
                profile_mode = profileMode(record),
                reference_id = record.referenceId,
                spell = arrayLength(component.SpellModifiers),
                static = arrayLength(component.StaticModifiers),
                toggled_passive = arrayLength(component.ToggledPassiveModifiers),
            })
            traceModifierGroups(diagnostics, record, "static", component.StaticModifiers)
            traceModifierGroups(diagnostics, record, "consumable", component.ConsumableModifiers)
            traceModifierGroups(diagnostics, record, "item_spell", component.ItemSpellModifiers)
            traceModifierGroups(diagnostics, record, "spell", component.SpellModifiers)
            traceModifierGroups(
                diagnostics,
                record,
                "toggled_passive",
                component.ToggledPassiveModifiers
            )
            for _, category in ipairs({
                "DynamicModifiers",
                "DynamicModifiers2",
                "DynamicModifiers3",
            }) do
                for index, modifier in pairs(component[category] or {}) do
                    diagnostics.Trace("native_profile_dynamic_modifier", {
                        action = record.action,
                        category = category,
                        comparison_id = record.comparisonId,
                        delegation_id = record.delegationId,
                        index = index,
                        modifier_guid = safeField(modifier, "ModifierGuid"),
                        modifier_type = safeField(modifier, "Type"),
                        profile_mode = profileMode(record),
                        reference_id = record.referenceId,
                    })
                end
            end
        end
        return true
    end

    function instance.OnStartSpellRequest(entity, component)
        local tracing = traceEnabled()
        local originator = safeField(component, "Originator")
        local spell = safeField(component, "Spell")
        local targetValues = {}
        local targetDescriptions = {}
        for index, initialTarget in pairs(safeField(component, "Targets") or {}) do
            local value = safeField(initialTarget, "Target")
            targetValues[#targetValues + 1] = value
            if tracing then
                targetDescriptions[#targetDescriptions + 1] = string.format(
                    "%s:%s",
                    tostring(index),
                    tostring(entityGuid(value) or value)
                )
            end
        end

        local caster = safeField(component, "Caster")
        local source = safeField(component, "Source")
        local record = nil
        for _, candidate in pairs(pendingByTarget) do
            for _, value in ipairs(targetValues) do
                if matchesParticipant(candidate, value) then
                    record = candidate
                    break
                end
            end
            if record == nil
                and (matchesParticipant(candidate, caster)
                    or matchesParticipant(candidate, source)) then
                record = candidate
            end
            if record ~= nil then
                break
            end
        end
        if record == nil then
            return false
        end

        local targetMatchesInitiator = false
        local targetMatchesSpecialist = false
        for _, value in ipairs(targetValues) do
            targetMatchesInitiator = targetMatchesInitiator
                or sameObject(value, record.initiator)
                or sameObject(entityGuid(value), record.initiator)
                or sameObject(entityGuid(value), entityGuid(record.initiator))
            targetMatchesSpecialist = targetMatchesSpecialist
                or sameObject(value, record.specialist)
                or sameObject(entityGuid(value), record.specialist)
                or sameObject(entityGuid(value), entityGuid(record.specialist))
        end
        local retargeted = 0
        local retargetError = nil
        if targetMatchesInitiator and not targetMatchesSpecialist then
            local specialistEntity = Ext.Entity.Get(record.specialist)
            if specialistEntity == nil then
                retargetError = "specialist_entity_unavailable"
            else
                local ok, errorMessage = xpcall(function()
                    for _, initialTarget in pairs(
                        safeField(component, "Targets") or {}
                    ) do
                        local value = safeField(initialTarget, "Target")
                        if sameObject(value, record.initiator)
                            or sameObject(entityGuid(value), record.initiator)
                            or sameObject(
                                entityGuid(value),
                                entityGuid(record.initiator)
                            ) then
                            initialTarget.Target = specialistEntity
                            retargeted = retargeted + 1
                        end
                    end
                end, debug.traceback)
                if not ok then
                    retargetError = errorMessage
                    retargeted = 0
                end
            end
        end
        if tracing then
            diagnostics.Trace("native_roll_bonus_spell_request", {
                action = record.action,
                caster = entityGuid(caster) or caster,
                delegation_id = record.delegationId,
                flags = safeField(component, "Flags"),
                net_guid = safeField(component, "NetGUID"),
                originator_action_guid = originator
                    and safeField(originator, "ActionGuid") or nil,
                originator_interrupt = originator
                    and safeField(originator, "InterruptId") or nil,
                originator_passive = originator
                    and safeField(originator, "PassiveId") or nil,
                originator_status = originator
                    and safeField(originator, "StatusId") or nil,
                request_entity = tostring(entity),
                source = entityGuid(source) or source,
                specialist = record.specialist,
                spell = spell,
                spell_originator_prototype = spell
                    and safeField(spell, "OriginatorPrototype") or nil,
                spell_prototype = spell and safeField(spell, "Prototype") or nil,
                story_action_id = safeField(component, "StoryActionId"),
                target_count = #targetValues,
                target_matches_initiator = targetMatchesInitiator and 1 or 0,
                target_matches_specialist = targetMatchesSpecialist and 1 or 0,
                targets = table.concat(targetDescriptions, ","),
                targets_retargeted = retargeted,
            })
        end
        if retargetError ~= nil then
            diagnostics.Error("native_roll_bonus_retarget_failed", {
                action = record.action,
                delegation_id = record.delegationId,
                error = retargetError,
                specialist = record.specialist,
            })
            return false
        end
        if retargeted > 0 then
            local rewritten = {}
            for index, initialTarget in pairs(
                safeField(component, "Targets") or {}
            ) do
                local value = safeField(initialTarget, "Target")
                rewritten[#rewritten + 1] = string.format(
                    "%s:%s",
                    tostring(index),
                    tostring(entityGuid(value) or value)
                )
            end
            diagnostics.Info("native_roll_bonus_retargeted", {
                action = record.action,
                caster = entityGuid(caster) or caster,
                delegation_id = record.delegationId,
                original_target = record.initiator,
                rewritten_targets = table.concat(rewritten, ","),
                specialist = record.specialist,
                spell_prototype = spell and safeField(spell, "Prototype") or nil,
                target_count = retargeted,
            })
        end
        return true
    end

    function instance.OnFinishedEvents(entity, component, stage)
        for _, event in pairs(component.Events or {}) do
            local rollUuid = objectGuid(event.RollUuid)
            local record = rollUuid and pendingByRollUuid[rollUuid] or nil
            local reference = rollUuid and referencesByRollUuid[rollUuid] or nil
            if record == nil and reference ~= nil then
                diagnostics.Trace("native_reference_finished_event", {
                    action = reference.action,
                    actor = reference.initiator,
                    advantage = safeField(event, "Advantage"),
                    canceled = safeField(event, "Canceled"),
                    comparison_id = reference.comparisonId,
                    consumed_inspiration = safeField(event, "ConsumedInspirationPoint"),
                    dc = safeField(event, "DC"),
                    dice_additional_value = safeField(event, "DiceAdditionalValue"),
                    disadvantage = safeField(event, "Disadvantage"),
                    finished_event_entity = tostring(entity),
                    natural_roll = safeField(event, "NaturalRoll"),
                    reference_id = reference.referenceId,
                    roll_context = safeField(event, "RollContext"),
                    roll_type = safeField(event, "RollType"),
                    roller = entityGuid(event.Roller),
                    roll_uuid = rollUuid,
                    skill = safeField(event, "Skill"),
                    stage = stage,
                    target = reference.target,
                })
                clearReference(reference, "reference_finished_event")
                return true
            end
            if record ~= nil then
                local rollerBefore = entityGuid(event.Roller)
                local rollerAfter = rollerBefore
                local ownerMatchesInitiator = sameObject(rollerBefore, record.initiator)
                    or sameObject(rollerBefore, entityGuid(record.initiator))
                if not ownerMatchesInitiator then
                    diagnostics.Error("native_finished_event_owner_invalid", {
                        action = record.action,
                        actor = record.initiator,
                        delegation_id = record.delegationId,
                        reason = "unexpected_non_initiator_owner",
                        roll_uuid = rollUuid,
                        roller_after = rollerAfter,
                        roller_before = rollerBefore,
                        specialist = record.specialist,
                        target = record.target,
                    })
                    return false
                end
                local written, reason, finishedEventHandle = bridge.SetFinishedEvent(
                    record.delegationId,
                    entity
                )
                if not written then
                    diagnostics.Error("native_finished_event_correlation_failed", {
                        action = record.action,
                        actor = record.initiator,
                        delegation_id = record.delegationId,
                        reason = reason,
                        roll_uuid = rollUuid,
                        specialist = record.specialist,
                        target = record.target,
                    })
                    return false
                end
                record.finishedEventEntity = tostring(entity)
                record.phase = "finished_event_correlated"
                diagnostics.Trace("native_finished_event_correlated", {
                    action = record.action,
                    actor = record.initiator,
                    advantage = safeField(event, "Advantage"),
                    canceled = safeField(event, "Canceled"),
                    consumed_inspiration = safeField(event, "ConsumedInspirationPoint"),
                    dc = safeField(event, "DC"),
                    delegation_id = record.delegationId,
                    dice_additional_value = safeField(event, "DiceAdditionalValue"),
                    disadvantage = safeField(event, "Disadvantage"),
                    finished_event_entity = record.finishedEventEntity,
                    finished_event_handle = finishedEventHandle,
                    natural_roll = safeField(event, "NaturalRoll"),
                    owner_matches_initiator = 1,
                    roll_context = safeField(event, "RollContext"),
                    roll_type = safeField(event, "RollType"),
                    roller_after = rollerAfter,
                    roller_before = rollerBefore,
                    roll_uuid = rollUuid,
                    skill = safeField(event, "Skill"),
                    specialist = record.specialist,
                    stage = stage,
                    target = record.target,
                })
                return true
            end
        end
        return false
    end

    function instance.Subscribe()
        if Ext.Entity == nil or type(Ext.Entity.OnCreate) ~= "function" then
            diagnostics.Error("entity_observer_registration_failed", {
                component = "all",
                reason = "entity_create_api_unavailable",
            })
            return false
        end

        local function register(componentName, callback, deferred)
            local registration = Ext.Entity.OnCreate
            if deferred and type(Ext.Entity.OnCreateDeferred) == "function" then
                registration = Ext.Entity.OnCreateDeferred
            end
            local ok, subscriptionOrError = pcall(registration, componentName, callback)
            if not ok then
                diagnostics.Error("entity_observer_registration_failed", {
                    component = componentName,
                    deferred = deferred and 1 or 0,
                    error = subscriptionOrError,
                })
                return false
            end
            diagnostics.Trace("entity_observer_registered", {
                component = componentName,
                deferred = deferred and 1 or 0,
                subscription = subscriptionOrError,
            })
            return true
        end

        local function registerChange(componentName, callback)
            if type(Ext.Entity.OnChange) ~= "function" then
                diagnostics.Warn("entity_observer_registration_failed", {
                    component = componentName,
                    reason = "entity_change_api_unavailable",
                })
                return false
            end
            local ok, subscriptionOrError = pcall(Ext.Entity.OnChange, componentName, callback)
            if not ok then
                diagnostics.Warn("entity_observer_registration_failed", {
                    component = componentName,
                    error = subscriptionOrError,
                    observer = "change",
                })
                return false
            end
            diagnostics.Trace("entity_observer_registered", {
                component = componentName,
                observer = "change",
                subscription = subscriptionOrError,
            })
            return true
        end

        local function registerDestroy(componentName, callback)
            if type(Ext.Entity.OnDestroy) ~= "function" then
                diagnostics.Warn("entity_observer_registration_failed", {
                    component = componentName,
                    reason = "entity_destroy_api_unavailable",
                })
                return false
            end
            local ok, subscriptionOrError = pcall(Ext.Entity.OnDestroy, componentName, callback)
            if not ok then
                diagnostics.Warn("entity_observer_registration_failed", {
                    component = componentName,
                    error = subscriptionOrError,
                    observer = "destroy",
                })
                return false
            end
            diagnostics.Trace("entity_observer_registered", {
                component = componentName,
                observer = "destroy",
                subscription = subscriptionOrError,
            })
            return true
        end

        local requestedRollAvailable = register("RequestedRoll", function(entity, _, component)
            local ok, errorMessage = xpcall(function()
                instance.OnRequestedRoll(entity, component)
            end, debug.traceback)
            if not ok then
                diagnostics.Error("requested_roll_router_failed", { error = errorMessage })
            end
        end, false)
        registerChange("RequestedRoll", function(entity, _, changedFields)
            local ok, errorMessage = xpcall(function()
                local rollEntity = Ext.Entity.Get(entity)
                local component = rollEntity and rollEntity.RequestedRoll or nil
                if component ~= nil then
                    instance.OnRequestedRollChanged(entity, component, changedFields)
                end
            end, debug.traceback)
            if not ok then
                diagnostics.Error("requested_roll_change_observer_failed", {
                    error = errorMessage,
                })
            end
        end)
        registerDestroy("RequestedRoll", function(entity, _, component)
            local ok, errorMessage = xpcall(function()
                instance.OnRequestedRollDestroyed(entity, component)
            end, debug.traceback)
            if not ok then
                diagnostics.Error("requested_roll_destroy_observer_failed", {
                    error = errorMessage,
                })
            end
        end)
        local finishedEventAvailable = register("ServerRollFinishedEvent", function(entity, _, component)
            local ok, errorMessage = xpcall(function()
                instance.OnFinishedEvents(entity, component, "created")
            end, debug.traceback)
            if not ok then
                diagnostics.Error("finished_event_observer_failed", {
                    error = errorMessage,
                    stage = "created",
                })
            end
        end, true)
        register("RollModifiers", function(entity, _, component)
            local ok, errorMessage = xpcall(function()
                instance.OnRollModifiers(entity, component, "created", nil)
            end, debug.traceback)
            if not ok then
                diagnostics.Error("roll_modifier_trace_failed", { error = errorMessage })
            end
        end, false)
        registerChange("RollModifiers", function(entity, _, changedFields)
            local ok, errorMessage = xpcall(function()
                local rollEntity = Ext.Entity.Get(entity)
                local component = rollEntity and rollEntity.RollModifiers or nil
                if component ~= nil then
                    instance.OnRollModifiers(entity, component, "changed", changedFields)
                end
            end, debug.traceback)
            if not ok then
                diagnostics.Error("roll_modifier_change_trace_failed", { error = errorMessage })
            end
        end)
        register("ServerRollStartSpellRequest", function(entity, _, component)
            local ok, errorMessage = xpcall(function()
                instance.OnStartSpellRequest(entity, component)
            end, debug.traceback)
            if not ok then
                diagnostics.Error("roll_bonus_spell_request_trace_failed", {
                    error = errorMessage,
                })
            end
        end, false)
        return requestedRollAvailable and finishedEventAvailable
    end

    function instance.Count()
        local count = 0
        for _, _ in pairs(pendingByTarget) do
            count = count + 1
        end
        return count
    end

    function instance.Clear(reason)
        local pending = {}
        for _, record in pairs(pendingByTarget) do
            pending[#pending + 1] = record
        end
        for _, record in ipairs(pending) do
            clear(record, reason or "clear")
        end
        local references = {}
        for _, record in pairs(referencesByTarget) do
            references[#references + 1] = record
        end
        for _, record in ipairs(references) do
            clearReference(record, reason or "clear")
        end
    end

    return instance
end

return NativeInteractionCoordinator
