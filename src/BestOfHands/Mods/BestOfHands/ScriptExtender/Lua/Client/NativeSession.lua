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
    local pollPending, refreshing = false, false
    local function notify()
        for _, callback in ipairs(callbacks) do callback() end
    end
    local function poll(currentGeneration)
        if generation ~= currentGeneration or not running then return end
        if refreshing then return end
        refreshing = true
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
            -- Repeat only until acknowledged. Once ready, lifecycle events
            -- and actual actions recheck status; exploration does no file I/O.
            local saved, result = true, true
            if status.client_ack ~= probe then
                saved, result = pcall(Ext.IO.SaveFile, HANDSHAKE_FILE, payload)
            end
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
        refreshing = false
        if not ready and not pollPending then
            pollPending = true
            Ext.Timer.WaitFor(250, function()
                if generation ~= currentGeneration then return end
                pollPending = false
                poll(currentGeneration)
            end)
        end
    end
    local function start()
        generation = generation + 1
        probe = tostring(Ext.Utils.MonotonicTime()) .. "-client-" .. generation
            .. "-" .. tostring({}):gsub("[^%x]", "")
        running, ready, session, pollPending = true, false, "", false
        notify()
        poll(generation)
    end
    function instance.GetSession()
        -- Called at action/session boundaries, never by a gameplay timer.
        if ready then poll(generation) end
        return ready and session or ""
    end
    function instance.Subscribe(callback) callbacks[#callbacks + 1] = callback end
    Ext.Events.SessionLoaded:Subscribe(start)
    Ext.Events.ResetCompleted:Subscribe(start)
    return instance
end

return NativeSession
