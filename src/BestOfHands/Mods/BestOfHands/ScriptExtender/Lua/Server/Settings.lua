-- SPDX-License-Identifier: Unlicense

return {
    MOD_NAME = "Best of Hands",
    LOG_PREFIX = "best_of_hands",
    MODULE_UUID = "8a82593c-28a3-4ed1-8c46-3d9bacff42e1",
    VERSION = "2.0.0",

    ACTIVE_ASSISTANCE_VAR = "ActiveAssistance",
    NATIVE_ACTION_TIMEOUT_MS = 300000,
    NATIVE_REFERENCE_TRACE_TIMEOUT_MS = 30000,
    NATIVE_HANDSHAKE_ATTEMPTS = 40,
    NATIVE_HANDSHAKE_POLL_MS = 250,
    QUICK_LOCKPICK_TIMEOUT_MS = 5000,
    TRACE_EVENTS = false,

    -- Base-game tool roots. These are used only as a conservative delegation
    -- precondition; BG3 remains responsible for choosing and consuming tools.
    -- Optional tool providers can extend this boundary when their integration
    -- is implemented.
    VANILLA_THIEVES_TOOLS_TEMPLATES = {
        "08851ac0-3bfa-44f3-80c6-6ab0536f0e10",
        "e32a200c-5b63-414d-ae57-00e7b38f125b",
    },
    VANILLA_TRAP_DISARM_TOOL_TEMPLATES = {
        "22c74b5e-bef2-41b1-b9ed-f4acc766d4ee",
    },
    MISSING_TOOL_ERROR_KEY = "CannotUse",

    INELIGIBLE_STATUSES = {
        "DEAD",
        "DOWNED",
        "DYING",
        "INCAPACITATED",
        "KNOCKED_OUT",
    },
}
