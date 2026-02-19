--[[
    main.lua

    Main loader for FarmlandMarket mod.
    Loads all dependencies in the correct order.

    ============================================================
    IMPORTANT: This file is a LOADER ONLY.
    ============================================================
    - It loads dependencies via source() in the correct order
    - All mod logic belongs in scripts/RmFarmlandMarket.lua
    - Do NOT add module definitions (RmFarmlandMarket = {}) here
    - Do NOT add business logic or game hooks here
    ============================================================

    Author: Ritter
]]

local modDirectory = g_currentModDirectory

-- =============================================================================
-- INFRASTRUCTURE
-- =============================================================================

source(modDirectory .. "scripts/rmlib/RmLogging.lua")
local Log = RmLogging.getLogger("FarmlandMarket")
Log:setLevel(RmLogging.LOG_LEVEL.INFO) -- Set to DEBUG/TRACE for development, INFO for normal use

-- =============================================================================
-- NETWORK EVENTS
-- =============================================================================

source(modDirectory .. "scripts/events/RmSettingsSyncEvent.lua")
source(modDirectory .. "scripts/events/RmAvailabilitySyncEvent.lua")
source(modDirectory .. "scripts/events/RmNegotiationRequestEvent.lua")
source(modDirectory .. "scripts/events/RmNegotiationResultEvent.lua")

-- =============================================================================
-- CORE
-- =============================================================================

source(modDirectory .. "scripts/RmFmAvailability.lua") -- After events (depends on RmAvailabilitySyncEvent)
source(modDirectory .. "scripts/RmNegotiationEngine.lua") -- Stateless negotiation algorithm
source(modDirectory .. "scripts/RmNegotiationManager.lua") -- Session state machine (wraps engine)
source(modDirectory .. "scripts/RmNegotiationUI.lua")  -- UI controller (wraps manager for dialogs)
source(modDirectory .. "scripts/RmFmSettings.lua")     -- After events and availability
source(modDirectory .. "scripts/RmFarmlandMarket.lua") -- Main module (orchestrator)

-- =============================================================================
-- TESTING (conditional - delete tests/ folder for production)
-- =============================================================================

local testRunnerPath = modDirectory .. "scripts/tests/RmTestRunner.lua"
if fileExists(testRunnerPath) then
    source(testRunnerPath)
end
