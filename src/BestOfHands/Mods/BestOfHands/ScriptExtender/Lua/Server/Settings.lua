-- SPDX-License-Identifier: Unlicense

return {
    MOD_NAME = "Best of Hands",
    LOG_PREFIX = "best_of_hands",
    MODULE_UUID = "8a82593c-28a3-4ed1-8c46-3d9bacff42e1",
    VERSION = "2.1.1",

    ACTIVE_ASSISTANCE_VAR = "ActiveAssistance",
    NATIVE_ACTION_TIMEOUT_MS = 300000,
    NATIVE_REFERENCE_TRACE_TIMEOUT_MS = 30000,
    NATIVE_HANDSHAKE_ATTEMPTS = 40,
    NATIVE_HANDSHAKE_POLL_MS = 250,
    QUICK_LOCKPICK_TIMEOUT_MS = 5000,
    QUICK_LOCKPICK_NATIVE_SUPPRESSION_MS = 2000,
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
    OPTIONAL_ACTION_TOOL_PROVIDERS = {
        lockpick = {
            {
                id = "eternal_lockpick",
                moduleUuid = "d105067d-1937-b314-78c0-3030e1d887c8",
                templates = {
                    "b9cb9a9a-13e4-42a8-a64a-4c2c2aacc77f",
                },
            },
        },
        disarm = {
            {
                id = "eternal_trap_disarm_kit",
                moduleUuid = "b7f62d2e-1e48-9f5c-7afb-3ea2367c9f66",
                templates = {
                    "d7ed475d-d353-449f-8798-df9b3a96f0e5",
                },
            },
        },
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
