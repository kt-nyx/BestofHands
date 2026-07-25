-- SPDX-License-Identifier: Unlicense

local Settings = Ext.Require("Server/Settings.lua")
local NativePresentationBridge = Ext.Require("Client/NativePresentationBridge.lua")
local UiRollDiagnostics = Ext.Require("Client/UiRollDiagnostics.lua")

local presentationBridge = NativePresentationBridge.Start(Settings)
UiRollDiagnostics.Start(Settings, presentationBridge)
