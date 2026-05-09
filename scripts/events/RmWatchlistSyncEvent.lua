--[[
    RmWatchlistSyncEvent.lua
    Server -> single client. Carries the canonical farmlandId subset for
    that client's farm. Used in two paths:
      1. Late-join sync (RmWatchlistStore.sendInitialClientState).
      2. Corrective sync after a rejected RmWatchlistToggleEvent.

    Wire format:
      Int32 count
      Int32[count] farmlandIds

    Author: Ritter
]]

local Log = RmLogging.getLogger("FarmlandMarket")

RmWatchlistSyncEvent = {}
local Mt = Class(RmWatchlistSyncEvent, Event)
InitEventClass(RmWatchlistSyncEvent, "RmWatchlistSyncEvent")

--- Empty constructor required by the event framework.
--- Test-only seam: see RmWatchlistToggleEvent._skipRunForTest. When true,
--- readStream skips the trailing self:run call so a round-trip test can
--- verify deserialization without mutating RmWatchlistUI.watched.
RmWatchlistSyncEvent._skipRunForTest = false

function RmWatchlistSyncEvent.emptyNew()
    return Event.new(Mt)
end

--- Construct the event with a list of farmlandIds for the receiving farm.
--- The input array is defensively COPIED + COMPACTED so a sparse caller
--- (an array with nil holes) cannot make writeStream's `#self.ids` count
--- diverge from its `streamWriteInt32(...,nil)` write loop, which would
--- crash the engine. All current callers pass dense tables; the copy is
--- a 5-line guard against a future refactor.
---@param ids number[] list of farmlandIds
---@return table event
function RmWatchlistSyncEvent.new(ids)
    local self = Event.new(Mt)
    self.ids = {}
    if ids ~= nil then
        for _, id in ipairs(ids) do
            if type(id) == "number" then
                table.insert(self.ids, id)
            end
        end
    end
    return self
end

---@param streamId number
---@param connection table
function RmWatchlistSyncEvent:writeStream(streamId, connection)
    local count = #self.ids
    streamWriteInt32(streamId, count)
    for i = 1, count do
        streamWriteInt32(streamId, self.ids[i])
    end
    Log:trace("RmWatchlistSyncEvent:writeStream count=%d", count)
end

---@param streamId number
---@param connection table
function RmWatchlistSyncEvent:readStream(streamId, connection)
    local count = streamReadInt32(streamId)
    self.ids = {}
    for i = 1, count do
        self.ids[i] = streamReadInt32(streamId)
    end
    Log:trace("RmWatchlistSyncEvent:readStream count=%d", count)
    if not RmWatchlistSyncEvent._skipRunForTest then
        self:run(connection)
    end
end

---@param connection table
function RmWatchlistSyncEvent:run(connection)
    if g_server ~= nil then
        -- This event is server -> client only. A client should never send it.
        Log:warning("RmWatchlistSyncEvent rejected: clients cannot send (server-authoritative)")
        return
    end
    Log:info("Received watchlist sync: %d entries", #self.ids)
    RmWatchlistUI.replaceFromSync(self.ids)
end
