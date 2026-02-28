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
RmFmSettings.negotiationEnabledState = 2   -- Default: 2 = On (BinaryOption: 1=Off, 2=On)

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

--- Check if negotiation system is enabled.
---@return boolean enabled
function RmFmSettings.isNegotiationEnabled()
    return RmFmSettings.negotiationEnabledState == 2
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

--- Set negotiation enabled state (no network - use event for MP changes).
---@param state number State index (BinaryOption: 1=Off, 2=On)
function RmFmSettings.setNegotiationEnabled(state)
    Log:trace(">>> setNegotiationEnabled(state=%d)", state)
    RmFmSettings.negotiationEnabledState = state
    Log:debug("SETTINGS: Negotiation = %s (state=%d)",
        RmFmSettings.isNegotiationEnabled() and "enabled" or "disabled", state)
    Log:trace("<<< setNegotiationEnabled()")
end

-- ============================================================================
-- UI CALLBACKS
-- ============================================================================

--- Apply settings change: direct on server, event on remote client.
---@param availabilityPresetState number Availability preset state (1-6)
---@param priceMultiplierState number Price multiplier state (1-6)
---@param negotiationEnabledState number Negotiation enabled state (BinaryOption: 1=Off, 2=On)
local function sendSettingsChangeRequest(availabilityPresetState, priceMultiplierState, negotiationEnabledState)
    Log:trace(">>> sendSettingsChangeRequest(preset=%d, mult=%d, neg=%d)",
        availabilityPresetState, priceMultiplierState, negotiationEnabledState)
    if g_server ~= nil then
        -- Host/server: apply directly and broadcast to remote clients
        RmFmSettings.setAvailabilityPreset(availabilityPresetState)
        RmFmSettings.setPriceMultiplier(priceMultiplierState)
        RmFmSettings.setNegotiationEnabled(negotiationEnabledState)
        g_server:broadcastEvent(
            RmSettingsSyncEvent.new(availabilityPresetState, priceMultiplierState, negotiationEnabledState)
        )
        Log:info("Settings changed: preset=%s (%d) multiplier=%.2fx (%d) negotiation=%s",
            RmFmSettings.getPresetName(), availabilityPresetState,
            RmFmSettings.getPriceMultiplier(), priceMultiplierState,
            RmFmSettings.isNegotiationEnabled() and "on" or "off")
    elseif g_client ~= nil then
        -- Remote client: send to server for validation
        g_client:getServerConnection():sendEvent(
            RmSettingsSyncEvent.new(availabilityPresetState, priceMultiplierState, negotiationEnabledState)
        )
    end
    Log:trace("<<< sendSettingsChangeRequest()")
end

--- Callback: Availability preset changed
---@param _ any Unused target (from raiseCallback)
---@param state number New state (1-6, index into PRESET_ORDER)
local function onAvailabilityPresetChanged(_, state)
    Log:trace(">>> onAvailabilityPresetChanged(state=%d)", state)
    sendSettingsChangeRequest(state, RmFmSettings.priceMultiplierState,
        RmFmSettings.negotiationEnabledState)
    Log:trace("<<< onAvailabilityPresetChanged()")
end

--- Callback: Price multiplier changed
---@param _ any Unused target (from raiseCallback)
---@param state number New state (1-6)
local function onPriceMultiplierChanged(_, state)
    Log:trace(">>> onPriceMultiplierChanged(state=%d)", state)
    sendSettingsChangeRequest(RmFmSettings.availabilityPresetState, state,
        RmFmSettings.negotiationEnabledState)
    Log:trace("<<< onPriceMultiplierChanged()")
end

--- Callback: Negotiation enabled changed
---@param _ any Unused target (from raiseCallback)
---@param state number New state (BinaryOption: 1=Off, 2=On)
local function onNegotiationEnabledChanged(_, state)
    Log:trace(">>> onNegotiationEnabledChanged(state=%d)", state)
    sendSettingsChangeRequest(RmFmSettings.availabilityPresetState, RmFmSettings.priceMultiplierState,
        state)
    Log:trace("<<< onNegotiationEnabledChanged()")
