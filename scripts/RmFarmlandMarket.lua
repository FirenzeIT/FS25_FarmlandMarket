--[[
    RmFarmlandMarket.lua
    Main module for FarmlandMarket mod.
    Contains all mod logic, state, and game integration hooks.
]]

-- Module declaration
RmFarmlandMarket = {}
RmFarmlandMarket.modDirectory = g_currentModDirectory
RmFarmlandMarket.modName = g_currentModName

-- Module constants
RmFarmlandMarket.DEFAULT_PRICE_PER_HA = nil -- nil = use game default
RmFarmlandMarket.COLOR_FOR_SALE = {0.10, 0.22, 0.01, 1}      -- Match available-selected overlay
RmFarmlandMarket.COLOR_NOT_FOR_SALE = {0.4, 0.05, 0.05, 1}   -- Match unavailable-selected overlay
RmFarmlandMarket.OVERLAY_COLOR_UNAVAILABLE_SELECTED = {0.4, 0.05, 0.05}  -- Red highlight for selected unavailable
RmFarmlandMarket.OVERLAY_COLOR_UNAVAILABLE = {0.25, 0.04, 0.04}  -- Light red tint for non-selected unavailable
RmFarmlandMarket.OVERLAY_COLOR_AVAILABLE_SELECTED = {0.10, 0.22, 0.01}  -- Green highlight for selected available
RmFarmlandMarket.OVERLAY_COLOR_AVAILABLE = {0.06, 0.13, 0.005}  -- Light green tint for non-selected available

-- Cached pricing details per farmland id (populated during updatePrice)
RmFarmlandMarket.priceData = {}

-- XML schema for savegame persistence (lazy-registered)
RmFarmlandMarket.xmlSchema = nil

-- Configure logging (per-mod instance with multiplayer context)
local Log = RmLogging.getLogger("FarmlandMarket")

-- ============================================================================
-- CORE FUNCTIONALITY: Crop Value Calculation
-- ============================================================================

--- Get peak seasonal price for a fill type across all 12 periods.
--- Falls back to current pricePerLiter if economy data unavailable.
---@param fillType table FillTypeDesc
---@return number peakPrice Peak price per liter
local function getPeakPrice(fillType)
    Log:trace(">>> getPeakPrice(fillType=%s)", fillType.name or "?")
    local economyManager = g_currentMission.economyManager
    if economyManager == nil then
        Log:trace("<<< getPeakPrice = %.4f (no economyManager, using base)", fillType.pricePerLiter)
        return fillType.pricePerLiter
    end

    local maxFactor = 0
    local bestPeriod = 0
    for period = 1, 12 do
        local factor = EconomyManager.getFillTypeSeasonalFactor(nil, fillType, period, 0)
        if factor ~= nil and factor > maxFactor then
            maxFactor = factor
            bestPeriod = period
        end
    end

    if maxFactor > 0 then
        local peakPrice = fillType.pricePerLiter * maxFactor
        Log:debug("PEAK_PRICE: %s base=%.4f factor=%.2f (period %d) peak=%.4f",
            fillType.name or "?", fillType.pricePerLiter, maxFactor, bestPeriod, peakPrice)
        Log:trace("<<< getPeakPrice = %.4f", peakPrice)
        return peakPrice
    end

    Log:trace("<<< getPeakPrice = %.4f (no seasonal data, using base)", fillType.pricePerLiter)
    return fillType.pricePerLiter
end

