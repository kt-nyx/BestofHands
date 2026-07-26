-- SPDX-License-Identifier: Unlicense

local Settings = Ext.Require("Server/Settings.lua")
local NativePresentationBridge = Ext.Require("Client/NativePresentationBridge.lua")

NativePresentationBridge.Start(Settings)
