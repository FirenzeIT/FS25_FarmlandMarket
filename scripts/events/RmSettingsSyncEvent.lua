--[[
    RmSettingsSyncEvent.lua
    Network event for synchronizing FarmlandMarket settings.

    Settings synced:
    - availabilityPresetState (Int32) - 1=off, 2=easy, 3=normal, 4=hard, 5=harder, 6=realistic
    - priceMultiplierState (Int32) - index into PRICE_MULTIPLIER_VALUES array

    Flow:
    - Client changes setting -> sends event to server (no local apply)
    - Server validates sender is master user -> applies on server -> broadcasts to all remote clients
    - Clients receive from server -> apply locally

    Author: Ritter
]]

local Log = RmLogging.getLogger("FarmlandMarket")

-- Event class declaration
RmSettingsSyncEvent = {}
local Mt = Class(RmSettingsSyncEvent, Event)
InitEventClass(RmSettingsSyncEvent, "RmSettingsSyncEvent")

--- Create empty event instance (required by event system)
---@return table event
function RmSettingsSyncEvent.emptyNew()
    Log:trace(">>> RmSettingsSyncEvent.emptyNew()")
    local self = Event.new(Mt)
    Log:trace("<<< RmSettingsSyncEvent.emptyNew()")
    return self
end

--- Create new event with data
---@param availabilityPresetState number Availability preset state (1-6)
---@param priceMultiplierState number Price multiplier state index
---@param negotiationEnabledState number Negotiation enabled state (1=On, 2=Off)
---@return table event
function RmSettingsSyncEvent.new(availabilityPresetState, priceMultiplierState, negotiationEnabledState)
    Log:trace(">>> RmSettingsSyncEvent.new(availabilityPresetState=%d, priceMultiplierState=%d, neg=%d)",
        availabilityPresetState, priceMultiplierState, negotiationEnabledState)
    local self = Event.new(Mt)
    self.availabilityPresetState = availabilityPresetState
    self.priceMultiplierState = priceMultiplierState
    self.negotiationEnabledState = negotiationEnabledState
    Log:trace("<<< RmSettingsSyncEvent.new()")
    return self
end

--- Serialize event data to network stream
---@param streamId number Stream ID
---@param connection table Connection object
function RmSettingsSyncEvent:writeStream(streamId, connection)
    Log:trace(">>> RmSettingsSyncEvent:writeStream(availabilityPresetState=%d, priceMultiplierState=%d, neg=%d)",
        self.availabilityPresetState, self.priceMultiplierState, self.negotiationEnabledState)
    streamWriteInt32(streamId, self.availabilityPresetState)
    streamWriteInt32(streamId, self.priceMultiplierState)
    streamWriteInt32(streamId, self.negotiationEnabledState)
    Log:trace("<<< RmSettingsSyncEvent:writeStream()")
end

--- Deserialize event data from network stream
---@param streamId number Stream ID
---@param connection table Connection object
function RmSettingsSyncEvent:readStream(streamId, connection)
    Log:trace(">>> RmSettingsSyncEvent:readStream()")
    self.availabilityPresetState = streamReadInt32(streamId)
    self.priceMultiplierState = streamReadInt32(streamId)
    self.negotiationEnabledState = streamReadInt32(streamId)
    Log:trace("    Read: availabilityPresetState=%d, priceMultiplierState=%d, neg=%d",
        self.availabilityPresetState, self.priceMultiplierState, self.negotiationEnabledState)
    self:run(connection)
    Log:trace("<<< RmSettingsSyncEvent:readStream()")
end

--- Execute event on receiving end
--- Server: validate, apply, broadcast to all remote clients
--- Client: apply from server broadcast
---@param connection table Connection object
function RmSettingsSyncEvent:run(connection)
    Log:trace(">>> RmSettingsSyncEvent:run() on %s",
        g_server and "SERVER" or "CLIENT")

    if g_server ~= nil then
        -- SERVER: Received from client - validate, apply, broadcast
        Log:debug("SYNC: Received settings sync from client")

        -- Validate sender is master user
        local isMasterUser = connection:getIsServer() or
                            g_currentMission.userManager:getIsConnectionMasterUser(connection)
        if not isMasterUser then
            Log:warning("Settings sync rejected: sender is not master user")
            return
        end

        Log:info("Applying settings: preset=%d multiplier=%d negotiation=%d",
            self.availabilityPresetState, self.priceMultiplierState, self.negotiationEnabledState)

        -- Apply on server (server IS the host in listen server mode)
        RmFmSettings.setAvailabilityPreset(self.availabilityPresetState)
        RmFmSettings.setPriceMultiplier(self.priceMultiplierState)
        RmFmSettings.setNegotiationEnabled(self.negotiationEnabledState)

        -- Broadcast to all remote clients (host already applied above)
        Log:debug("SYNC: Broadcasting settings to all clients")
        g_server:broadcastEvent(
            RmSettingsSyncEvent.new(self.availabilityPresetState, self.priceMultiplierState,
                self.negotiationEnabledState)
        )
    else
        -- CLIENT: Received from server broadcast - apply
        Log:info("Received settings from server: preset=%d multiplier=%d negotiation=%d",
            self.availabilityPresetState, self.priceMultiplierState, self.negotiationEnabledState)

        RmFmSettings.setAvailabilityPreset(self.availabilityPresetState)
        RmFmSettings.setPriceMultiplier(self.priceMultiplierState)
        RmFmSettings.setNegotiationEnabled(self.negotiationEnabledState)
    end

    Log:trace("<<< RmSettingsSyncEvent:run()")
end
