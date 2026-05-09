--[[
    RmWatchlistToggleEvent.lua
    Client -> server. Requests an add or remove for the requesting client's
    own farm. The server derives farmId from the connection (clients never
    pass it on the wire), validates, mutates RmWatchlistStore.byFarm, and on
    rejection sends a corrective RmWatchlistSyncEvent back to the originating
    client so the optimistic local cache reconverges.

    Wire format:
      Int32 farmlandId
      Bool  add        (true = add, false = remove)

    Author: Ritter
]]

local Log = RmLogging.getLogger("FarmlandMarket")

RmWatchlistToggleEvent = {}
local Mt = Class(RmWatchlistToggleEvent, Event)
InitEventClass(RmWatchlistToggleEvent, "RmWatchlistToggleEvent")

--- Test-only seam. When set true, readStream skips the trailing self:run
--- call so a stream round-trip test can exercise the deserializer without
--- triggering server-side mutation of production state. Tests MUST flip
--- this back to false on teardown.
RmWatchlistToggleEvent._skipRunForTest = false

function RmWatchlistToggleEvent.emptyNew()
    return Event.new(Mt)
end

---@param farmlandId number
---@param add boolean
---@return table event
function RmWatchlistToggleEvent.new(farmlandId, add)
    local self = Event.new(Mt)
    self.farmlandId = farmlandId
    self.add = add and true or false
    return self
end

---@param streamId number
---@param connection table
function RmWatchlistToggleEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmlandId)
    streamWriteBool(streamId, self.add)
    Log:trace("RmWatchlistToggleEvent:writeStream farmland=%d add=%s",
        self.farmlandId, tostring(self.add))
end

---@param streamId number
---@param connection table
function RmWatchlistToggleEvent:readStream(streamId, connection)
    self.farmlandId = streamReadInt32(streamId)
    self.add = streamReadBool(streamId)
    Log:trace("RmWatchlistToggleEvent:readStream farmland=%d add=%s",
        self.farmlandId, tostring(self.add))
    if not RmWatchlistToggleEvent._skipRunForTest then
        self:run(connection)
    end
end

---@param connection table
function RmWatchlistToggleEvent:run(connection)
    if g_server == nil then
        Log:warning("RmWatchlistToggleEvent rejected: clients cannot receive (server-only)")
        return
    end

    -- Early-drop branches still must answer the originating client - the
    -- client already mutated its local cache optimistically and will stay
    -- diverged forever without a corrective sync. We can't compute a
    -- canonical subset without farmId, so fall back to an empty sync; the
    -- client will clear its watched and the next sendInitialClientState
    -- (on rebind / reconnect) restores the correct state.
    local player = g_currentMission and g_currentMission:getPlayerByConnection(connection) or nil
    if player == nil then
        Log:warning("RmWatchlistToggleEvent: no player for connection; sending empty corrective sync")
        connection:sendEvent(RmWatchlistSyncEvent.new({}))
        return
    end
    local farmId = player.farmId
    if type(farmId) ~= "number" or farmId <= 0 then
        Log:warning("RmWatchlistToggleEvent: invalid farmId=%s for connection; sending empty corrective sync",
            tostring(farmId))
        connection:sendEvent(RmWatchlistSyncEvent.new({}))
        return
    end

    local ok, reason = RmWatchlistStore.applyToggle(farmId, self.farmlandId, self.add)
    if not ok then
        Log:debug("RmWatchlistToggleEvent: applyToggle rejected (reason=%s); sending corrective sync",
            tostring(reason))
        RmWatchlistStore.sendCorrectiveSync(connection, farmId)
    end
    -- On success, applyToggle already broadcasted to the farm (which
    -- includes this connection), so the originator gets canonical state too.
end
