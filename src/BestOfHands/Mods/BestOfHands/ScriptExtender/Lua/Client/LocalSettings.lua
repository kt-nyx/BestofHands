-- SPDX-License-Identifier: Unlicense

local LocalSettings = {}
local FILE = "BestOfHands/ClientSettings.json"
local MODES = { "On", "Only while sneaking", "Off" }

local function validMode(value)
    for _, mode in ipairs(MODES) do if value == mode then return true end end
    return false
end

-- Automatic input belongs to this computer; party-roll modes belong to the host.
function LocalSettings.Start(settings)
    local instance, listeners = {}, {}
    local mode, registered = "On", false
    function instance.GetMode() return mode end
    function instance.IsEnabled(_, sneaking)
        return mode == "On" or (mode == "Only while sneaking" and sneaking == true)
    end
    function instance.Subscribe(callback) listeners[#listeners + 1] = callback end
    local function apply(value)
        if mode == value then return end
        mode = value
        for _, callback in ipairs(listeners) do callback() end
    end
    local function read()
        local ok, values = pcall(function()
            local text = Ext.IO.LoadFile(FILE)
            return type(text) == "string" and text ~= "" and Ext.Json.Parse(text) or {}
        end)
        if not ok or type(values) ~= "table" then values = {} end
        local value = values.left_click_lockpick
        if not validMode(value) then
            -- Preserve old Off first, then fold the former separate sneak switch
            -- into this feature's mode. It never restricted party-roll sharing.
            value = value == false and "Off"
                or (values.sneak_only_lockpick == true and "Only while sneaking" or "On")
        end
        apply(value)
    end
    local function render(tab)
        local groupId = "BestOfHands_PersonalLockpick"
        for _, child in ipairs(tab.Children) do if child.IDContext == groupId then return end end
        -- MCM already adds a 10px spacer after the first blueprint setting,
        -- but none after the last. Give both setting groups a 16px gap.
        for _, child in ipairs(tab.Children) do
            if child.IDContext == settings.MODULE_UUID .. "_best_in_party_lockpick_Group" then
                child:AddDummy(0, 6)
            elseif child.IDContext == settings.MODULE_UUID .. "_best_in_party_disarm_Group" then
                child:AddDummy(0, 16)
            end
        end
        local group = tab:AddGroup(groupId)
        group.IDContext = groupId
        local title = group:AddText("Left-click lockpick")
        title.TextWrapPos = 0
        -- Match MCM's SettingTitle and SettingDescription text styles.
        title:SetColor("Text", {250 / 255, 240 / 255, 220 / 255, 1})
        local combo = group:AddCombo("")
        combo.IDContext = groupId .. "_Mode"
        combo.Options = MODES
        local reset = group:AddImageButton("Reset to default", "ico_randomize_d", {32, 32})
        if not reset.Image or reset.Image.Icon == "" then
            reset:Destroy()
            reset = group:AddButton("Reset to default")
        end
        reset.IDContext, reset.SameLine = groupId .. "_Reset", true
        local explanation = group:AddText("Multiplayer: your setting here applies only to you.")
        explanation.TextWrapPos = 0
        explanation:SetColor("Text", {190 / 255, 170 / 255, 150 / 255, 1})
        local errorText = group:AddText("")
        errorText.TextWrapPos = 0
        local function refresh()
            for index, value in ipairs(MODES) do
                if value == mode then combo.SelectedIndex = index - 1 end
            end
            reset.Visible = mode ~= "On"
        end
        local function save(value)
            if not validMode(value) then refresh() return end
            local ok, saved = pcall(function()
                return Ext.IO.SaveFile(FILE, Ext.Json.Stringify({left_click_lockpick=value}))
            end)
            if not ok or saved == false then
                refresh()
                errorText.Label = "Could not save this preference. Your previous setting is still active."
                Ext.Utils.Print("best_of_hands|ERROR|client_setting_save_failed")
                return
            end
            errorText.Label = ""
            apply(value)
            refresh()
        end
        refresh()
        combo.OnChange = function(widget) save(MODES[widget.SelectedIndex + 1]) end
        reset.OnClick = function() save("On") end
    end
    local function register()
        if registered then return end
        if type(MCM) ~= "table" or type(MCM.InsertModMenuTab) ~= "function" then
            apply("On")
            return
        end
        read()
        local ok, err = pcall(MCM.InsertModMenuTab, {
            modUUID=settings.MODULE_UUID, tabName="Features", tabCallback=render, skipDisclaimer=true,
        })
        registered = ok
        if not ok then
            apply("On")
            Ext.Utils.Print("best_of_hands|ERROR|client_settings_menu_failed|" .. tostring(err))
        end
    end
    Ext.Events.SessionLoaded:Subscribe(register)
    Ext.Events.ResetCompleted:Subscribe(register)
    Ext.Events.GameStateChanged:Subscribe(register)
    Ext.OnNextTick(register)
    register()
    return instance
end

return LocalSettings
