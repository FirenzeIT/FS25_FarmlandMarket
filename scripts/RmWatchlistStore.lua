--[[
    RmWatchlistStore.lua
    Server-authoritative master for the watchlist feature.

    Holds byFarm = {[farmId] = {[farmlandId] = true}}, which is the source of
    truth for which farmlands each farm is watching. Persists into the existing
    rm_FarmlandMarket.xml under <watchlist>, syncs per-farm subsets to clients,
    and validates client-driven mutations.

    Lifecycle:
    - reset() -> on BaseMission.delete (server only)
    - loadFromXMLFile -> from RmFarmlandMarket.loadFromSavegame, runs stale prune
    - saveToXMLFile -> from RmFarmlandMarket.saveToSavegame
    - sendInitialClientState(connection) -> from FSBaseMission.sendInitialClientState
    - applyToggle(farmId, farmlandId, add) -> from host short-circuit AND from
      RmWatchlistToggleEvent:run on the server

    Author: Ritter
]]

RmWatchlistStore = {}

local Log = RmLogging.getLogger("FarmlandMarket")

-- Master table. byFarm[farmId][farmlandId] = true.
RmWatchlistStore.byFarm = {}

-- ============================================================================
-- INTERNAL HELPERS
-- ============================================================================

--- Validate that a farmland is a legitimate watchlist target for the given
--- farm. Used by applyToggle (event path) and pruneStaleSubset (sync path).
---@param farmlandId number
---@param farmId number requesting / watching farm
---@return boolean ok, string|nil reason  reason is set when ok = false
local function isValidEntry(farmlandId, farmId)
    if type(farmlandId) ~= "number" or farmlandId <= 0 then
        return false, "invalid_farmlandId"
    end
    if type(farmId) ~= "number" or farmId <= 0 then
        return false, "invalid_farmId"
    end
    local farmlands = g_farmlandManager and g_farmlandManager:getFarmlands() or nil
    if farmlands == nil then
        return false, "farmlands_not_ready"
    end
    local farmland = farmlands[farmlandId]
    if type(farmland) ~= "table" then
        return false, "farmland_missing"
    end
    -- Order matters: owned_by_self is a strict subset of "not eligible"
    -- (eligibility requires NO_OWNER_FARM_ID), so we must surface the
    -- specific reason before the generic one. UX hooks may use this
    -- distinction later to show a tailored "you already own this" hint.
    if farmland.farmId == farmId then
        return false, "owned_by_self"
    end
    if not RmFmAvailability.isEligibleForAvailability(farmland) then
        return false, "farmland_not_eligible"
    end
    return true, nil
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

--- Wipe all server state. Called on BaseMission.delete. Mutates the table in
--- place so external references stay valid.
function RmWatchlistStore.reset()
    if g_server == nil then
        return
    end
    local count = 0
    for k in pairs(RmWatchlistStore.byFarm) do
        RmWatchlistStore.byFarm[k] = nil
        count = count + 1
    end
    Log:debug("RmWatchlistStore.reset: cleared %d farms", count)
end

--- Test-only reset. Same effect as reset() but without the server guard so
--- unit tests can run on the host without spinning up a real connection.
function RmWatchlistStore._resetForTest()
    for k in pairs(RmWatchlistStore.byFarm) do
        RmWatchlistStore.byFarm[k] = nil
    end
end

--- Apply a toggle to the master table after validating it. Used by the host
--- short-circuit AND by RmWatchlistToggleEvent on the server.
---@param farmId number requesting farm
---@param farmlandId number target farmland
---@param add boolean true = add, false = remove
---@return boolean ok, string|nil reason  reason set when ok = false
function RmWatchlistStore.applyToggle(farmId, farmlandId, add)
    if g_server == nil then
        Log:warning("RmWatchlistStore.applyToggle called off-server")
        return false, "not_server"
    end

    if add then
        local ok, reason = isValidEntry(farmlandId, farmId)
        if not ok then
            Log:debug("applyToggle reject add: farm=%s farmland=%s reason=%s",
                tostring(farmId), tostring(farmlandId), tostring(reason))
            return false, reason
        end
        RmWatchlistStore.byFarm[farmId] = RmWatchlistStore.byFarm[farmId] or {}
        RmWatchlistStore.byFarm[farmId][farmlandId] = true
        Log:debug("applyToggle add: farm=%d farmland=%d", farmId, farmlandId)
        -- Live propagation: every connection on this farm gets the canonical
        -- subset so same-farm players see each other's adds without a
        -- reconnect. See broadcastToFarm for the host-self-update path.
        RmWatchlistStore.broadcastToFarm(farmId)
        return true, nil
    end

    -- Remove: tolerant of stale farmlandIds. The point of remove is "I don't
    -- want this on my list anymore"; whether the id passes eligibility today
    -- is irrelevant - the entry has to go.
    if type(farmlandId) ~= "number" or type(farmId) ~= "number" then
        return false, "invalid_args"
    end
    local set = RmWatchlistStore.byFarm[farmId]
    if set ~= nil then
        set[farmlandId] = nil
        -- Collapse empty per-farm sub-table so iteration costs stay flat.
        if next(set) == nil then
            RmWatchlistStore.byFarm[farmId] = nil
        end
    end
    Log:debug("applyToggle remove: farm=%d farmland=%d", farmId, farmlandId)
    -- Same-farm clients need the new (smaller) subset live, not at reconnect.
    RmWatchlistStore.broadcastToFarm(farmId)
    return true, nil
