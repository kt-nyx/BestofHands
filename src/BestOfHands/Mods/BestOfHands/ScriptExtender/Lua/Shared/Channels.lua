-- SPDX-License-Identifier: Unlicense

local Settings = Ext.Require("Server/Settings.lua")

return {
    NativeActions = Ext.Net.CreateChannel(Settings.MODULE_UUID, "NativeActions"),
    QuickLockpick = Ext.Net.CreateChannel(
        Settings.MODULE_UUID,
        "QuickLockpick"
    ),
}
