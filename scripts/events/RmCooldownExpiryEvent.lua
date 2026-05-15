--[[
    RmCooldownExpiryEvent.lua
    Server -> all clients. Carries the list of {farmId, farmlandId} pairs whose
    negotiation cooldowns reached zero on the current PERIOD_CHANGED tick.

    Server-authoritative: clients receiving server-side run() reject.

    Each client filters the incoming list locally (own farmId + isWatched +
    not owned by local farm) and surfaces one batched HUD message. Mirrors
    the for-sale notification's broadcast + client-filter shape.

    Wire format:
      Int32 count
      For each pair (sorted by farmId asc, farmlandId asc):
        Int32 farmId
        Int32 farmlandId

    Sorting in new() makes the wire bytes deterministic across runs.

    Author: Ritter
]]

local Log = RmLogging.getLogger("FarmlandMarket")

RmCooldownExpiryEvent = {}
local Mt = Class(RmCooldownExpiryEvent, Event)
InitEventClass(RmCooldownExpiryEvent, "RmCooldownExpiryEvent")

--- Test-only seam: when true, readStream skips the trailing self:run call so
--- a round-trip test can verify deserialization without firing the HUD path.
--- Tests MUST flip this back to false on teardown.
RmCooldownExpiryEvent._skipRunForTest = false

--- Empty constructor required by the event framework.
function RmCooldownExpiryEvent.emptyNew()
    return Event.new(Mt)
end

--- Construct the event with a list of expiries.
---
--- The input is defensively copied and sorted by (farmId asc, farmlandId asc)
--- so the wire bytes are deterministic across runs.
---
---@param expiries table[] list of { farmId=number, farmlandId=number }
---@return table event
function RmCooldownExpiryEvent.new(expiries)
    local self = Event.new(Mt)
    self.expiries = {}
    local rawCount = 0
    if type(expiries) == "table" then
        for _, e in ipairs(expiries) do
            rawCount = rawCount + 1
            if type(e) == "table"
                and type(e.farmId) == "number" and e.farmId > 0
                and type(e.farmlandId) == "number" and e.farmlandId > 0 then
                table.insert(self.expiries, {
                    farmId = e.farmId,
                    farmlandId = e.farmlandId,
                })
            end
        end
    end
    if rawCount ~= #self.expiries then
        Log:warning("RmCooldownExpiryEvent.new: dropped %d malformed entries (kept %d)",
            rawCount - #self.expiries, #self.expiries)
    end
    table.sort(self.expiries, function(a, b)
        if a.farmId ~= b.farmId then return a.farmId < b.farmId end
        return a.farmlandId < b.farmlandId
    end)
    return self
end

---@param streamId number
---@param connection table
function RmCooldownExpiryEvent:writeStream(streamId, connection)
    local count = #self.expiries
    streamWriteInt32(streamId, count)
    for i = 1, count do
        local e = self.expiries[i]
        streamWriteInt32(streamId, e.farmId)
        streamWriteInt32(streamId, e.farmlandId)
    end
    Log:debug("COOLDOWN-EXPIRY: writeStream %d entries", count)
end

---@param streamId number
---@param connection table
function RmCooldownExpiryEvent:readStream(streamId, connection)
    local count = streamReadInt32(streamId)
    self.expiries = {}
    for i = 1, count do
        local farmId = streamReadInt32(streamId)
        local farmlandId = streamReadInt32(streamId)
        self.expiries[i] = { farmId = farmId, farmlandId = farmlandId }
    end
    Log:debug("COOLDOWN-EXPIRY: readStream %d entries", count)
    if not RmCooldownExpiryEvent._skipRunForTest then
        self:run(connection)
    end
end

---@param connection table
function RmCooldownExpiryEvent:run(connection)
    if g_server ~= nil then
        -- Server-authoritative: clients should never send this event.
        -- Defensive backstop only -- broadcastEvent(sendLocal=false) skips
        -- the host loopback so this branch should never fire in normal
        -- operation. Mirrors RmWatchlistSyncEvent.
        Log:warning("RmCooldownExpiryEvent rejected: clients cannot send (server-authoritative)")
        return
    end
    RmWatchlistUI.notifyCooldownExpiries(self.expiries)
end
