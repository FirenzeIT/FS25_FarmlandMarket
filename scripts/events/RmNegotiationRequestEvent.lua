--[[
    RmNegotiationRequestEvent.lua
    Client → host: negotiation action request.

    Actions: start_listed, start_unlisted, start_sell, offer, ask, walkaway, respond, cancel

    Flow:
    - Client sends action request to server
    - Server validates, executes via RmNegotiationManager, sends RmNegotiationResultEvent back

    Author: Ritter
]]

local Log = RmLogging.getLogger("FarmlandMarket")

-- Event class declaration
RmNegotiationRequestEvent = {}
local Mt = Class(RmNegotiationRequestEvent, Event)
InitEventClass(RmNegotiationRequestEvent, "RmNegotiationRequestEvent")

--- Create empty event instance (required by event system)
---@return table event
function RmNegotiationRequestEvent.emptyNew()
    Log:trace(">>> RmNegotiationRequestEvent.emptyNew()")
    local self = Event.new(Mt)
    Log:trace("<<< RmNegotiationRequestEvent.emptyNew()")
    return self
end

--- Create new event with action data
---@param actionType string "start_listed"|"start_unlisted"|"start_sell"|"offer"|"ask"|"walkaway"|"respond"|"cancel"
---@param farmlandId number For start actions (0 otherwise)
---@param amount number For offer/ask (0 otherwise)
---@param accept boolean For respond (false otherwise)
---@param strategy string For start_sell ("" otherwise)
---@return table event
function RmNegotiationRequestEvent.new(actionType, farmlandId, amount, accept, strategy)
    Log:trace(">>> RmNegotiationRequestEvent.new(action=%s)", tostring(actionType))
    local self = Event.new(Mt)
    self.actionType = actionType
    self.farmlandId = farmlandId
    self.amount = amount
    self.accept = accept
    self.strategy = strategy
    Log:trace("<<< RmNegotiationRequestEvent.new()")
    return self
end

--- Serialize event data to network stream
---@param streamId number Stream ID
---@param connection table Connection object
function RmNegotiationRequestEvent:writeStream(streamId, connection)
    Log:trace(">>> RmNegotiationRequestEvent:writeStream(action=%s)", self.actionType)
    streamWriteString(streamId, self.actionType)
    streamWriteInt32(streamId, self.farmlandId)
    streamWriteFloat32(streamId, self.amount)
    streamWriteBool(streamId, self.accept)
    streamWriteString(streamId, self.strategy)
    Log:trace("<<< RmNegotiationRequestEvent:writeStream()")
end

--- Deserialize event data from network stream
---@param streamId number Stream ID
---@param connection table Connection object
function RmNegotiationRequestEvent:readStream(streamId, connection)
    Log:trace(">>> RmNegotiationRequestEvent:readStream()")
    self.actionType = streamReadString(streamId)
    self.farmlandId = streamReadInt32(streamId)
    self.amount = streamReadFloat32(streamId)
    self.accept = streamReadBool(streamId)
    self.strategy = streamReadString(streamId)
    Log:trace("    Read: action=%s farmlandId=%d amount=%.0f accept=%s strategy=%s",
        self.actionType, self.farmlandId, self.amount, tostring(self.accept), self.strategy)
    self:run(connection)
    Log:trace("<<< RmNegotiationRequestEvent:readStream()")
end

--- Execute event on server: route action to manager, send result back
---@param connection table Connection object
function RmNegotiationRequestEvent:run(connection)
    Log:trace(">>> RmNegotiationRequestEvent:run(action=%s)", self.actionType)

    if g_server == nil then
        Log:warning("NegotiationRequest rejected: not on server")
        return
    end

    local player = g_currentMission:getPlayerByConnection(connection)
    if player == nil then
        Log:warning("NegotiationRequest: no player for connection")
        return
    end
    local farmId = player.farmId
    if farmId == nil then
        Log:warning("NegotiationRequest: no farmId for player")
        return
    end

    local snapshot, errorReason
    local action = self.actionType

    if action == "start_listed" then
        snapshot, errorReason = RmNegotiationManager.startListedBuy(self.farmlandId, farmId)
    elseif action == "start_unlisted" then
        snapshot, errorReason = RmNegotiationManager.startUnlistedBuy(self.farmlandId, farmId)
    elseif action == "start_sell" then
        snapshot, errorReason = RmNegotiationManager.startSell(self.farmlandId, farmId, self.amount)
    elseif action == "offer" then
        snapshot, errorReason = RmNegotiationManager.submitOffer(farmId, self.amount)
    elseif action == "ask" then
        snapshot, errorReason = RmNegotiationManager.submitAsk(farmId, self.amount)
    elseif action == "walkaway" then
        snapshot, errorReason = RmNegotiationManager.walkaway(farmId)
    elseif action == "respond" then
        snapshot, errorReason = RmNegotiationManager.respondToProposal(farmId, self.accept)
    elseif action == "cancel" then
        RmNegotiationManager.cancelSession(farmId)
        snapshot = nil
        errorReason = nil
    else
        Log:warning("NegotiationRequest: unknown action '%s'", tostring(action))
        errorReason = "unknown_action"
    end

    -- Send result back to requesting client
    local success = (errorReason == nil)
    connection:sendEvent(RmNegotiationResultEvent.new(
        success,
        errorReason or "",
        snapshot
    ))

    Log:trace("<<< RmNegotiationRequestEvent:run()")
end