--- Calculates estimated crop value for a farmland based on current field state.
--- Uses peak seasonal price to reflect what a farmer would get selling at optimal time.
---@param farmland table The farmland object
---@return table details { cropValue, fruitName, growthRatio, ... }
local function calculateCropValue(farmland)
    Log:trace(">>> calculateCropValue(farmlandId=%d)", farmland.id)
    local details = { cropValue = 0 }

    local field = farmland:getField()
    if field == nil then
        Log:trace("<<< calculateCropValue = 0 (no field for farmland)")
        return details
    end
    details.hasField = true

    local fieldState = field:getFieldState()
    if fieldState == nil or not fieldState.isValid then
        Log:trace("<<< calculateCropValue = 0 (no valid fieldState)")
        return details
    end

    if fieldState.fruitTypeIndex == nil or fieldState.fruitTypeIndex == FruitType.UNKNOWN then
        Log:trace("<<< calculateCropValue = 0 (no fruit planted)")
        return details
    end

    local fruitDesc = g_fruitTypeManager:getFruitTypeByIndex(fieldState.fruitTypeIndex)
    if fruitDesc == nil then
        Log:trace("<<< calculateCropValue = 0 (unknown fruitTypeIndex=%d)", fieldState.fruitTypeIndex)
        return details
    end

    local fillType = g_fruitTypeManager:getFillTypeByFruitTypeIndex(fieldState.fruitTypeIndex)
    if fillType == nil then
        Log:trace("<<< calculateCropValue = 0 (no fillType for fruit=%s)", fruitDesc.name)
        return details
    end

    -- Growth progress ratio (0.0 to 1.0)
    local growthRatio = fieldState.growthState / fruitDesc.maxHarvestingGrowthState
    growthRatio = math.min(growthRatio, 1.0)

    -- Estimated harvest value using peak seasonal price
    local areaHa = field:getAreaHa()
    local areaSqm = areaHa * 10000
    local harvestMultiplier = fieldState:getHarvestScaleMultiplier()
    local harvestLiters = areaSqm * fruitDesc.literPerSqm * harvestMultiplier
    local peakPrice = getPeakPrice(fillType)
    local cropValue = harvestLiters * peakPrice * growthRatio

    details.cropValue = cropValue
    details.fruitName = fruitDesc.name
    details.growthState = fieldState.growthState
    details.maxGrowthState = fruitDesc.maxHarvestingGrowthState
    details.growthRatio = growthRatio
    details.areaHa = areaHa
    details.literPerSqm = fruitDesc.literPerSqm
    details.harvestMultiplier = harvestMultiplier
    details.harvestLiters = harvestLiters
    details.basePricePerLiter = fillType.pricePerLiter
    details.peakPrice = peakPrice

    Log:debug("CROP_VALUE: farmland=%d fruit=%s growth=%.0f%% area=%.1fha liters=%.0f peakPrice=%.2f value=%.0f",
        farmland.id, fruitDesc.name, growthRatio * 100, areaHa,
        harvestLiters, peakPrice, cropValue)
    Log:trace("<<< calculateCropValue = %.0f", cropValue)

    return details
end

-- ============================================================================
-- PRICE OVERRIDES
-- ============================================================================

--- Override Farmland.updatePrice to add crop value on top of base price
Farmland.updatePrice = Utils.overwrittenFunction(Farmland.updatePrice, function(self, superFunc)
    superFunc(self)
    local basePrice = self.price
    Log:trace(">>> updatePrice override (farmlandId=%d, basePrice=%.0f)", self.id, basePrice)
    local details = calculateCropValue(self)
    if details.cropValue > 0 then
        self.price = self.price + details.cropValue
        Log:trace("    price adjusted: %.0f + %.0f = %.0f", basePrice, details.cropValue, self.price)
    end
    RmFarmlandMarket.priceData[self.id] = {
        basePrice = basePrice,
        cropValue = details.cropValue,
        finalPrice = self.price,
        crop = details,
    }
    Log:trace("<<< updatePrice override (finalPrice=%.0f)", self.price)
end)

-- Override base price per hectare with multiplier (Phase 2)
FarmlandManager.getPricePerHa = Utils.overwrittenFunction(
    FarmlandManager.getPricePerHa,
    function(self, superFunc)
        local basePrice = superFunc(self)
        local multiplier = RmFmSettings.getPriceMultiplier()
        local result = basePrice * multiplier
        Log:trace(">>> getPricePerHa: base=%.0f multiplier=%.2f result=%.0f",
            basePrice, multiplier, result)
        return result
    end
)

-- ============================================================================
-- BUY FLOW VALIDATION HOOKS
-- ============================================================================

