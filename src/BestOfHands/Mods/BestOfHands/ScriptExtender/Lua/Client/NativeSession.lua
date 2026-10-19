-- SPDX-License-Identifier: Unlicense

-- Each computer acknowledges its own DLL session. Host action records arrive
-- over the network separately; host memory handles are never used by guests.
local NativeSession = {}
local STATUS_FILE = "BestOfHandsNative.status"
local HANDSHAKE_FILE = "BestOfHandsNative.handshake"

function NativeSession.Start(settings, manifests)
    local instance, callbacks = {}, {}
    local generation, probe, session, running = 0, "", "", false
    local ready, lastState = false, ""
    local function notify()
        for _, callback in ipairs(callbacks) do callback() end
    end
    local function poll(currentGeneration)
        if generation ~= currentGeneration or not running then return end
        local status, readReason = manifests.ReadStatus(settings.VERSION)
        local valid = readReason == nil and status.protocol == "9" and status.version == settings.VERSION
            and status["end"] == "1" and type(status.session) == "string"
            and status.session ~= ""
        local previousSession, previousReady = session, ready
        ready = false
        local state = readReason or "waiting_for_native"
        if valid then
            session = status.session
            local payload = table.concat({"protocol=9", "pak_version=" .. settings.VERSION,
                "probe=" .. probe, "native_session=" .. session, "trace=0", "end=1", ""}, "\n")
            -- Repeat until acknowledged. A failed read/write or late worker
            -- initialization must never permanently strand the local client.
            local saved, result = pcall(Ext.IO.SaveFile, HANDSHAKE_FILE, payload)
            ready = saved and result ~= false and status.client_ack == probe
                and status.features == manifests.REQUIRED_FEATURES
            if not saved or result == false then
                state = "native_handshake_write_failed"
            elseif status.features ~= manifests.REQUIRED_FEATURES then
                state = "native_manifest_mismatch"
            elseif status.client_ack ~= probe then
                state = "waiting_for_client_ack"
            else
                state = "ready"
            end
        else
            session = ""
        end
        if state ~= lastState then
            lastState = state
            Ext.Utils.Print("[best_of_hands]|INFO|client_native_session|state="
                .. tostring(state) .. "|version=" .. settings.VERSION
                .. "|observed_version=" .. tostring(status.version or "unknown")
                .. "|observed_protocol=" .. tostring(status.protocol or "unknown")
                .. "|file=" .. STATUS_FILE)
        end
        if previousSession ~= session or previousReady ~= ready then notify() end
        Ext.Timer.WaitFor(ready and 2000 or 250, function() poll(currentGeneration) end)
    end
    local function start()
        generation = generation + 1
        probe = tostring(Ext.Utils.MonotonicTime()) .. "-client-" .. generation
            .. "-" .. tostring({}):gsub("[^%x]", "")
        running, ready, session = true, false, ""
        notify()
        poll(generation)
    end
    function instance.GetSession() return ready and session or "" end
    function instance.Subscribe(callback) callbacks[#callbacks + 1] = callback end
    Ext.Events.SessionLoaded:Subscribe(start)
    Ext.Events.ResetCompleted:Subscribe(start)
    return instance
end

return NativeSession
