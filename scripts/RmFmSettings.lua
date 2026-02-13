--[[
    RmFmSettings.lua
    Settings module for FarmlandMarket.

    Manages:
    - In-game settings UI (cloned from gameSettingsLayout)
    - Network sync via RmSettingsSyncEvent
    - Savegame persistence
    - Multiplayer lifecycle hooks

    Settings:
    - Availability preset (MultiTextOption): off, easy, normal, hard, harder, realistic
    - Base price multiplier (MultiTextOption): 0.5x to 2.0x presets

    Author: Ritter
]]

RmFmSettings = {}

local Log = RmLogging.getLogger("FarmlandMarket")

-- ============================================================================
-- MODULE STATE
-- ============================================================================

-- Settings state (1-indexed for MultiTextOption)
RmFmSettings.availabilityPresetState = 3   -- Default: 3 = Normal (index into PRESET_ORDER)
RmFmSettings.priceMultiplierState = 3      -- Default: 3 = 1.0x

-- Price multiplier presets
RmFmSettings.PRICE_MULTIPLIER_VALUES = {0.5, 0.75, 1.0, 1.25, 1.5, 2.0}
RmFmSettings.PRICE_MULTIPLIER_TEXTS = {"0.5x", "0.75x", "1.0x", "1.25x", "1.5x", "2.0x"}

-- UI initialization flag
RmFmSettings.uiInitialized = false

-- ============================================================================
-- PUBLIC GETTERS
-- ============================================================================

--- Get the preset name string for the current availability setting.
---@return string presetName One of "off", "easy", "normal", "hard", "harder", "realistic"
function RmFmSettings.getPresetName()
    return RmFmAvailability.PRESET_ORDER[RmFmSettings.availabilityPresetState]
end

--- Check if availability system is enabled (any preset other than "off").
---@return boolean enabled
function RmFmSettings.isAvailabilityEnabled()
    return RmFmSettings.availabilityPresetState ~= 1
end

--- Get current price multiplier value
---@return number multiplier
function RmFmSettings.getPriceMultiplier()
    return RmFmSettings.PRICE_MULTIPLIER_VALUES[RmFmSettings.priceMultiplierState]
end

-- ============================================================================
-- PUBLIC SETTERS (pure state apply - called from event run(), load, and tests)
-- ============================================================================

--- Set availability preset state (no network - use event for MP changes).
---@param state number State index (1-6, index into PRESET_ORDER)
function RmFmSettings.setAvailabilityPreset(state)
    Log:trace(">>> setAvailabilityPreset(state=%d)", state)
    RmFmSettings.availabilityPresetState = state
    Log:debug("SETTINGS: Availability preset = %s (state=%d)",
        RmFmSettings.getPresetName(), state)
    Log:trace("<<< setAvailabilityPreset()")
end

--- Set price multiplier state and recalculate all farmland prices
--- (no network - use event for MP changes)
---@param state number State index (1-6)
function RmFmSettings.setPriceMultiplier(state)
    Log:trace(">>> setPriceMultiplier(state=%d)", state)
    RmFmSettings.priceMultiplierState = state
    local multiplier = RmFmSettings.getPriceMultiplier()
    Log:debug("SETTINGS: Price multiplier = %.2fx (state=%d)", multiplier, state)

    -- Update all farmland prices
    RmFarmlandMarket.updateAllFarmlandPrices()
    Log:info("Base price multiplier changed to %.2fx, updating all farmland prices", multiplier)

    Log:trace("<<< setPriceMultiplier()")
end

-- ============================================================================
-- UI CALLBACKS
-- ============================================================================

--- Apply settings change: direct on server, event on remote client.
---@param availabilityPresetState number Availability preset state (1-6)
---@param priceMultiplierState number Price multiplier state (1-6)
local function sendSettingsChangeRequest(availabilityPresetState, priceMultiplierState)
    Log:trace(">>> sendSettingsChangeRequest(preset=%d, mult=%d)", availabilityPresetState, priceMultiplierState)
    if g_server ~= nil then
        -- Host/server: apply directly and broadcast to remote clients
        Log:debug("SETTINGS: Applying directly on server (host path)")
        RmFmSettings.setAvailabilityPreset(availabilityPresetState)
        RmFmSettings.setPriceMultiplier(priceMultiplierState)
        g_server:broadcastEvent(
            RmSettingsSyncEvent.new(availabilityPresetState, priceMultiplierState)
        )
        Log:info("Settings changed: preset=%s (%d) multiplier=%.2fx (%d)",
            RmFmSettings.getPresetName(), availabilityPresetState,
            RmFmSettings.getPriceMultiplier(), priceMultiplierState)
    elseif g_client ~= nil then
        -- Remote client: send to server for validation
        Log:debug("SETTINGS: Sending change request to server (client path)")
        g_client:getServerConnection():sendEvent(
            RmSettingsSyncEvent.new(availabilityPresetState, priceMultiplierState)
        )
    end
    Log:trace("<<< sendSettingsChangeRequest()")
