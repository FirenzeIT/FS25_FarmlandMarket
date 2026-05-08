-- RmWatchlistDialog - Modal dialog for the Watchlist feature.
-- Author: Ritter
--
-- MessageDialog subclass with a SmoothList of eligible (unowned) farmlands.
-- Each row shows the farmland's display name, area in hectares (plus an
-- expiry-day suffix when listed), and either the formatted listing price or
-- "Not for sale" on the right. Curation, persistence, and add/remove arrive
-- in a follow-up spec.

local Log = RmLogging.getLogger("FarmlandMarket")

---@class RmWatchlistDialog : MessageDialog
---@field entries table[] Sorted entry records returned by buildEntries().
---@field watchlistList table SmoothList element (XML id="watchlistList").
---@field listSlider table Scrollbar slider element (XML id="listSlider").
---@field emptyListText table Empty-state text element (XML id="emptyListText").
---@field dialogTitleElement table Title text element (XML id="dialogTitleElement").
RmWatchlistDialog = {}
local RmWatchlistDialog_mt = Class(RmWatchlistDialog, MessageDialog)

RmWatchlistDialog.CONTROLS = {
    "watchlistList",
    "listSlider",
    "emptyListText",
    "dialogTitleElement",
    "watchlistBackButton",
}

-- ============================================================================
-- CONSTRUCTOR
-- ============================================================================

--- Creates a new RmWatchlistDialog instance.
---@param target table|nil
---@param customMt table|nil
---@return RmWatchlistDialog
function RmWatchlistDialog.new(target, customMt)
    Log:trace(">>> RmWatchlistDialog.new()")
    ---@type RmWatchlistDialog
    ---@diagnostic disable-next-line: assign-type-mismatch
    local self = MessageDialog.new(target, customMt or RmWatchlistDialog_mt)
    -- Instance-scope so the first getNumberOfItemsInSection call (triggered by
    -- setDataSource in onGuiSetupFinished) returns 0 instead of nil-indexing.
    self.entries = {}
    return self
end

-- ============================================================================
-- STATIC METHODS
-- ============================================================================

--- Registers the dialog with the GUI system.
function RmWatchlistDialog.register()
    Log:trace(">>> RmWatchlistDialog.register()")
    local modDir = RmFarmlandMarket.modDirectory
    local dialog = RmWatchlistDialog.new(g_i18n)
    g_gui:loadGui(modDir .. "gui/RmWatchlistDialog.xml", "RmWatchlistDialog", dialog)
    if g_gui.guis ~= nil and g_gui.guis["RmWatchlistDialog"] ~= nil then
        Log:info("RmWatchlistDialog registered")
    else
        Log:error("Failed to register RmWatchlistDialog (g_gui.guis lookup empty)")
    end
    Log:trace("<<< RmWatchlistDialog.register()")
end

--- Opens the watchlist dialog via the GUI system.
function RmWatchlistDialog.show()
    Log:trace(">>> RmWatchlistDialog.show()")
    if g_gui == nil then
        Log:trace("RmWatchlistDialog.show: g_gui is nil, abort")
        return
    end
    if g_gui.guis == nil or g_gui.guis["RmWatchlistDialog"] == nil then
        Log:trace("RmWatchlistDialog.show: dialog not registered, abort")
        return
    end
    g_gui:showDialog("RmWatchlistDialog")
    Log:trace("<<< RmWatchlistDialog.show()")
end

--- Returns the dialog instance from the GUI system.
---@return RmWatchlistDialog|nil
function RmWatchlistDialog.getInstance()
    local entry = g_gui.guis["RmWatchlistDialog"]
    return entry and entry.target or nil
end