--- Override FarmlandStateEvent:run() to reject purchases of unavailable farmlands
FarmlandStateEvent.run = Utils.overwrittenFunction(FarmlandStateEvent.run, function(self, superFunc, connection)
    Log:trace(">>> FarmlandStateEvent:run(farmlandId=%d)", self.id)

    -- Check availability (server receiving from client)
    if connection:getIsServer() and RmFmSettings.isAvailabilityEnabled() then
        if not RmFmAvailability.isForSale(self.id) then
            Log:warning("Purchase rejected: farmland %d not available for sale", self.id)
            Log:trace("<<< FarmlandStateEvent:run() [rejected]")
            return
        end
        Log:debug("AVAIL: Buy check for farmland %d: available=true", self.id)
    end

    superFunc(self, connection)
    Log:trace("<<< FarmlandStateEvent:run() [allowed]")
end)

--- Override InGameMenuMapFrame:setMapInputContext() to suppress buy button for unavailable farmlands.
--- Intercepts canBuy before the game builds the context bar, preserving all other buttons.
InGameMenuMapFrame.setMapInputContext = Utils.overwrittenFunction(
    InGameMenuMapFrame.setMapInputContext,
    function(self, superFunc, canEnter, canReset, canSellVehicle, canVisit, canSetMarker, removeMarker, canBuy, canSell, canManage)
        -- Check if current hotspot is an unavailable farmland
        if canBuy and RmFmSettings.isAvailabilityEnabled() then
            local hotspot = self.currentHotspot
            if hotspot ~= nil and hotspot.getFarmland ~= nil then
                local farmland = hotspot:getFarmland()
                if farmland ~= nil and not RmFmAvailability.isForSale(farmland.id) then
                    canBuy = false
                    Log:debug("AVAIL: Suppressed buy button for unavailable farmland %d", farmland.id)
                end
            end
        end

        superFunc(self, canEnter, canReset, canSellVehicle, canVisit, canSetMarker, removeMarker, canBuy, canSell, canManage)
    end
)

-- ============================================================================
-- CONTEXT BOX DISPLAY
-- ============================================================================

--- Replace farmland value with "Not for sale" for unavailable farmlands.
--- Runs after base showContextBox (and PF override if active).
InGameMenuMapUtil.showContextBox = Utils.appendedFunction(
    InGameMenuMapUtil.showContextBox,
    function(contextBox, hotspot, description, imageFilename, uvs, farmId, playerName, isPlaceable, isVehicle, isFarmland)
        if not isFarmland or contextBox == nil then
            return
        end
        if not RmFmSettings.isAvailabilityEnabled() then
            return
        end
        if hotspot == nil or hotspot.getFarmland == nil then
            return
        end
        local farmland = hotspot:getFarmland()
        if farmland == nil then
            return
        end
        if RmFmAvailability.isEligibleForAvailability(farmland)
           and not RmFmAvailability.isForSale(farmland.id) then
            contextBox:getDescendantByName("farmlandValue"):setText(
                g_i18n:getText("rm_fm_notForSale"))
            Log:debug("CONTEXT: Replaced value with 'Not for sale' for farmland %d", farmland.id)
        end
    end
)

-- ============================================================================
-- FARMLAND LEGEND
-- ============================================================================

--- Customize farmland legend at cell render time for guaranteed consistency.
--- Entry 1 "Unowned" -> "For sale", Entry 2 "Currently Selected" -> "Not for sale" (red).
InGameMenuMapFrame.populateCellForItemInSection = Utils.appendedFunction(
    InGameMenuMapFrame.populateCellForItemInSection,
    function(self, list, section, index, cell)
        if list ~= self.filterList then
            return
        end
        if self.mapOverviewSelector:getState() ~= InGameMenuMapFrame.MAP_FARMLANDS then
            return
        end
        if not RmFmSettings.isAvailabilityEnabled() then
            return
        end

        if index == 1 then
            -- "Unowned" -> "For sale" (green)
            cell:getAttribute("name"):setText(g_i18n:getText("rm_fm_forSale"))
            self:assignItemColors(cell:getAttribute("iconBg"),
                { RmFarmlandMarket.COLOR_FOR_SALE })
        elseif index == 2 then
            -- "Currently Selected" -> "Not for sale" (red)
            cell:getAttribute("name"):setText(g_i18n:getText("rm_fm_notForSale"))
            self:assignItemColors(cell:getAttribute("iconBg"),
                { RmFarmlandMarket.COLOR_NOT_FOR_SALE })
        end
    end
)

