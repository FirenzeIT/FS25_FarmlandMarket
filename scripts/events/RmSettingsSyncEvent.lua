--[[
    RmSettingsSyncEvent.lua
    Network event for synchronizing FarmlandMarket settings.

    Settings synced:
    - availabilityPresetState (Int32) - 1=off, 2=easy, 3=normal, 4=hard, 5=harder, 6=realistic
    - customPricePerHa (Int32) - absolute price per hectare (0 = map default)
    - negotiateBuyState (Int32) - 1=Off, 2=On
    - negotiateSellState (Int32) - 1=Off, 2=On
    - unlistedOffersState (Int32) - 1=Off, 2=On

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
---@param customPricePerHa number Custom price per hectare (0 = map default)
---@param negotiateBuyState number Negotiate buy state (1=Off, 2=On)
---@param negotiateSellState number Negotiate sell state (1=Off, 2=On)
---@param unlistedOffersState number Unlisted offers state (1=Off, 2=On)
---@return table event
function RmSettingsSyncEvent.new(availabilityPresetState, customPricePerHa,
        negotiateBuyState, negotiateSellState, unlistedOffersState)
    Log:trace(">>> RmSettingsSyncEvent.new(preset=%d, price=%d, negBuy=%d, negSell=%d, unlisted=%d)",
        availabilityPresetState, customPricePerHa, negotiateBuyState, negotiateSellState, unlistedOffersState)
    local self = Event.new(Mt)
    self.availabilityPresetState = availabilityPresetState
    self.customPricePerHa = customPricePerHa
    self.negotiateBuyState = negotiateBuyState
    self.negotiateSellState = negotiateSellState
    self.unlistedOffersState = unlistedOffersState
    Log:trace("<<< RmSettingsSyncEvent.new()")
    return self
end

--- Serialize event data to network stream
---@param streamId number Stream ID
---@param connection table Connection object
function RmSettingsSyncEvent:writeStream(streamId, connection)
    Log:trace(">>> RmSettingsSyncEvent:writeStream(preset=%d, price=%d, negBuy=%d, negSell=%d, unlisted=%d)",
        self.availabilityPresetState, self.customPricePerHa,
        self.negotiateBuyState, self.negotiateSellState, self.unlistedOffersState)
    streamWriteInt32(streamId, self.availabilityPresetState)
    streamWriteInt32(streamId, self.customPricePerHa)
    streamWriteInt32(streamId, self.negotiateBuyState)
    streamWriteInt32(streamId, self.negotiateSellState)
    streamWriteInt32(streamId, self.unlistedOffersState)
    Log:trace("<<< RmSettingsSyncEvent:writeStream()")
end

--- Deserialize event data from network stream
---@param streamId number Stream ID
---@param connection table Connection object
function RmSettingsSyncEvent:readStream(streamId, connection)
    Log:trace(">>> RmSettingsSyncEvent:readStream()")
    self.availabilityPresetState = streamReadInt32(streamId)
    self.customPricePerHa = streamReadInt32(streamId)
    self.negotiateBuyState = streamReadInt32(streamId)
    self.negotiateSellState = streamReadInt32(streamId)
    self.unlistedOffersState = streamReadInt32(streamId)
    Log:trace("    Read: preset=%d, price=%d, negBuy=%d, negSell=%d, unlisted=%d",
        self.availabilityPresetState, self.customPricePerHa,
        self.negotiateBuyState, self.negotiateSellState, self.unlistedOffersState)
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

        Log:info("Applying settings: preset=%d price/ha=%d negBuy=%d negSell=%d unlisted=%d",
            self.availabilityPresetState, self.customPricePerHa,
            self.negotiateBuyState, self.negotiateSellState, self.unlistedOffersState)

        -- Apply on server (server IS the host in listen server mode)
        RmFmSettings.setAvailabilityPreset(self.availabilityPresetState)
        RmFmSettings.setCustomPricePerHa(self.customPricePerHa)
        RmFmSettings.setNegotiateBuy(self.negotiateBuyState)
        RmFmSettings.setNegotiateSell(self.negotiateSellState)
        RmFmSettings.setUnlistedOffers(self.unlistedOffersState)

        -- Broadcast to all remote clients (host already applied above)
        Log:debug("SYNC: Broadcasting settings to all clients")
        g_server:broadcastEvent(
            RmSettingsSyncEvent.new(self.availabilityPresetState, self.customPricePerHa,
                self.negotiateBuyState, self.negotiateSellState, self.unlistedOffersState)
        )
    else
        -- CLIENT: Received from server broadcast - apply
        Log:info("Received settings from server: preset=%d price/ha=%d negBuy=%d negSell=%d unlisted=%d",
            self.availabilityPresetState, self.customPricePerHa,
            self.negotiateBuyState, self.negotiateSellState, self.unlistedOffersState)

        RmFmSettings.setAvailabilityPreset(self.availabilityPresetState)
        RmFmSettings.setCustomPricePerHa(self.customPricePerHa)
        RmFmSettings.setNegotiateBuy(self.negotiateBuyState)
        RmFmSettings.setNegotiateSell(self.negotiateSellState)
        RmFmSettings.setUnlistedOffers(self.unlistedOffersState)
    end

    Log:trace("<<< RmSettingsSyncEvent:run()")
end
