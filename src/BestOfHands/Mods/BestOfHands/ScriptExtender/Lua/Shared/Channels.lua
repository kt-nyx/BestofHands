-- SPDX-License-Identifier: Unlicense

local Settings = Ext.Require("Server/Settings.lua")

return {
    QuickLockpick = Ext.Net.CreateChannel(
        Settings.MODULE_UUID,
        "QuickLockpick"
    ),
}