-- ============================================================================
-- HOTSPOT COLOR MANAGEMENT
-- ============================================================================

--- Override FarmlandHotspot:updateColors() to apply red tint to unavailable fields
FarmlandHotspot.updateColors = Utils.appendedFunction(FarmlandHotspot.updateColors, function(self)
    -- Guard: check log level before trace (performance optimization)
    if Log.level <= RmLogging.LOG_LEVEL.TRACE then
        Log:trace(">>> FarmlandHotspot:updateColors()")
    end

    -- Guard: skip if no farmland
    local farmland = self:getFarmland()
    if farmland == nil then
        return
    end

    -- Guard: skip if availability disabled
    if not RmFmSettings.isAvailabilityEnabled() then
        return
    end

    -- Guard: skip if player-owned (not in availability pool)
    if not RmFmAvailability.isEligibleForAvailability(farmland) then
        return
    end

    -- Apply red tint if not for sale
    if not RmFmAvailability.isForSale(farmland.id) then
        local color = RmFarmlandMarket.COLOR_NOT_FOR_SALE
        self:setColor(color[1], color[2], color[3])
        self.colorDisabled[1] = color[1]
        self.colorDisabled[2] = color[2]
        self.colorDisabled[3] = color[3]
        self.colorDisabled[4] = color[4]
    end

    if Log.level <= RmLogging.LOG_LEVEL.TRACE then
        Log:trace("<<< FarmlandHotspot:updateColors()")
    end
end)

-- ============================================================================
-- MAP OVERLAY COLOR MANAGEMENT (menu map farmland area overlay)
-- ============================================================================

--- Apply availability tint to farmland area overlays after standard colors are set.
--- Red for unavailable, green for available (for sale).
--- Called as appendedFunction on both build methods.
--- Engine API: setDensityMapVisualizationOverlayStateColor(overlay, map, 0, 0, 0, numChannels, key, r, g, b)
---   where key is the farmlands table key (from pairs()), not farmland.id
---@param self table MapOverlayGenerator instance
---@param selectedFarmland table|nil Currently selected Farmland object
local function applyAvailabilityOverlayColors(self, selectedFarmland)
    if not RmFmSettings.isAvailabilityEnabled() then
        return
    end

    local overlay = self.farmlandStateOverlay
    if overlay == nil then
        return
    end

    local map = self.farmlandManager:getLocalMap()
    if map == nil then
        return
    end

    local numChannels = getBitVectorMapNumChannels(map)
    local selectedId = selectedFarmland ~= nil and selectedFarmland.id or nil

    for k, farmland in pairs(self.farmlandManager:getFarmlands()) do
        if RmFmAvailability.isEligibleForAvailability(farmland) then
            local isSelected = farmland.id == selectedId
            local color
            if RmFmAvailability.isForSale(farmland.id) then
                color = isSelected
                    and RmFarmlandMarket.OVERLAY_COLOR_AVAILABLE_SELECTED
                    or RmFarmlandMarket.OVERLAY_COLOR_AVAILABLE
            else
                color = isSelected
                    and RmFarmlandMarket.OVERLAY_COLOR_UNAVAILABLE_SELECTED
                    or RmFarmlandMarket.OVERLAY_COLOR_UNAVAILABLE
            end
            setDensityMapVisualizationOverlayStateColor(
                overlay, map, 0, 0, 0, numChannels, k,
                color[1], color[2], color[3])
        end
    end
end

--- Override MapOverlayGenerator:buildFarmlandsMapOverlay() to tint farmlands by availability
MapOverlayGenerator.buildFarmlandsMapOverlay = Utils.appendedFunction(
    MapOverlayGenerator.buildFarmlandsMapOverlay,
    applyAvailabilityOverlayColors
)

--- Override MapOverlayGenerator:buildSingleFarmlandsMapOverlay() to tint selected farmland by availability
MapOverlayGenerator.buildSingleFarmlandsMapOverlay = Utils.appendedFunction(
    MapOverlayGenerator.buildSingleFarmlandsMapOverlay,
    applyAvailabilityOverlayColors
)

