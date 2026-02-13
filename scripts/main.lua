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
-- NETWORK EVENTS (Phase 2)
-- =============================================================================

source(modDirectory .. "scripts/events/RmSettingsSyncEvent.lua")
source(modDirectory .. "scripts/events/RmAvailabilitySyncEvent.lua")

-- =============================================================================
-- CORE
-- =============================================================================

source(modDirectory .. "scripts/RmFmAvailability.lua") -- After events (depends on RmAvailabilitySyncEvent)
source(modDirectory .. "scripts/RmFmSettings.lua")     -- After events and availability
source(modDirectory .. "scripts/RmFarmlandMarket.lua") -- Main module (orchestrator)

-- =============================================================================
-- OPTIONAL COMPONENTS - Phase 3
-- =============================================================================

-- Offer system events (Phase 3)
-- source(modDirectory .. "scripts/events/RmFarmlandOfferEvent.lua")
-- source(modDirectory .. "scripts/events/RmFarmlandOfferResponseEvent.lua")

-- =============================================================================
-- TESTING (conditional - delete tests/ folder for production)
-- =============================================================================

local testRunnerPath = modDirectory .. "scripts/tests/RmTestRunner.lua"
if fileExists(testRunnerPath) then
    source(testRunnerPath)
end
