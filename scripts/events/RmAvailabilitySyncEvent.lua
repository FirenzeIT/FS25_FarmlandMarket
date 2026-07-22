--[[
    RmAvailabilitySyncEvent.lua
    Network event for synchronizing farmland availability state.

    Server-authoritative only: server broadcasts to clients, client-sent events are rejected.

    Syncs the full availability table:
    - farmlandId (Int32)
    - isForSale (Bool)
    - expiryDay (Int32)
    - listingDay (Int32)

    Flow:
    - Server initialization/daily evaluation -> broadcasts to all clients
    - Client joins -> server sends initial state
    - Clients receive -> replace local availability table + refresh map colors

    Author: Ritter
]]

local Log = RmLogging.getLogger("FarmlandMarket")

-- Event class declaration
RmAvailabilitySyncEvent = {}
local Mt = Class(RmAvailabilitySyncEvent, Event)
InitEventClass(RmAvailabilitySyncEvent, "RmAvailabilitySyncEvent")

--- Create empty event instance (required by event system)
---@return table event
function RmAvailabilitySyncEvent.emptyNew()
    Log:trace(">>> RmAvailabilitySyncEvent.emptyNew()")
    local self = Event.new(Mt)
    Log:trace("<<< RmAvailabilitySyncEvent.emptyNew()")
    return self
end

--- Create new event with availability data from module
---@return table event
function RmAvailabilitySyncEvent.new()
    Log:trace(">>> RmAvailabilitySyncEvent.new()")
    local self = Event.new(Mt)
    -- Capture current availability state from module
    self.availability = RmFmAvailability.availability or {}
    Log:trace("<<< RmAvailabilitySyncEvent.new(%d entries)", self:countEntries())
    return self
end

--- Count availability entries
---@return number count
function RmAvailabilitySyncEvent:countEntries()
    local count = 0
    for _ in pairs(self.availability) do
        count = count + 1
    end
    return count
end

--- Count for-sale entries
---@return number count
function RmAvailabilitySyncEvent:countForSale()
    local count = 0
    for _, data in pairs(self.availability) do
        if data.isForSale then
            count = count + 1
        end
    end
    return count
end

--- Serialize event data to network stream
---@param streamId number Stream ID
---@param connection table Connection object
function RmAvailabilitySyncEvent:writeStream(streamId, connection)
    Log:trace(">>> RmAvailabilitySyncEvent:writeStream(%d entries)", self:countEntries())

    -- Write count
    local count = self:countEntries()
    streamWriteInt32(streamId, count)
    Log:debug("SYNC: Writing %d availability entries", count)

    -- Write each entry
    for farmlandId, data in pairs(self.availability) do
        streamWriteInt32(streamId, farmlandId)
        streamWriteBool(streamId, data.isForSale)
        streamWriteInt32(streamId, data.expiryDay)
        streamWriteInt32(streamId, data.listingDay)
        streamWriteInt32(streamId, data.listingPrice or 0)
        Log:trace("  SYNC: farmland=%d isForSale=%s expiryDay=%d listingDay=%d listingPrice=%d",
            farmlandId, tostring(data.isForSale), data.expiryDay, data.listingDay, data.listingPrice or 0)
    end

    Log:trace("<<< RmAvailabilitySyncEvent:writeStream()")
end

--- Deserialize event data from network stream
---@param streamId number Stream ID
---@param connection table Connection object
function RmAvailabilitySyncEvent:readStream(streamId, connection)
    Log:trace(">>> RmAvailabilitySyncEvent:readStream()")

    -- Read count
    local count = streamReadInt32(streamId)
    Log:debug("SYNC: Reading %d availability entries", count)

    -- Read entries
    self.availability = {}
    for i = 1, count do
        local farmlandId = streamReadInt32(streamId)
        local isForSale = streamReadBool(streamId)
        local expiryDay = streamReadInt32(streamId)
        local listingDay = streamReadInt32(streamId)
        local listingPrice = streamReadInt32(streamId)
        self.availability[farmlandId] = {
            isForSale = isForSale,
            expiryDay = expiryDay,
            listingDay = listingDay,
            listingPrice = listingPrice > 0 and listingPrice or nil,
        }
        Log:trace("  SYNC: farmland=%d isForSale=%s expiryDay=%d listingDay=%d listingPrice=%d",
            farmlandId, tostring(isForSale), expiryDay, listingDay, listingPrice)
    end

    self:run(connection)
    Log:trace("<<< RmAvailabilitySyncEvent:readStream()")
end

--- Execute event on receiving end
---@param connection table Connection object
function RmAvailabilitySyncEvent:run(connection)
    Log:trace(">>> RmAvailabilitySyncEvent:run() on %s",
        g_server and "SERVER" or "CLIENT")

    if g_server ~= nil then
        -- SERVER: Reject (server-authoritative only)
        Log:warning("Availability sync rejected: server is authoritative, clients cannot send")
        return
    end

    -- CLIENT: delegate to the testable inner method. Tests call
    -- _applyClientSync directly instead of trying to fool g_server, which
    -- the fmTest harness keeps non-nil for the duration of the suite.
    self:_applyClientSync(connection)

    Log:trace("<<< RmAvailabilitySyncEvent:run()")
end

--- Apply an incoming sync as if we were a client. Splits out so unit tests
--- can drive the client-side logic without stubbing g_server (which the
--- fmTest harness keeps set throughout, breaking any g_server=nil swap).
---@param connection table|nil
function RmAvailabilitySyncEvent:_applyClientSync(connection)
    local forSaleCount = self:countForSale()
    Log:info("Received availability sync: %d farmlands (%d for sale)",
        self:countEntries(), forSaleCount)

    -- Snapshot the old availability BEFORE replacement so the watchlist
    -- transition diff has something to compare against. This feature
    -- assumes FULL-SNAPSHOT semantics (current behavior); if the event
    -- is ever refactored to delta payloads, the diff logic in
    -- RmWatchlistUI._collectTransitions would need redesign to match the
    -- new payload contract.
    local oldAvailability = RmFmAvailability.availability or {}

    -- Replace local availability table
    RmFmAvailability.availability = self.availability

    -- Refresh map hotspot colors
    if RmFarmlandMarket ~= nil and RmFarmlandMarket.updateAllHotspotColors ~= nil then
        RmFarmlandMarket.updateAllHotspotColors()
    end

    -- Watchlist for-sale notification: the first sync after join is the
    -- baseline and is silent. Subsequent syncs notify on false->true
    -- transitions. Even if the first sync is empty (server had no
    -- availability state at join), that's still the baseline - the next
    -- sync's diff against {} correctly identifies any new listings as
    -- genuine post-join transitions, which IS the right behaviour
    -- (those parcels are new from this player's perspective). The flag
    -- is reset on BaseMission.delete and onStartMission so a reconnect
    -- starts fresh.
    if RmFmAvailability._initialSyncSeen ~= true then
        RmFmAvailability._initialSyncSeen = true
        Log:debug("Watchlist for-sale notify: first sync seen (count=%d), suppressing notifications",
            self:countEntries())
    else
        local transitions = RmWatchlistUI._collectTransitions(
            oldAvailability, self.availability)
        if #transitions > 0 then
            RmWatchlistUI.notifyForSaleTransitions(transitions)
        end
    end
end
