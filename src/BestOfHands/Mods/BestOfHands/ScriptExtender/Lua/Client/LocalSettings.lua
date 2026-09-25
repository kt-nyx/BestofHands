-- SPDX-License-Identifier: Unlicense

local LocalSettings = {}
local FILE = "BestOfHands/ClientSettings.json"

-- MCM blueprint settings are shared by the host. A custom MCM checkbox and
-- client-only file keep this control personal, including on guest machines.
function LocalSettings.Start(settings)
    local instance = {}
    local enabled = true
    local registered = false
    local listeners = {}

    function instance.IsEnabled()
        return enabled
    end

    function instance.Subscribe(callback)
        listeners[#listeners + 1] = callback
    end

    local function apply(value)
        if enabled == value then return end
        enabled = value
        for _, callback in ipairs(listeners) do callback() end
    end

    local function read()
        local ok, value = pcall(function()
            local text = Ext.IO.LoadFile(FILE)
            if type(text) ~= "string" or text == "" then return nil end
            return Ext.Json.Parse(text).left_click_lockpick
        end)
        apply(not (ok and value == false))
    end

    local function render(tab)
        -- MCM may call this more than once for the same existing tab (for
        -- example, menu-to-save UI readiness). Own only our group: do not
        -- clear the shared page's blueprint-generated party settings.
        local groupId = "BestOfHands_PersonalLockpick"
        for _, child in ipairs(tab.Children) do
            if child.IDContext == groupId then return end
        end
        local group = tab:AddGroup(groupId)
        group.IDContext = groupId
        local checkbox = group:AddCheckbox("Left-click lockpick", enabled)
        -- Match MCM's standard reset icon and inherited button theme.
        local reset = group:AddImageButton("Reset to default", "ico_randomize_d", { 32, 32 })
        if not reset.Image or reset.Image.Icon == "" then
            reset:Destroy()
            reset = group:AddButton("Reset to default")
        end
        reset.IDContext = groupId .. "_Reset"
        reset.SameLine = true
        reset.Visible = not enabled
        local explanation = group:AddText(
            "Left-click locked doors or containers to start lockpicking. Keys still take priority. "
                .. "When disabled, use the normal context-menu Lockpick action.\n\n"
                .. "In multiplayer, this affects only your controls."
        )
        explanation.TextWrapPos = 0
        -- MCM's IMGUIWidget:SetupDescription uses this same faded white.
        -- Custom AddText otherwise inherits the window's gold title color.
        explanation:SetColor("Text", { 1, 1, 1, 0.67 })
        local errorText = group:AddText("")
        errorText.TextWrapPos = 0
        local function save(value)
            if type(value) ~= "boolean" then return end
            local ok, saved = pcall(function()
                return Ext.IO.SaveFile(FILE, Ext.Json.Stringify({
                    left_click_lockpick = value,
                }))
            end)
            if not ok or saved == false then
                checkbox.Checked = enabled
                reset.Visible = not enabled
                errorText.Label = "Could not save this preference. Your previous setting is still active."
                Ext.Utils.Print("best_of_hands|ERROR|client_setting_save_failed")
                return
            end
            errorText.Label = ""
            apply(value)
            checkbox.Checked = enabled
            reset.Visible = not enabled
        end
        checkbox.OnChange = function(widget) save(widget.Checked) end
        reset.OnClick = function() save(true) end
    end

    local function register()
        if registered then return end
        if type(MCM) ~= "table" or type(MCM.InsertModMenuTab) ~= "function" then
            -- Ignore even an existing disabled preference when MCM is absent.
            apply(true)
            return
        end
        read()
        local ok, err = pcall(MCM.InsertModMenuTab, {
            modUUID = settings.MODULE_UUID,
            -- MCM reuses the blueprint tab with this exact name.
            tabName = "Features",
            tabCallback = render,
            skipDisclaimer = true,
        })
        registered = ok
        if not ok then
            apply(true)
            Ext.Utils.Print("best_of_hands|ERROR|client_settings_menu_failed|" .. tostring(err))
        end
    end

    -- Retry after optional mods have bootstrapped. MCM owns rebuilding the tab
    -- across menu/save transitions; never register duplicate callbacks.
    Ext.Events.SessionLoaded:Subscribe(register)
    Ext.Events.ResetCompleted:Subscribe(register)
    Ext.Events.GameStateChanged:Subscribe(register)
    Ext.OnNextTick(register)
    register()
    return instance
end

return LocalSettings