--- Update all farmland hotspot colors (called after availability changes)
function RmFarmlandMarket.updateAllHotspotColors()
    Log:trace(">>> updateAllHotspotColors()")
    local count = 0
    for _, hotspot in pairs(g_currentMission.mapHotspots) do
        if hotspot.getFarmland ~= nil then
            hotspot:updateColors()
            count = count + 1
        end
    end
    Log:debug("Updated %d farmland hotspot colors", count)

    -- Also refresh the farmland area overlay if the map frame is open
    if g_inGameMenu ~= nil and g_inGameMenu.pageMapOverview ~= nil then
        g_inGameMenu.pageMapOverview.needsOverlayUpdate = true
        Log:debug("OVERLAY: Flagged map frame for overlay refresh")
    end

    Log:trace("<<< updateAllHotspotColors()")
end

-- ============================================================================
-- DAY CHANGE HANDLER
-- ============================================================================

--- Day change callback (subscribed via MessageCenter)
function RmFarmlandMarket.onDayChanged()
    Log:trace(">>> onDayChanged()")

    -- Server only
    if g_server == nil then
        Log:trace("<<< onDayChanged() [not server]")
        return
    end

    RmFmAvailability.evaluateDaily()
    Log:trace("<<< onDayChanged()")
end

-- ============================================================================
-- CONSOLE COMMANDS
-- ============================================================================

--- Get owner name for a farmland (player farm or NPC)
---@param farmland table
---@return string ownerName
local function getOwnerName(farmland)
    -- Player-owned farmland
    if farmland.farmId ~= nil and farmland.farmId ~= FarmlandManager.NO_OWNER_FARM_ID then
        local farm = g_farmManager:getFarmById(farmland.farmId)
        if farm ~= nil then
            return farm.name
        end
        return string.format("Farm %d", farmland.farmId)
    end
    -- NPC-owned farmland
    if farmland.npcIndex ~= nil and farmland.npcIndex > 0 then
        local npc = g_npcManager:getNPCByIndex(farmland.npcIndex)
        if npc ~= nil then
            return npc.title
        end
        return string.format("NPC %d", farmland.npcIndex)
    end
    return "(unowned)"
end

--- Get crop status string for a farmland
---@param data table|nil Cached price data
---@return string status
local function getCropStatus(data)
    if data == nil then
        return ""
    end
    local crop = data.crop
    if crop.cropValue > 0 then
        return string.format("%s (%.0f%%)", crop.fruitName, crop.growthRatio * 100)
    elseif crop.hasField then
        return "(empty)"
    else
        return "(no field)"
    end
end

