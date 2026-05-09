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

    -- Early-drop branches: server can't resolve the connection's player or
    -- farmId, so we cannot compute a scoped snapshot. We send an empty
    -- byFarm payload as a heartbeat. The receiver treats own-farm-absent
    -- as NO-OP, so this empty payload does NOT clear the client's
    -- optimistic state. That is acceptable here: if the server can't
    -- resolve the player, the connection is effectively broken; the
    -- client's cache will reconcile on next reconnect via
    -- sendInitialClientState (which ships a properly scoped snapshot
    -- landing in case (a) or (b)).
    local player = g_currentMission and g_currentMission:getPlayerByConnection(connection) or nil
    if player == nil then
        Log:warning("RmWatchlistToggleEvent: no player for connection; empty payload sent (no-op corrective)")
        connection:sendEvent(RmWatchlistSyncEvent.new({}))
        return
    end
    local farmId = player.farmId
    if type(farmId) ~= "number" or farmId <= 0 then
        Log:warning("RmWatchlistToggleEvent: invalid farmId=%s for connection; empty payload sent (no-op corrective)",
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
