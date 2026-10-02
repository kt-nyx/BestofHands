-- SPDX-License-Identifier: Unlicense

local Settings = Ext.Require("Server/Settings.lua")
local NativePresentationBridge = Ext.Require("Client/NativePresentationBridge.lua")
local Channels = Ext.Require("Shared/Channels.lua")
local LocalSettings = Ext.Require("Client/LocalSettings.lua")
local NativeSession = Ext.Require("Client/NativeSession.lua")
local Manifests = Ext.Require("Server/NativeBridge.lua")

local features = LocalSettings.Start(Settings)
local session = NativeSession.Start(Settings, Manifests)
NativePresentationBridge.Start(Settings, Channels.QuickLockpick, features,
    session, Channels.NativeActions)