--- Console command: List all farmlands with prices
function RmFarmlandMarket:consoleFmList()
    local farmlands = {}
    for _, farmland in pairs(g_farmlandManager:getFarmlands()) do
        table.insert(farmlands, farmland)
    end
    table.sort(farmlands, function(a, b) return a.id < b.id end)

    print("Farmland Market - Price Overview")
    print(string.format("  %3s  %-14s  %7s  %8s  %7s  %8s  %5s  %s",
        "ID", "Owner", "Area", "Base", "Crop", "Final", "Avail", "Field"))
    print("  ---  --------------  -------  --------  -------  --------  -----  ---------------")

    for _, farmland in ipairs(farmlands) do
        local owner = getOwnerName(farmland)
        local data = RmFarmlandMarket.priceData[farmland.id]
        local basePrice = data and data.basePrice or farmland.price
        local cropValue = data and data.cropValue or 0
        local finalPrice = data and data.finalPrice or farmland.price
        local status = getCropStatus(data)

        -- Availability indicator
        local availStr = "-"
        if RmFmAvailability.isEligibleForAvailability(farmland) then
            availStr = RmFmAvailability.isForSale(farmland.id) and "Y" or "N"
        end

        print(string.format("  %3d  %-14s  %5.1fha  %8.0f  %7.0f  %8.0f  %5s  %s",
            farmland.id, owner, farmland.areaInHa, basePrice, cropValue, finalPrice, availStr, status))
    end

    return string.format("Listed %d farmlands", #farmlands)
end

--- Console command: Show availability status for all farmlands
function RmFarmlandMarket:consoleFmAvail()
    Log:trace(">>> consoleFmAvail()")

    if not RmFmSettings.isAvailabilityEnabled() then
        print("Availability system is DISABLED")
        return "Availability disabled"
    end

    local farmlands = {}
    for _, farmland in pairs(g_farmlandManager:getFarmlands()) do
        if RmFmAvailability.isEligibleForAvailability(farmland) then
            table.insert(farmlands, farmland)
        end
    end
    table.sort(farmlands, function(a, b) return a.id < b.id end)

    print("Farmland Market - Availability Status")
    print(string.format("  %3s  %8s  %10s  %10s  %s",
        "ID", "For Sale", "Listed Day", "Expiry Day", "Status"))
    print("  ---  --------  ----------  ----------  -----------")

    local forSaleCount = 0
    for _, farmland in ipairs(farmlands) do
        local entry = RmFmAvailability.availability[farmland.id]
        if entry ~= nil then
            local forSaleStr = entry.isForSale and "Y" or "N"
            local listingDayStr = entry.listingDay > 0 and tostring(entry.listingDay) or "-"
            local expiryDayStr = entry.expiryDay > 0 and tostring(entry.expiryDay) or "-"
            local statusStr = ""
            if entry.isForSale then
                forSaleCount = forSaleCount + 1
                local daysLeft = entry.expiryDay - g_currentMission.environment.currentDay
                statusStr = string.format("%d days left", daysLeft)
            else
                statusStr = "Not listed"
            end

            print(string.format("  %3d  %8s  %10s  %10s  %s",
                farmland.id, forSaleStr, listingDayStr, expiryDayStr, statusStr))

            Log:debug("AVAIL: farmland %d: forSale=%s listingDay=%d expiryDay=%d",
                farmland.id, forSaleStr, entry.listingDay, entry.expiryDay)
        else
            print(string.format("  %3d  (no entry in availability table)", farmland.id))
        end
    end

    print("")
    print(string.format("Total: %d eligible farmlands, %d for sale", #farmlands, forSaleCount))

    Log:trace("<<< consoleFmAvail()")
    return string.format("%d eligible, %d for sale", #farmlands, forSaleCount)
end

--- Console command: Inspect a farmland's price breakdown
function RmFarmlandMarket:consoleFmInspect(farmlandIdStr)
    if farmlandIdStr == nil then
        return "Usage: fmInspect <farmlandId>"
    end

    local farmlandId = tonumber(farmlandIdStr)
    if farmlandId == nil then
        return "Invalid farmland ID: " .. farmlandIdStr
    end

    local farmland = g_farmlandManager:getFarmlands()[farmlandId]
    if farmland == nil then
        return string.format("Farmland %d not found", farmlandId)
    end

    local owner = getOwnerName(farmland)
    print(string.format("Farmland Market - Farmland %d", farmlandId))
    print(string.format("  Owner:         %s", owner))
    print(string.format("  Area:          %.2f ha", farmland.areaInHa))

    local data = RmFarmlandMarket.priceData[farmlandId]
    if data == nil then
        if farmland.fixedPrice ~= nil then
            print(string.format("  Fixed Price:   %.0f", farmland.price))
        else
            print(string.format("  Price:         %.0f (no cached data)", farmland.price))
        end
        return string.format("Farmland %d: price = %.0f", farmlandId, farmland.price)
    end

    -- Base price breakdown
    local pricePerHa = g_farmlandManager:getPricePerHa()
    local priceFactor = farmland.priceFactor or 0
    print(string.format("  Price Factor:  %.2f", priceFactor))
    print("")
    print(string.format("  Base Price:    %.0f", data.basePrice))
    print(string.format("    = %.0f $/ha x %.2f ha x %.2f factor",
        pricePerHa, farmland.areaInHa, priceFactor))

    -- Crop value breakdown
    print("")
    local crop = data.crop
    if crop.cropValue > 0 then
        print(string.format("  Crop Value:    %.0f", crop.cropValue))
        print(string.format("    Fruit:       %s", crop.fruitName))
        print(string.format("    Growth:      %.0f%% (%d/%d)",
            crop.growthRatio * 100, crop.growthState, crop.maxGrowthState))
        print(string.format("    Harvest:     %.0f L (%.2f ha x %.2f L/sqm x %.2fx)",
            crop.harvestLiters, crop.areaHa, crop.literPerSqm, crop.harvestMultiplier))
        print(string.format("    Peak Price:  %.4f $/L (base: %.4f)",
            crop.peakPrice, crop.basePricePerLiter))
        print(string.format("    = %.0f L x %.4f $/L x %.0f%%",
            crop.harvestLiters, crop.peakPrice, crop.growthRatio * 100))
    elseif crop.hasField then
        print("  Crop Value:    0 (no crop planted)")
    else
        print("  Crop Value:    0 (no field)")
    end

    -- Final price
    print("")
    print(string.format("  Final Price:   %.0f", data.finalPrice))
    if crop.cropValue > 0 then
        print(string.format("    = %.0f base + %.0f crop", data.basePrice, crop.cropValue))
    end

    return string.format("Farmland %d: %.0f (base) + %.0f (crop) = %.0f",
        farmlandId, data.basePrice, data.cropValue, data.finalPrice)
end

-- ============================================================================
-- SAVEGAME PERSISTENCE
-- ============================================================================

--- Register XML schema for savegame files (idempotent)
function RmFarmlandMarket.registerXmlSchema()
    if RmFarmlandMarket.xmlSchema ~= nil then
        return
    end

    local schema = XMLSchema.new("rmFarmlandMarket")

    -- Settings
    schema:register(XMLValueType.INT, "rmFarmlandMarket.settings#availabilityPreset", "Availability preset state")
    schema:register(XMLValueType.INT, "rmFarmlandMarket.settings#priceMultiplier", "Price multiplier state")

    -- Availability entries
    local entryPath = "rmFarmlandMarket.availability.farmland(?)"
    schema:register(XMLValueType.INT, entryPath .. "#id", "Farmland ID")
    schema:register(XMLValueType.BOOL, entryPath .. "#isForSale", "For sale flag")
    schema:register(XMLValueType.INT, entryPath .. "#expiryDay", "Expiry day")
    schema:register(XMLValueType.INT, entryPath .. "#listingDay", "Listing day")

    RmFarmlandMarket.xmlSchema = schema
    Log:debug("XML schema registered")
end

--- Load mod data from savegame XML (server only)
local function loadFromSavegame()
    Log:trace(">>> loadFromSavegame()")

    if g_server == nil then
        Log:trace("<<< loadFromSavegame() [not server]")
        return
    end

    local savegameDir = g_currentMission.missionInfo.savegameDirectory
    if savegameDir == nil then
        Log:warning("Savegame directory not available, skipping load")
        return
    end

    local filePath = savegameDir .. "/rm_FarmlandMarket.xml"
    RmFarmlandMarket.registerXmlSchema()
    local xmlFile = XMLFile.loadIfExists("fmSavegame", filePath, RmFarmlandMarket.xmlSchema)

    if xmlFile == nil then
        Log:debug("No savegame file found (new save), using defaults")
        return
    end

    Log:info("Loading savegame from rm_FarmlandMarket.xml")

    -- Delegate to modules
    RmFmSettings.loadFromXMLFile(xmlFile)
    RmFmAvailability.loadFromXMLFile(xmlFile)

    xmlFile:delete()
    Log:info("Savegame loaded from rm_FarmlandMarket.xml")
    Log:trace("<<< loadFromSavegame()")
end

--- Save mod data to savegame XML
local function saveToSavegame()
    Log:trace(">>> saveToSavegame()")

    -- Server only
    if g_server == nil then
        Log:trace("  Not server, skipping")
        return
    end

    local savegameDir = g_currentMission.missionInfo.savegameDirectory
    if savegameDir == nil then
        Log:warning("Savegame directory not available, skipping save")
        return
    end

    local filePath = savegameDir .. "/rm_FarmlandMarket.xml"
    RmFarmlandMarket.registerXmlSchema()
    local xmlFile = XMLFile.create("fmSavegame", filePath, "rmFarmlandMarket", RmFarmlandMarket.xmlSchema)

    if xmlFile == nil then
        Log:error("Failed to create savegame XML file: %s", filePath)
        return
    end

    Log:info("Saving to rm_FarmlandMarket.xml")

    -- Delegate to modules
    RmFmSettings.saveToXMLFile(xmlFile)
    RmFmAvailability.saveToXMLFile(xmlFile)

    xmlFile:save()
    xmlFile:delete()

    Log:info("Savegame saved to rm_FarmlandMarket.xml")
    Log:trace("<<< saveToSavegame()")
end

-- ============================================================================
-- LIFECYCLE HOOKS
-- ============================================================================

local function onLoadMapFinished()
    Log:info("Map loaded, initializing FarmlandMarket")

    -- Register console commands
    RmLogging.registerConsoleCommands()
    addConsoleCommand("fmList", "List all farmlands with prices", "consoleFmList", RmFarmlandMarket)
    addConsoleCommand("fmInspect", "Inspect farmland price details", "consoleFmInspect", RmFarmlandMarket, "farmlandId")
    addConsoleCommand("fmAvail", "Show availability status", "consoleFmAvail", RmFarmlandMarket)

    -- Subscribe to day change events
    g_messageCenter:subscribe(MessageType.DAY_CHANGED, RmFarmlandMarket.onDayChanged, RmFarmlandMarket)
    Log:debug("Subscribed to DAY_CHANGED message")

    Log:info("FarmlandMarket hooks registered")
end

--- Apply crop-value pricing to all farmlands.
--- Called from onStartMission when farmlands and fields are fully loaded.
--- Also called when price multiplier setting changes.
function RmFarmlandMarket.updateAllFarmlandPrices()
    Log:trace(">>> updateAllFarmlandPrices()")
    local totalFarmlands = 0
    local farmlandsWithCrops = 0
    for _, farmland in pairs(g_farmlandManager:getFarmlands()) do
        totalFarmlands = totalFarmlands + 1
        if farmland.fixedPrice ~= nil then
            Log:trace("  Skipping farmland %d (fixedPrice=%.0f)", farmland.id, farmland.fixedPrice)
        else
            local priceBefore = farmland.price
            farmland:updatePrice()
            if farmland.price > priceBefore then
                farmlandsWithCrops = farmlandsWithCrops + 1
            end
        end
    end

    Log:info("Updated prices for %d farmlands (%d with crop value)", totalFarmlands, farmlandsWithCrops)
    Log:trace("<<< updateAllFarmlandPrices()")
end

local function onStartMission()
    RmFarmlandMarket.updateAllFarmlandPrices()
    RmFmAvailability.initialize()
    Log:info("FarmlandMarket initialization complete")
end

local function onDeleteMap()
    Log:debug("Cleaning up FarmlandMarket")

    -- Unsubscribe from day change events
    g_messageCenter:unsubscribe(MessageType.DAY_CHANGED, RmFarmlandMarket)

    -- Clean up availability state
    RmFmAvailability.reset()

    -- Remove console commands
    removeConsoleCommand("fmList")
    removeConsoleCommand("fmInspect")
    removeConsoleCommand("fmAvail")
    RmLogging.unregisterConsoleCommands()

    -- Clear cached data
    RmFarmlandMarket.priceData = {}
end

-- Hook into map loading completion (early init: console commands, settings)
BaseMission.loadMapFinished = Utils.appendedFunction(
    BaseMission.loadMapFinished,
    onLoadMapFinished
)

-- Hook into mission start (farmlands and fields fully loaded)
FSBaseMission.onStartMission = Utils.appendedFunction(
    FSBaseMission.onStartMission,
    onStartMission
)

-- Hook into map cleanup
BaseMission.delete = Utils.appendedFunction(
    BaseMission.delete,
    onDeleteMap
)

-- Hook into savegame load
Mission00.loadItemsFinished = Utils.appendedFunction(
    Mission00.loadItemsFinished,
    loadFromSavegame
)

-- Hook into savegame save
FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(
    FSCareerMissionInfo.saveToXMLFile,
    saveToSavegame
)

-- Hook into initial client state sync (send availability to joining clients)
FSBaseMission.sendInitialClientState = Utils.appendedFunction(
    FSBaseMission.sendInitialClientState,
    function(_, connection)
        if g_server ~= nil then
            RmFmAvailability.sendInitialClientState(connection)
        end
    end
)

Log:info("FarmlandMarket mod loaded (v%s)",
    g_modManager:getModByName(RmFarmlandMarket.modName).version)