end

-- ============================================================================
-- UI HELPERS
-- ============================================================================

-- Cloned containers for FocusManager registration
local fmClonedControls = {}

--- Recursively assign unique focusIds to a cloned element and all its children.
--- Cloned elements inherit duplicate focusIds from their templates, which breaks
--- FocusManager navigation. Pattern from ForestryHelper UIHelper / PlayerMovement.
---@param element table GUI element
local function updateFocusIds(element)
    if not element then return end
    element.focusId = FocusManager:serveAutoFocusId()
    for _, child in pairs(element.elements) do
        updateFocusIds(child)
    end
end

-- ============================================================================
-- UI INITIALIZATION
-- ============================================================================

--- Initialize settings UI by cloning elements from game settings page.
--- Called at source time (g_inGameMenu is available).
function RmFmSettings.initGui()
    Log:trace(">>> initGui()")

    -- Guard: skip on dedicated server
    if g_dedicatedServer ~= nil then
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
    local binaryOptionTemplate = nil

    for _, element in pairs(scrollPanel.elements) do
        if element.name == "sectionHeader" and sectionHeaderTemplate == nil then
            sectionHeaderTemplate = element
        end
        if element.typeName == "Bitmap" and element.elements[1] ~= nil then
            if element.elements[1].typeName == "MultiTextOption" and multiTextOptionTemplate == nil then
                multiTextOptionTemplate = element
            end
            if element.elements[1].typeName == "BinaryOption" and binaryOptionTemplate == nil then
                binaryOptionTemplate = element
            end
        end
        if sectionHeaderTemplate ~= nil and multiTextOptionTemplate ~= nil and binaryOptionTemplate ~= nil then
            break
        end
    end

    if sectionHeaderTemplate == nil or multiTextOptionTemplate == nil then
        Log:warning("Could not find UI templates in gameSettingsLayout")
        return
    end

    -- Clone section header
    local header = sectionHeaderTemplate:clone(scrollPanel)
    updateFocusIds(header)
    header:setText(g_i18n:getText("rm_fm_settings_section"))

    -- Clone availability preset (MultiTextOption)
    local availabilityContainer = multiTextOptionTemplate:clone(scrollPanel)
    updateFocusIds(availabilityContainer)
    availabilityContainer.id = nil  -- clear cloned ID to avoid conflicts

    local availabilityControl = availabilityContainer.elements[1]
    local availabilityLabel = availabilityContainer.elements[2]

    availabilityLabel:setText(g_i18n:getText("rm_fm_settings_availability"))
    availabilityLabel.id = nil
    availabilityControl.elements[1]:setText(g_i18n:getText("rm_fm_settings_availability_tooltip"))
    availabilityControl.id = "fmAvailabilityPreset"
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

    availabilityContainer:setVisible(true)
    availabilityContainer:setDisabled(false)

    -- Store reference for state updates in updateGameSettings
    settingsPage.fmAvailabilityControl = availabilityControl

    -- Clone negotiation enabled toggle (BinaryOption: 1=Off, 2=On)
    local negTemplate = binaryOptionTemplate or multiTextOptionTemplate
    local negContainer = negTemplate:clone(scrollPanel)
    updateFocusIds(negContainer)
    negContainer.id = nil

    local negControl = negContainer.elements[1]
    local negLabel = negContainer.elements[2]

    negLabel:setText(g_i18n:getText("rm_fm_settings_negotiation"))
    negLabel.id = nil
    negControl.elements[1]:setText(g_i18n:getText("rm_fm_settings_negotiation_tooltip"))
    negControl.id = "fmNegotiationEnabled"
    if binaryOptionTemplate == nil then
        -- Fallback: MultiTextOption if no BinaryOption template found
        negControl:setTexts({ g_i18n:getText("ui_off"), g_i18n:getText("ui_on") })
    end
    -- NOTE: Do NOT call setState here for BinaryOption. The slider positions itself
    -- based on element dimensions which are zero at source time. updateGameSettings
    -- will set the correct state when the frame opens with real dimensions.
    negControl.onClickCallback = onNegotiationEnabledChanged

    negContainer:setVisible(true)
    negContainer:setDisabled(false)

    settingsPage.fmNegotiationControl = negControl

    -- Clone price multiplier (MultiTextOption)
    local priceContainer = multiTextOptionTemplate:clone(scrollPanel)
    updateFocusIds(priceContainer)
    priceContainer.id = nil

    local priceControl = priceContainer.elements[1]
    local priceLabel = priceContainer.elements[2]

    priceLabel:setText(g_i18n:getText("rm_fm_settings_priceMultiplier"))
    priceLabel.id = nil
    priceControl.elements[1]:setText(g_i18n:getText("rm_fm_settings_priceMultiplier_tooltip"))
    priceControl.id = "fmPriceMultiplier"
    priceControl:setTexts(RmFmSettings.PRICE_MULTIPLIER_TEXTS)
    priceControl:setState(RmFmSettings.priceMultiplierState)
    priceControl.onClickCallback = onPriceMultiplierChanged

    priceContainer:setVisible(true)
    priceContainer:setDisabled(false)

    settingsPage.fmPriceMultiplierControl = priceControl

    -- Track cloned containers for FocusManager registration
    fmClonedControls = { header, availabilityContainer, negContainer, priceContainer }

    scrollPanel:invalidateLayout()

    RmFmSettings.uiInitialized = true
    Log:info("Settings GUI initialized (4 elements cloned, focusIds updated)")
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

    end

    if settingsPage.fmNegotiationControl ~= nil then
        settingsPage.fmNegotiationControl:setState(RmFmSettings.negotiationEnabledState)
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
    RmFmSettings.negotiationEnabledState = xmlFile:getValue(key .. "#negotiationEnabled", 1)

    Log:debug("Settings loaded: preset=%s multiplier=%.2fx negotiation=%s",
        RmFmSettings.getPresetName(), RmFmSettings.getPriceMultiplier(),
        RmFmSettings.isNegotiationEnabled() and "on" or "off")

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
    xmlFile:setValue(key .. "#negotiationEnabled", RmFmSettings.negotiationEnabledState)

    Log:debug("Settings saved to savegame")

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

    connection:sendEvent(
        RmSettingsSyncEvent.new(RmFmSettings.availabilityPresetState, RmFmSettings.priceMultiplierState,
            RmFmSettings.negotiationEnabledState)
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

    -- Hook: Register cloned elements with FocusManager when GUI is set up.
    -- Without this, cloned elements are not in the FocusManager's element mapping
    -- and keyboard navigation skips them. Pattern from ForestryHelper / PlayerMovement.
    FocusManager.setGui = Utils.appendedFunction(FocusManager.setGui, function(_, gui)
        if gui == nil or #fmClonedControls == 0 then return end

        local registered = 0
        for _, control in ipairs(fmClonedControls) do
            if not control.focusId
                or not FocusManager.currentFocusData.idToElementMapping[control.focusId] then
                if FocusManager:loadElementFromCustomValues(control, nil, nil, false, false) then
                    registered = registered + 1
                else
                    Log:warning("FOCUS: Failed to register %s with FocusManager",
                        control.id or control.typeName or "?")
                end
            end
        end

        if registered > 0 then
            Log:trace("FOCUS: Registered %d controls with FocusManager", registered)
            local settingsPage = g_inGameMenu.pageSettings
            if settingsPage ~= nil and settingsPage.gameSettingsLayout ~= nil then
                settingsPage.gameSettingsLayout:invalidateLayout()
            end
        end
    end)

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