end

--- Callback: Availability preset changed
---@param _ any Unused target (from raiseCallback)
---@param state number New state (1-6, index into PRESET_ORDER)
local function onAvailabilityPresetChanged(_, state)
    Log:trace(">>> onAvailabilityPresetChanged(state=%d)", state)
    sendSettingsChangeRequest(state, RmFmSettings.priceMultiplierState)
    Log:trace("<<< onAvailabilityPresetChanged()")
end

--- Callback: Price multiplier changed
---@param _ any Unused target (from raiseCallback)
---@param state number New state (1-6)
local function onPriceMultiplierChanged(_, state)
    Log:trace(">>> onPriceMultiplierChanged(state=%d)", state)
    sendSettingsChangeRequest(RmFmSettings.availabilityPresetState, state)
    Log:trace("<<< onPriceMultiplierChanged()")
end

-- ============================================================================
-- UI INITIALIZATION (follows AdjustStorageCapacity pattern)
-- ============================================================================

--- Initialize settings UI by cloning elements from game settings page.
--- Called at source time (g_inGameMenu is available).
function RmFmSettings.initGui()
    Log:trace(">>> initGui()")

    -- Guard: skip on dedicated server
    if g_dedicatedServer ~= nil then
        Log:debug("SETTINGS: Skipping GUI init on dedicated server")
        return
    end

    -- Guard: g_inGameMenu not available
    if g_inGameMenu == nil then
        Log:warning("g_inGameMenu not available, skipping GUI init")
        return
    end

    local settingsPage = g_inGameMenu.pageSettings
    if settingsPage == nil then
        Log:warning("Settings page not found, skipping GUI init")
        return
    end

    local scrollPanel = settingsPage.gameSettingsLayout
    if scrollPanel == nil then
        Log:warning("Game settings layout not found, skipping GUI init")
        return
    end

    -- Find templates by scanning elements
    local sectionHeaderTemplate = nil
    local multiTextOptionTemplate = nil

    for _, element in pairs(scrollPanel.elements) do
        if element.name == "sectionHeader" and sectionHeaderTemplate == nil then
            sectionHeaderTemplate = element
        end
        if element.typeName == "Bitmap" and element.elements[1] ~= nil then
            if element.elements[1].typeName == "MultiTextOption" and multiTextOptionTemplate == nil then
                multiTextOptionTemplate = element
            end
        end
        if sectionHeaderTemplate ~= nil and multiTextOptionTemplate ~= nil then
            break
        end
    end

    if sectionHeaderTemplate == nil or multiTextOptionTemplate == nil then
        Log:warning("Could not find UI templates in gameSettingsLayout")
        return
    end

    -- Clone section header
    local header = sectionHeaderTemplate:clone(scrollPanel)
    header:setText(g_i18n:getText("rm_fm_settings_section"))

    -- Clone availability preset (MultiTextOption)
    local availabilityContainer = multiTextOptionTemplate:clone(scrollPanel)
    availabilityContainer.id = nil  -- clear cloned ID to avoid conflicts

    local availabilityControl = availabilityContainer.elements[1]
    local availabilityLabel = availabilityContainer.elements[2]

    availabilityLabel:setText(g_i18n:getText("rm_fm_settings_availability"))
    availabilityControl.elements[1]:setText(g_i18n:getText("rm_fm_settings_availability_tooltip"))
    availabilityControl:setTexts({
        g_i18n:getText("ui_off"),
        g_i18n:getText("rm_fm_preset_easy"),
        g_i18n:getText("rm_fm_preset_normal"),
        g_i18n:getText("rm_fm_preset_hard"),
        g_i18n:getText("rm_fm_preset_harder"),
        g_i18n:getText("rm_fm_preset_realistic"),
    })
    availabilityControl:setState(RmFmSettings.availabilityPresetState)
    availabilityControl.onClickCallback = onAvailabilityPresetChanged

    -- Store reference for state updates in updateGameSettings
    settingsPage.fmAvailabilityControl = availabilityControl

    -- Clone price multiplier (MultiTextOption)
    local priceContainer = multiTextOptionTemplate:clone(scrollPanel)
    priceContainer.id = nil

    local priceControl = priceContainer.elements[1]
    local priceLabel = priceContainer.elements[2]

    priceLabel:setText(g_i18n:getText("rm_fm_settings_priceMultiplier"))
    priceControl.elements[1]:setText(g_i18n:getText("rm_fm_settings_priceMultiplier_tooltip"))
    priceControl:setTexts(RmFmSettings.PRICE_MULTIPLIER_TEXTS)
    priceControl:setState(RmFmSettings.priceMultiplierState)
    priceControl.onClickCallback = onPriceMultiplierChanged

    settingsPage.fmPriceMultiplierControl = priceControl

    scrollPanel:invalidateLayout()

    RmFmSettings.uiInitialized = true
    Log:info("Settings GUI initialized")
    Log:trace("<<< initGui()")