end

--- Return a fresh array of farmlandIds the given farm is watching, after
--- dropping stale entries. Mutates byFarm[farmId] - any entry that fails
--- isValidEntry for a "definitely stale" reason is removed in place. Used
--- by sendInitialClientState and the corrective-sync path.
---
--- "farmlands_not_ready" is treated as transient: the entry is KEPT in the
--- master AND included in the returned ids. Otherwise a transient unload
--- of g_farmlandManager (mid-load, late-join race) would silently wipe the
--- entire watchlist - the harshest possible failure mode.
---@param farmId number
---@return number[] ids
function RmWatchlistStore.pruneStaleSubset(farmId)
    if g_server == nil then return {} end
    local set = RmWatchlistStore.byFarm[farmId]
    if set == nil then return {} end

    local ids = {}
    local toRemove = {}
    for farmlandId in pairs(set) do
        local ok, reason = isValidEntry(farmlandId, farmId)
        if ok then
            table.insert(ids, farmlandId)
        elseif reason == "farmlands_not_ready" then
            -- Transient: keep the entry in the master, return it to the
            -- caller. The next prune (after the world finishes loading)
            -- will resolve eligibility correctly.
            table.insert(ids, farmlandId)
        else
            table.insert(toRemove, farmlandId)
        end
    end
    for _, fid in ipairs(toRemove) do
        set[fid] = nil
    end
    if next(set) == nil then
        RmWatchlistStore.byFarm[farmId] = nil
    end
    -- Sort so wire order is deterministic - simplifies stream-mock tests and
    -- keeps the dialog's natural-sort happy without re-sorting on the client.
    table.sort(ids)
    return ids
end

-- ============================================================================
-- SAVEGAME PERSISTENCE
-- Schema is registered in RmFarmlandMarket.registerXmlSchema next to the
-- existing availability + negotiation registrations.
-- ============================================================================

