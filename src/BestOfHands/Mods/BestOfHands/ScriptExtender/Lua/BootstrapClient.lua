-- SPDX-License-Identifier: Unlicense

local Settings = Ext.Require("Server/Settings.lua")
local NativePresentationBridge = Ext.Require("Client/NativePresentationBridge.lua")
local Channels = Ext.Require("Shared/Channels.lua")
local LocalSettings = Ext.Require("Client/LocalSettings.lua")

local features = LocalSettings.Start(Settings)
NativePresentationBridge.Start(Settings, Channels.QuickLockpick, features)
