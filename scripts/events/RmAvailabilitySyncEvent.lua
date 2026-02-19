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
    else
        -- CLIENT: Received from server
        local forSaleCount = self:countForSale()
        Log:info("Received availability sync: %d farmlands (%d for sale)",
            self:countEntries(), forSaleCount)

        -- Replace local availability table
        RmFmAvailability.availability = self.availability

        -- Refresh map hotspot colors
        RmFarmlandMarket.updateAllHotspotColors()
    end

    Log:trace("<<< RmAvailabilitySyncEvent:run()")
end
