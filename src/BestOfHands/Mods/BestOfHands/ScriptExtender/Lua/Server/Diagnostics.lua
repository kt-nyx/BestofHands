-- SPDX-License-Identifier: Unlicense

local Diagnostics = {}

local function stableValue(value)
    if value == nil then
        return "null"
    end
    if type(value) == "boolean" or type(value) == "number" then
        return tostring(value)
    end
    return tostring(value):gsub("[\r\n|]", " ")
end

local function stableFields(fields)
    local keys = {}
    for key, _ in pairs(fields or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)

    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = tostring(key) .. "=" .. stableValue(fields[key])
    end
    return table.concat(parts, "|")
end

function Diagnostics.Create(settings, printFunction)
    local traceEnabled = settings.TRACE_EVENTS == true
    local emit = printFunction or function(message)
        Ext.Utils.Print(message)
    end

    local instance = {}

    local function write(level, event, fields)
        local suffix = stableFields(fields)
        local line = string.format("[%s]|%s|%s", settings.LOG_PREFIX, level, event)
        if suffix ~= "" then
            line = line .. "|" .. suffix
        end
        emit(line)
    end

    function instance.Info(event, fields)
        write("INFO", event, fields)
    end

    function instance.Warn(event, fields)
        write("WARN", event, fields)
    end

    function instance.Error(event, fields)
        write("ERROR", event, fields)
    end

    function instance.Trace(event, fields)
        if traceEnabled then
            write("TRACE", event, fields)
        end
    end

    function instance.SetTrace(enabled)
        traceEnabled = enabled == true
        write("INFO", "trace_changed", { enabled = traceEnabled })
    end

    function instance.IsTraceEnabled()
        return traceEnabled
    end

    return instance
end

return Diagnostics