end

-- ============================================================================
-- LIFECYCLE HOOKS
-- ============================================================================

--- Hook: Sync settings UI state when settings frame opens
---@param settingsPage table InGameMenuSettingsFrame instance
local function updateGameSettings(settingsPage)
    Log:trace(">>> updateGameSettings()")

    if settingsPage.fmAvailabilityControl ~= nil then
        settingsPage.fmAvailabilityControl:setState(RmFmSettings.availabilityPresetState)
        Log:debug("SETTINGS: Synced availability UI to state %d (%s)",
            RmFmSettings.availabilityPresetState, RmFmSettings.getPresetName())
    end

    if settingsPage.fmPriceMultiplierControl ~= nil then
        settingsPage.fmPriceMultiplierControl:setState(RmFmSettings.priceMultiplierState)

        -- Update tooltip with map's base price (available now that map is loaded)
        if g_farmlandManager ~= nil and g_farmlandManager.pricePerHa ~= nil then
            local basePrice = g_farmlandManager.pricePerHa
            local tooltip = string.format("%s\n%s: %s/ha",
                g_i18n:getText("rm_fm_settings_priceMultiplier_tooltip"),
                g_i18n:getText("rm_fm_settings_priceMultiplier_mapBase"),
                g_i18n:formatMoney(basePrice, 0, true))
            settingsPage.fmPriceMultiplierControl.elements[1]:setText(tooltip)
        end

        Log:debug("SETTINGS: Synced price multiplier UI to state %d", RmFmSettings.priceMultiplierState)
    end

    Log:trace("<<< updateGameSettings()")
end

--- Hook: Load settings from savegame XML (server only)
---@param xmlFile table Already-opened XMLFile handle
function RmFmSettings.loadFromXMLFile(xmlFile)
    Log:trace(">>> loadFromXMLFile()")

    if g_server == nil then
        Log:trace("<<< loadFromXMLFile() [not server]")
        return
    end

    local key = "rmFarmlandMarket.settings"
    RmFmSettings.availabilityPresetState = xmlFile:getValue(key .. "#availabilityPreset", 3)
    RmFmSettings.priceMultiplierState = xmlFile:getValue(key .. "#priceMultiplier", 3)

    Log:debug("SETTINGS: Loaded preset=%s (state=%d) multiplier=%.2fx (state=%d)",
        RmFmSettings.getPresetName(),
        RmFmSettings.availabilityPresetState,
        RmFmSettings.getPriceMultiplier(),
        RmFmSettings.priceMultiplierState)
    Log:info("Settings loaded from savegame")

    Log:trace("<<< loadFromXMLFile()")
end

--- Hook: Save settings to savegame XML
---@param xmlFile table Already-opened XMLFile handle
function RmFmSettings.saveToXMLFile(xmlFile)
    Log:trace(">>> saveToXMLFile()")

    -- Server only
    if g_server == nil then
        Log:trace("  Not server, skipping")
        return
    end

    local key = "rmFarmlandMarket.settings"
    xmlFile:setValue(key .. "#availabilityPreset", RmFmSettings.availabilityPresetState)
    xmlFile:setValue(key .. "#priceMultiplier", RmFmSettings.priceMultiplierState)

    Log:debug("SETTINGS: Saved preset=%d multiplier=%d",
        RmFmSettings.availabilityPresetState, RmFmSettings.priceMultiplierState)
    Log:info("Settings saved")

    Log:trace("<<< saveToXMLFile()")
end

--- Hook: Send initial client state on join
---@param _ any Unused
---@param connection table Client connection
function RmFmSettings.sendInitialClientState(_, connection)
    Log:trace(">>> sendInitialClientState(connection=%s)", connection ~= nil and "yes" or "no")

    if g_server == nil then
        Log:trace("  Not server, skipping")
        return
    end

    Log:debug("SYNC: Sending initial settings to joining client")
    connection:sendEvent(
        RmSettingsSyncEvent.new(RmFmSettings.availabilityPresetState, RmFmSettings.priceMultiplierState)
    )

    Log:trace("<<< sendInitialClientState()")
end

--- Register lifecycle hooks
function RmFmSettings.setupHooks()
    Log:trace(">>> setupHooks()")

    -- Hook: Settings UI sync when frame opens
    InGameMenuSettingsFrame.updateGameSettings = Utils.appendedFunction(
        InGameMenuSettingsFrame.updateGameSettings,
        updateGameSettings
    )

    -- Hook: Send initial state to joining clients
    FSBaseMission.sendInitialClientState = Utils.appendedFunction(
        FSBaseMission.sendInitialClientState,
        RmFmSettings.sendInitialClientState
    )

    Log:trace("<<< setupHooks()")
end

-- ============================================================================
-- MODULE INITIALIZATION (runs at source time)
-- ============================================================================

RmFmSettings.initGui()
RmFmSettings.setupHooks()

Log:debug("RmFmSettings module loaded")