--- Restore byFarm from XML, dropping stale entries during load. Server only.
---@param xmlFile table XMLFile object
function RmWatchlistStore.loadFromXMLFile(xmlFile)
    Log:trace(">>> RmWatchlistStore.loadFromXMLFile()")
    if g_server == nil then
        Log:trace("<<< RmWatchlistStore.loadFromXMLFile [not server]")
        return
    end

    RmWatchlistStore._resetForTest()

    local i = 0
    while true do
        local farmKey = string.format("rmFarmlandMarket.watchlist.farm(%d)", i)
        if not xmlFile:hasProperty(farmKey) then break end

        local farmId = xmlFile:getValue(farmKey .. "#farmId")
        if type(farmId) ~= "number" or farmId <= 0 then
            Log:warning("Watchlist load: skipping farm entry %d (invalid farmId=%s)",
                i, tostring(farmId))
        else
            local set = {}
            local j = 0
            while true do
                local entryKey = string.format("%s.entry(%d)", farmKey, j)
                if not xmlFile:hasProperty(entryKey) then break end
                local farmlandId = xmlFile:getValue(entryKey .. "#farmlandId")
                if type(farmlandId) == "number" and farmlandId > 0 then
                    set[farmlandId] = true
                else
                    Log:warning("Watchlist load: skipping entry %d.%d (invalid farmlandId=%s)",
                        i, j, tostring(farmlandId))
                end
                j = j + 1
            end
            if next(set) ~= nil then
                RmWatchlistStore.byFarm[farmId] = set
            end
        end
        i = i + 1
    end

    -- Stale-prune at load: drop ids whose farmland is gone or owned by self.
    -- Iterate via pruneStaleSubset which already collapses empty sub-tables.
    local farmIds = {}
    for fid in pairs(RmWatchlistStore.byFarm) do
        table.insert(farmIds, fid)
    end
    local totalKept, totalDropped = 0, 0
    for _, fid in ipairs(farmIds) do
        local before = 0
        for _ in pairs(RmWatchlistStore.byFarm[fid] or {}) do before = before + 1 end
        local kept = #RmWatchlistStore.pruneStaleSubset(fid)
        totalKept = totalKept + kept
        totalDropped = totalDropped + (before - kept)
    end
    Log:debug("Watchlist loaded: %d farms, %d entries kept, %d dropped (stale prune)",
        #farmIds, totalKept, totalDropped)
    Log:trace("<<< RmWatchlistStore.loadFromXMLFile()")
end

--- Persist byFarm to XML. Server only.
---@param xmlFile table XMLFile object
function RmWatchlistStore.saveToXMLFile(xmlFile)
    Log:trace(">>> RmWatchlistStore.saveToXMLFile()")
    if g_server == nil then
        Log:trace("<<< RmWatchlistStore.saveToXMLFile [not server]")
        return
    end

    -- Sort farmIds for deterministic XML output (helps diffing savegames).
    local farmIds = {}
    for fid in pairs(RmWatchlistStore.byFarm) do
        if next(RmWatchlistStore.byFarm[fid]) ~= nil then
            table.insert(farmIds, fid)
        end
    end
    table.sort(farmIds)

    local farmEntries, totalEntries = 0, 0
    for _, farmId in ipairs(farmIds) do
        local farmKey = string.format("rmFarmlandMarket.watchlist.farm(%d)", farmEntries)
        xmlFile:setValue(farmKey .. "#farmId", farmId)

        local farmlandIds = {}
        for fid in pairs(RmWatchlistStore.byFarm[farmId]) do
            table.insert(farmlandIds, fid)
        end
        table.sort(farmlandIds)

        for j, farmlandId in ipairs(farmlandIds) do
            local entryKey = string.format("%s.entry(%d)", farmKey, j - 1)
            xmlFile:setValue(entryKey .. "#farmlandId", farmlandId)
            totalEntries = totalEntries + 1
        end
        farmEntries = farmEntries + 1
    end

    Log:debug("Watchlist saved: %d farms, %d total entries", farmEntries, totalEntries)
    Log:trace("<<< RmWatchlistStore.saveToXMLFile()")
end

-- ============================================================================
-- LATE-JOIN SYNC
-- ============================================================================

--- Send the joining client THEIR farm's subset. Runs server-side stale prune
--- before sending so late joiners never receive entries that other clients
--- would already have pruned locally. Server only.
---@param connection table Connection object for the joining client
function RmWatchlistStore.sendInitialClientState(connection)
    Log:trace(">>> RmWatchlistStore.sendInitialClientState()")
    if g_server == nil then
        return
    end

    -- Nil-guard: if the player object is not bound to this connection yet,
    -- send an empty subset rather than throwing or sending the wrong farm's
    -- list. Empty syncs are harmless - the client clears its local view and
    -- the next dialog open will reflect that.
    local player = g_currentMission and g_currentMission:getPlayerByConnection(connection) or nil
    if player == nil then
        Log:warning("sendInitialClientState: no player for connection, sending empty sync")
        connection:sendEvent(RmWatchlistSyncEvent.new({}))
        return
    end
    local farmId = player.farmId
    if type(farmId) ~= "number" or farmId <= 0 then
        Log:warning("sendInitialClientState: invalid farmId=%s, sending empty sync",
            tostring(farmId))
        connection:sendEvent(RmWatchlistSyncEvent.new({}))
        return
    end

    local ids = RmWatchlistStore.pruneStaleSubset(farmId)
    Log:debug("sendInitialClientState: sending %d entries to farm=%d", #ids, farmId)
    connection:sendEvent(RmWatchlistSyncEvent.new(ids))
    Log:trace("<<< RmWatchlistStore.sendInitialClientState()")
end

--- Send a corrective sync to a single connection - used by the toggle event
--- handler when it rejects a client request. The client receives the canonical
--- subset and replaces its local cache, converging within one round-trip.
---@param connection table
---@param farmId number
function RmWatchlistStore.sendCorrectiveSync(connection, farmId)
    if g_server == nil then return end
    if type(farmId) ~= "number" or farmId <= 0 then return end
    local ids = RmWatchlistStore.pruneStaleSubset(farmId)
    Log:debug("sendCorrectiveSync: %d entries to farm=%d", #ids, farmId)
    connection:sendEvent(RmWatchlistSyncEvent.new(ids))
end

--- Send the canonical per-farm subset to EVERY connection currently bound to
--- that farm, AND update the host's local cache if the host is on the same
--- farm. Called after a successful applyToggle so all same-farm players see
--- the change live (not just at next reconnect).
---
--- The host doesn't appear as a remote connection in userManager:getUsers,
--- so its local RmWatchlistUI.watched needs an explicit refresh - otherwise
--- a remote client toggling on the host's farm would update only the remote
--- side and the host's dialog would stay stale until reload.
---@param farmId number
function RmWatchlistStore.broadcastToFarm(farmId)
    if g_server == nil then return end
    if type(farmId) ~= "number" or farmId <= 0 then return end
    local ids = RmWatchlistStore.pruneStaleSubset(farmId)

    -- Host self-update if applicable.
    local hostFarmId = RmWatchlistUI and RmWatchlistUI._localFarmId and RmWatchlistUI._localFarmId() or nil
    if hostFarmId == farmId then
        RmWatchlistUI.replaceFromSync(ids)
    end

    -- Remote same-farm clients.
    if g_currentMission == nil or g_currentMission.userManager == nil then return end
    local sent = 0
    for _, user in ipairs(g_currentMission.userManager:getUsers()) do
        local conn = user.getConnection and user:getConnection() or nil
        if conn ~= nil then
            local player = g_currentMission:getPlayerByConnection(conn)
            if player ~= nil and player.farmId == farmId then
                conn:sendEvent(RmWatchlistSyncEvent.new(ids))
                sent = sent + 1
            end
        end
    end
    Log:debug("broadcastToFarm: farmId=%d ids=%d remote_sent=%d host_self=%s",
        farmId, #ids, sent, tostring(hostFarmId == farmId))
end
