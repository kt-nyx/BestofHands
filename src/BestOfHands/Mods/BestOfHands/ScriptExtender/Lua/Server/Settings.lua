-- SPDX-License-Identifier: Unlicense

return {
    MOD_NAME = "Best of Hands",
    LOG_PREFIX = "best_of_hands",
    MODULE_UUID = "8a82593c-28a3-4ed1-8c46-3d9bacff42e1",
    VERSION = "1.0.1",

    ACTIVE_ASSISTANCE_VAR = "ActiveAssistance",
    ACTION_PERMISSION_TIMEOUT_MS = 5000,
    DELEGATION_ROLL_TIMEOUT_MS = 300000,
    QUICK_LOCKPICK_OPEN_TIMEOUT_MS = 5000,
    DELEGATED_LOCKPICK_ROLL_EVENT = "BestOfHands_DelegatedLockpick",
    DELEGATED_DISARM_ROLL_EVENT = "BestOfHands_DelegatedDisarm",
    TRACE_EVENTS = false,

    -- Closed and opened Thieves' Tools root templates used by the base game.
    THIEVES_TOOLS_TEMPLATES = {
        "08851ac0-3bfa-44f3-80c6-6ab0536f0e10",
        "e32a200c-5b63-414d-ae57-00e7b38f125b",
    },

    TRAP_DISARM_TOOL_TEMPLATES = {
        "22c74b5e-bef2-41b1-b9ed-f4acc766d4ee",
    },

    INELIGIBLE_STATUSES = {
        "DEAD",
        "DOWNED",
        "DYING",
        "INCAPACITATED",
        "KNOCKED_OUT",
    },
}