--- Build a sorted list of watchlist entries from raw farmland data.
--- Pure: no g_i18n, no g_currentMission, no g_farmlandManager, no logging side
--- effects beyond the loggers passed in via the module-level Log handle.
---
--- The price for listed rows is read from `availabilityEntry.listingPrice`
--- (the synced authoritative listing price written by
--- RmNegotiationManager.ensureListedProfiles), NOT from farmland.price. That
--- keeps the watchlist consistent with the map context box and the buy flow.
---@param farmlands table map of farmlandId -> Farmland (e.g. g_farmlandManager:getFarmlands())
---@param eligibilityFn function predicate(farmland) -> boolean filtering pool members
---@param availabilityTable table map of farmlandId -> { isForSale, expiryDay, listingDay, listingPrice } or nil
---@return table[] sorted array of { farmlandId, name, areaInHa, isForSale, price, expiryDay, sortKey }
function RmWatchlistDialog.buildEntries(farmlands, eligibilityFn, availabilityTable)
    -- Count input rows up-front so the entry trace carries the same shape as
    -- the rest of the dialog's per-call traces. pairs is used because
    -- farmlands is keyed by farmland id, so the # operator is unreliable.
    local inputCount = 0
    if farmlands ~= nil then
        for _ in pairs(farmlands) do inputCount = inputCount + 1 end
    end
    Log:trace(">>> RmWatchlistDialog.buildEntries(input=%d)", inputCount)

    local entries = {}
    local skipped = 0
    local nilIdSkipped = 0
    local nilAreaCount = 0
    if farmlands == nil then
        Log:debug("buildEntries: 0 eligible, 0 skipped (nil farmlands input)")
        return entries
    end
    for _, farmland in pairs(farmlands) do
        local farmlandId = farmland.id
        if farmlandId == nil then
            -- Custom maps have produced surprising nil scalars before. Skip
            -- the row instead of crashing the whole dialog on string.format.
            nilIdSkipped = nilIdSkipped + 1
        elseif not eligibilityFn(farmland) then
            skipped = skipped + 1
        else
            local availabilityEntry = availabilityTable ~= nil and availabilityTable[farmlandId] or nil
            local isForSale = false
            local price = nil
            local expiryDay = nil
            if availabilityEntry ~= nil and availabilityEntry.isForSale == true then
                isForSale = true
                -- Listed price source is the synced availability entry's
                -- listingPrice, not farmland.price. The negotiation manager
                -- writes this on every listed field so server, client, and
                -- buy flow agree on a single number.
                price = availabilityEntry.listingPrice
                expiryDay = availabilityEntry.expiryDay
            end
            local rawName = farmland.name
            local sortKey = (rawName ~= nil and rawName ~= "")
                and rawName
                or string.format("%d", farmlandId)
            local areaInHa = farmland.areaInHa
            if areaInHa == nil then
                nilAreaCount = nilAreaCount + 1
                areaInHa = 0
            end
            local entry = {
                farmlandId = farmlandId,
                name = rawName,
                areaInHa = areaInHa,
                isForSale = isForSale,
                price = price,
                expiryDay = expiryDay,
                sortKey = sortKey,
            }
            table.insert(entries, entry)
        end
    end
    -- Tiebreaker on equal sortKey: lower farmlandId wins. Lua's table.sort is
    -- not stable, so two rows with the same display name would otherwise
    -- swap positions across reloads.
    table.sort(entries, function(a, b)
        if a.sortKey == b.sortKey then
            return a.farmlandId < b.farmlandId
        end
        return a.sortKey < b.sortKey
    end)
    if nilAreaCount > 0 then
        Log:debug("buildEntries: %d farmlands had nil areaInHa, defaulted to 0", nilAreaCount)
    end
    if nilIdSkipped > 0 then
        Log:debug("buildEntries: skipped %d farmlands with nil id", nilIdSkipped)
    end
    Log:debug("buildEntries: %d eligible, %d skipped", #entries, skipped)
    return entries
end

-- ============================================================================
-- INSTANCE METHODS - Lifecycle
-- ============================================================================

--- Wire the SmoothList to this dialog as its data source. Runs once after
--- the GUI element tree is loaded.
function RmWatchlistDialog:onGuiSetupFinished()
    Log:trace(">>> RmWatchlistDialog:onGuiSetupFinished()")
    RmWatchlistDialog:superClass().onGuiSetupFinished(self)
    -- Nil-guard the data-source wire-up: if a future XML edit drops the
    -- watchlistList id, register() still reports success (it only checks
    -- the registry slot), and we'd crash here without a useful message.
    if self.watchlistList ~= nil then
        self.watchlistList:setDataSource(self)
    else
        Log:error("RmWatchlistDialog:onGuiSetupFinished: self.watchlistList is nil (XML id missing or CONTROLS misaligned)")
    end
    Log:trace("<<< RmWatchlistDialog:onGuiSetupFinished()")
end

--- Refresh entries, toggle empty-state visibility, and place focus.
function RmWatchlistDialog:onOpen()
    Log:trace(">>> RmWatchlistDialog:onOpen()")
    RmWatchlistDialog:superClass().onOpen(self)

    self:refreshEntries()
    self:updateEmptyState()
    self.watchlistList:reloadData()

    self:setSoundSuppressed(true)
    if #self.entries > 0 then
        FocusManager:setFocus(self.watchlistList)
    elseif self.watchlistBackButton ~= nil then
        -- Focus the Back button directly when the list is hidden so keyboard
        -- and controller users do not get stranded on an invisible element.
        FocusManager:setFocus(self.watchlistBackButton)
    else
        Log:warning("RmWatchlistDialog:onOpen: empty list AND watchlistBackButton not resolved; default focus may strand keyboard nav")
    end
    self:setSoundSuppressed(false)

    Log:debug("RmWatchlistDialog:onOpen: %d entries", #self.entries)
end

--- Clear cached entries and delegate to the base dialog close path.
function RmWatchlistDialog:onClose()
    Log:trace(">>> RmWatchlistDialog:onClose()")
    self.entries = {}
    RmWatchlistDialog:superClass().onClose(self)
end

--- Override to log the close path before delegating to MessageDialog.
--- Wired from RmWatchlistDialog.xml: <Button onClick="onClickBack" .../>
function RmWatchlistDialog:onClickBack()
    Log:trace(">>> RmWatchlistDialog:onClickBack()")
    RmWatchlistDialog:superClass().onClickBack(self)
    Log:trace("<<< RmWatchlistDialog:onClickBack()")
end

-- ============================================================================
-- INSTANCE METHODS - Data
-- ============================================================================

--- Pull live game state and rebuild the entries array.
--- The injected predicate composes the existing eligibility check with the
--- player's curated watchlist membership, so only watched + still-eligible
--- farmlands render. Stale watched ids (e.g. a farmland the player just
--- bought) are pruned in place before the build, so they never linger.
function RmWatchlistDialog:refreshEntries()
    Log:trace(">>> RmWatchlistDialog:refreshEntries()")
    if g_farmlandManager == nil or RmFmAvailability == nil then
        Log:error("RmWatchlistDialog:refreshEntries: required globals missing (g_farmlandManager=%s, RmFmAvailability=%s)",
            tostring(g_farmlandManager), tostring(RmFmAvailability))
        self.entries = {}
        return
    end
    local farmlands = g_farmlandManager:getFarmlands()
    if RmWatchlistUI ~= nil and RmWatchlistUI.pruneStale ~= nil then
        RmWatchlistUI.pruneStale(farmlands)
    end
    local function watchedAndEligible(farmland)
        return RmFmAvailability.isEligibleForAvailability(farmland)
            and RmWatchlistUI.isWatched(farmland.id)
    end
    self.entries = RmWatchlistDialog.buildEntries(
        farmlands,
        watchedAndEligible,
        RmFmAvailability.availability
    )
    Log:debug("RmWatchlistDialog:refreshEntries: %d entries", #self.entries)
end

--- Show the empty-state text and hide the list when there are no entries.
function RmWatchlistDialog:updateEmptyState()
    local isEmpty = #self.entries == 0
    self.emptyListText:setVisible(isEmpty)
    self.watchlistList:setVisible(not isEmpty)
end

-- ============================================================================
-- INSTANCE METHODS - SmoothList data-source contract
-- ============================================================================

--- Number of rows the SmoothList should render in the given section.
---@param list table the SmoothList element making the query
---@param section number 1-based section index
---@return number
function RmWatchlistDialog:getNumberOfItemsInSection(list, section)
    -- The watchlist is single-section by design; guard against a future
    -- engine layout that probes section >= 2 to avoid phantom rows.
    if list == self.watchlistList and section == 1 then
        return #self.entries
    end
    return 0
end

--- Render one row's three text cells from the entry record at index.
---@param list table the SmoothList element making the call
---@param section number 1-based section index
---@param index number 1-based row index within the section
---@param cell table the prepared row element from the XML template
function RmWatchlistDialog:populateCellForItemInSection(list, section, index, cell)
    if list ~= self.watchlistList or section ~= 1 then
        return
    end
    local entry = self.entries[index]
    if entry == nil then
        return
    end

    local nameElement = cell:getAttribute("farmlandName")
    local subtextElement = cell:getAttribute("farmlandSubtext")
    local priceElement = cell:getAttribute("priceText")
    if nameElement == nil or subtextElement == nil or priceElement == nil then
        -- An XML rename or typo on the row template's name="..." attributes
        -- would surface here on first reloadData. Bail without crashing the
        -- engine row loop. No log per spec ("NO logging in this function").
        return
    end

    -- Primary text: farmland name, with caller-side fallback for unnamed parcels.
    local displayName = entry.name
    if displayName == nil or displayName == "" then
        displayName = g_i18n:getText("rm_fm_farmland_label") .. " " .. tostring(entry.farmlandId)
    end
    nameElement:setText(displayName)

    -- Secondary text: area, plus expiry suffix when listed.
    if entry.isForSale and entry.expiryDay ~= nil then
        subtextElement:setText(string.format("%.1f ha . expires day %d",
            entry.areaInHa, entry.expiryDay))
    else
        subtextElement:setText(string.format("%.1f ha", entry.areaInHa))
    end

    -- Right column: price (listed) or "Not for sale" (anything else).
    local isCB = RmFarmlandMarket.isColorBlindMode
    if entry.isForSale and entry.price ~= nil then
        priceElement:setText(g_i18n:formatMoney(entry.price))
        priceElement:setTextColor(unpack(RmFarmlandMarket.COLOR_WATCHLIST_LISTED_PRICE[isCB]))
    else
        priceElement:setText(g_i18n:getText("rm_fm_notForSale"))
        priceElement:setTextColor(unpack(RmFarmlandMarket.COLOR_WATCHLIST_NOT_FOR_SALE[isCB]))
    end
end

-- ============================================================================
-- INSTANCE METHODS - List events (stubs, identical for this iteration)
-- ============================================================================

--- Single-click handler. Stub: bounds-check + TRACE log only; visible
--- behaviour lands in a future curation spec.
---@param list table the SmoothList element
---@param section number 1-based section index
---@param index number 1-based row index
function RmWatchlistDialog:onListClick(list, section, index)
    if section ~= 1 or index == nil or index < 1 or index > #self.entries then
        Log:trace("RmWatchlistDialog:onListClick: out of range (section=%s index=%s entries=%d)",
            tostring(section), tostring(index), #self.entries)
        return
    end
    local entry = self.entries[index]
    Log:trace("RmWatchlistDialog:onListClick: section=%s index=%d farmlandId=%d",
        tostring(section), index, entry.farmlandId)
end

--- Double-click handler. Intentionally identical to single-click for this
--- iteration; the visible-behaviour split arrives in a future curation spec.
---@param list table the SmoothList element
---@param section number 1-based section index
---@param index number 1-based row index
function RmWatchlistDialog:onListDoubleClick(list, section, index)
    if section ~= 1 or index == nil or index < 1 or index > #self.entries then
        Log:trace("RmWatchlistDialog:onListDoubleClick: out of range (section=%s index=%s entries=%d)",
            tostring(section), tostring(index), #self.entries)
        return
    end
    local entry = self.entries[index]
    Log:trace("RmWatchlistDialog:onListDoubleClick: section=%s index=%d farmlandId=%d",
        tostring(section), index, entry.farmlandId)
end
