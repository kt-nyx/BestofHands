-- SPDX-License-Identifier: Unlicense

local Settings = Ext.Require("Server/Settings.lua")
local NativePresentationBridge = Ext.Require("Client/NativePresentationBridge.lua")
local Channels = Ext.Require("Shared/Channels.lua")

NativePresentationBridge.Start(Settings, Channels.QuickLockpick)
