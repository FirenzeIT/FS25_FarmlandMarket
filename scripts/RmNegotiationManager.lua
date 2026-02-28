--[[
    RmNegotiationManager.lua
    Session-based state machine wrapping RmNegotiationEngine.

    Manages:
    - One active negotiation session per farm
    - Period-based cooldowns after failed negotiations
    - Farmland locks for multiplayer exclusivity
    - Cached seller profiles for listed farmlands
    - Host/client routing via network events
    - Console commands for testing

    Server-authoritative: all state lives on the host/server.
    Clients send RmNegotiationRequestEvent, receive RmNegotiationResultEvent.

    Author: Ritter
]]

-- =============================================================================
-- MODULE DECLARATION & CONSTANTS
-- =============================================================================

RmNegotiationManager = {}

local Log = RmLogging.getLogger("FarmlandMarket")

-- Additional outcome constant (engine has no walkaway outcome)
RmNegotiationManager.OUTCOME_WALKAWAY = "walkaway"

-- =============================================================================
-- COOLDOWN PARAMETER TABLE (with walkaway additions)
-- =============================================================================

RmNegotiationManager.COOLDOWNS = {
    listed_rejected      = { easy = 1, normal = 1, hard = 2, harder = 2, realistic = 3 },
    listed_failed        = { easy = 1, normal = 1, hard = 1, harder = 1, realistic = 2 },
    listed_walkaway      = { easy = 1, normal = 1, hard = 1, harder = 1, realistic = 2 },
    unlisted_dismissed   = { easy = 2, normal = 3, hard = 4, harder = 5, realistic = 6 },
    unlisted_rejected    = { easy = 2, normal = 3, hard = 3, harder = 4, realistic = 5 },
    unlisted_failed      = { easy = 1, normal = 2, hard = 2, harder = 3, realistic = 4 },
    unlisted_walkaway    = { easy = 1, normal = 2, hard = 2, harder = 3, realistic = 4 },
    selling_npc_walked   = { easy = 1, normal = 1, hard = 1, harder = 1, realistic = 1 },
    selling_walkaway     = { easy = 0, normal = 0, hard = 0, harder = 0, realistic = 0 },
}

-- =============================================================================
-- STATE TABLES (module-level, server-only)
-- =============================================================================

-- One active session per farm (farmId → session)
RmNegotiationManager.sessions = {}

-- Cooldowns: [farmlandId][farmId] = { remaining=N, lastOutcome=string }
RmNegotiationManager.cooldowns = {}

-- Locks: [farmlandId] = farmId (or nil if unlocked)
RmNegotiationManager.locks = {}

-- Cached listed seller profiles: [farmlandId] = profile table
RmNegotiationManager.sellerProfiles = {}

-- Pending deals: [farmlandId] = true (consumed by FarmlandStateEvent bypass)
RmNegotiationManager.pendingDeals = {}

-- Guard flag: true during savegame load
RmNegotiationManager.loadingFromSavegame = false

-- =============================================================================
-- INTERNAL HELPERS (local)
-- =============================================================================

--- Returns current preset name from settings. "off" → "normal" for engine compatibility.
---@return string preset
local function getPreset()
    local preset = RmFmSettings.getPresetName()
    if preset == "off" then return "normal" end
    return preset
end

--- Returns current farmland price.
---@param farmlandId number
---@return number|nil price
local function getMarketValue(farmlandId)
    local farmland = g_farmlandManager:getFarmlandById(farmlandId)
    if farmland == nil then return nil end
    return farmland.price
end

--- Extracts farmId from network connection (MP).
---@param connection table Connection object
---@return number|nil farmId
local function getFarmIdForConnection(connection)
    local player = g_currentMission:getPlayerByConnection(connection)
    if player == nil then return nil end
    return player.farmId
end

--- Maps mode + outcome → cooldown table key.
---@param mode string
---@param outcome string
---@return string|nil key
local function getOutcomeCooldownKey(mode, outcome)
    local ENGINE = RmNegotiationEngine
    local MGR = RmNegotiationManager
    local map = {
        [ENGINE.MODE_LISTED_BUY] = {
            [ENGINE.OUTCOME_REJECTED] = "listed_rejected",
            [ENGINE.OUTCOME_FAILED]   = "listed_failed",
            [MGR.OUTCOME_WALKAWAY]    = "listed_walkaway",
        },
        [ENGINE.MODE_UNLISTED_BUY] = {
            [ENGINE.OUTCOME_DISMISSED] = "unlisted_dismissed",
            [ENGINE.OUTCOME_REJECTED]  = "unlisted_rejected",
            [ENGINE.OUTCOME_FAILED]    = "unlisted_failed",
            [MGR.OUTCOME_WALKAWAY]     = "unlisted_walkaway",
        },
        [ENGINE.MODE_SELL] = {
            [ENGINE.OUTCOME_NPC_WALKED] = "selling_npc_walked",
            [MGR.OUTCOME_WALKAWAY]      = "selling_walkaway",
        },
    }
    local modeMap = map[mode]
    return modeMap and modeMap[outcome] or nil
end

--- Sets cooldown based on preset + outcome.
---@param farmlandId number
---@param farmId number
---@param mode string
---@param outcome string
local function applyCooldown(farmlandId, farmId, mode, outcome)
    local key = getOutcomeCooldownKey(mode, outcome)
    if key == nil then return end
    local preset = getPreset()
    local periods = RmNegotiationManager.COOLDOWNS[key]
    if periods == nil then return end
    local remaining = periods[preset] or 0
    if remaining <= 0 then return end
    if RmNegotiationManager.cooldowns[farmlandId] == nil then
        RmNegotiationManager.cooldowns[farmlandId] = {}
    end
    RmNegotiationManager.cooldowns[farmlandId][farmId] = {
        remaining = remaining,
        lastOutcome = outcome,
    }
    Log:debug("COOLDOWN: farmland %d farm %d = %d periods (%s)", farmlandId, farmId, remaining, outcome)
end

--- Builds sanitized snapshot (public function for testing).
---@param session table|nil
---@return table|nil snapshot
function RmNegotiationManager.createSnapshot(session)
    if session == nil then return nil end
    -- Deep copy offers to avoid shared reference with live session
    local offersCopy = {}
    for i, entry in ipairs(session.offers) do
        local copy = { round = entry.round }
        if entry.offer then copy.offer = entry.offer end
        if entry.counter then copy.counter = entry.counter end
        if entry.npcOffer then copy.npcOffer = entry.npcOffer end
        if entry.playerAsk then copy.playerAsk = entry.playerAsk end
        if entry.npcResponse then copy.npcResponse = entry.npcResponse end
        offersCopy[i] = copy
    end
    return {
        farmlandId = session.farmlandId,
        mode = session.mode,
        round = session.round,
        state = session.state,
        lastCounter = session.lastCounter,
        offers = offersCopy,
        pendingProposal = session.pendingProposal and {
            type = session.pendingProposal.type,
            price = session.pendingProposal.price,
            counter = session.pendingProposal.counter,
        } or nil,
        outcome = session.outcome,
        finalPrice = session.finalPrice,
        anchorPrice = session.profile and session.profile.anchorPrice or nil,
        rejectFloor = session.profile and session.profile.rejectFloor or nil,
    }
end

--- Finalizes session, applies cooldown, releases lock.
---@param farmId number
---@param outcome string
---@param price number|nil
---@return table|nil snapshot
local function completeSession(farmId, outcome, price)
    local session = RmNegotiationManager.sessions[farmId]
    if session == nil then return nil end
    session.state = "completed"
    session.outcome = outcome
    session.finalPrice = price

    -- Set pendingDeals for buy deals (bypass availability check in FarmlandStateEvent)
    if outcome == RmNegotiationEngine.OUTCOME_DEAL
       and session.mode ~= RmNegotiationEngine.MODE_SELL then
        RmNegotiationManager.pendingDeals[session.farmlandId] = true
        Log:debug("NEGOTIATION: Set pendingDeals for farmland %d", session.farmlandId)
    end

    -- Apply cooldown (no cooldown for deals)
    if outcome ~= RmNegotiationEngine.OUTCOME_DEAL then
        applyCooldown(session.farmlandId, farmId, session.mode, outcome)
    end
    -- Release lock
    RmNegotiationManager.locks[session.farmlandId] = nil
    -- Build snapshot before clearing session
    local snapshot = RmNegotiationManager.createSnapshot(session)
    -- Clear session
    RmNegotiationManager.sessions[farmId] = nil
    Log:info("NEGOTIATION: Completed farmland %d - %s%s",
        session.farmlandId, outcome, price and string.format(" at $%.0f", price) or "")
    return snapshot
end

-- =============================================================================
-- PUBLIC API - canNegotiate
-- =============================================================================

---@param farmlandId number
---@param farmId number
---@return boolean canNegotiate
---@return string|nil reason If false, why not
function RmNegotiationManager.canNegotiate(farmlandId, farmId)
    Log:trace(">>> canNegotiate(farmlandId=%d, farmId=%d)", farmlandId, farmId)
    -- 1. Valid farmland?
    if g_farmlandManager:getFarmlandById(farmlandId) == nil then
        Log:trace("<<< canNegotiate = false (invalid_farmland)")
        return false, "invalid_farmland"
    end
    -- 2. Lock check: locked by someone else?
    local lockHolder = RmNegotiationManager.locks[farmlandId]
    if lockHolder ~= nil and lockHolder ~= farmId then
        Log:trace("<<< canNegotiate = false (locked by farm %d)", lockHolder)
        return false, "locked"
    end
    -- 3. Cooldown check
    local cdFarmland = RmNegotiationManager.cooldowns[farmlandId]
    if cdFarmland ~= nil and cdFarmland[farmId] ~= nil and cdFarmland[farmId].remaining > 0 then
        Log:trace("<<< canNegotiate = false (cooldown %d periods)", cdFarmland[farmId].remaining)
        return false, "cooldown"
    end
    Log:trace("<<< canNegotiate = true")
    return true
end

-- =============================================================================
-- PUBLIC API - Start Functions (with host/client routing)
-- =============================================================================

--- Internal: execute startListedBuy on host
---@param farmlandId number
---@param farmId number
---@return table|nil snapshot
---@return string|nil errorReason
local function doStartListedBuy(farmlandId, farmId)
    Log:trace(">>> doStartListedBuy(farmlandId=%d, farmId=%d)", farmlandId, farmId)
    -- Validate
    local canNeg, reason = RmNegotiationManager.canNegotiate(farmlandId, farmId)
    if not canNeg then return nil, reason end
    local farmland = g_farmlandManager:getFarmlandById(farmlandId)
    if farmland == nil then return nil, "invalid_farmland" end
    if farmland.farmId == farmId then return nil, "own_farmland" end
    -- Cancel any existing session for this farm (no cooldown)
    RmNegotiationManager.cancelSession(farmId)
    -- Get or generate seller profile
    local profile = RmNegotiationManager.sellerProfiles[farmlandId]
    if profile == nil then
        local marketValue = getMarketValue(farmlandId)
        if marketValue == nil or marketValue <= 0 then return nil, "invalid_market_value" end
        profile = RmNegotiationEngine.generateListedSeller(getPreset(), marketValue)
        if profile == nil then return nil, "profile_generation_failed" end
        RmNegotiationManager.sellerProfiles[farmlandId] = profile
        Log:debug("NEGOTIATION: Cached new listed seller profile for farmland %d", farmlandId)
    else
        Log:debug("NEGOTIATION: Reusing cached seller profile for farmland %d", farmlandId)
    end
    -- Create session
    RmNegotiationManager.sessions[farmId] = {
        farmlandId = farmlandId,
        farmId = farmId,
        mode = RmNegotiationEngine.MODE_LISTED_BUY,
        profile = profile,
        round = 1,
        state = "active",
        lastCounter = nil,
        offers = {},
        pendingProposal = nil,
        outcome = nil,
        finalPrice = nil,
    }
    -- Acquire lock
    RmNegotiationManager.locks[farmlandId] = farmId
    Log:info("NEGOTIATION: Started listed buy on farmland %d (listing=%.0f)", farmlandId, profile.anchorPrice)
    return RmNegotiationManager.createSnapshot(RmNegotiationManager.sessions[farmId])
end

--- Start a listed buy negotiation.
---@param farmlandId number
---@param farmId number
---@return table|nil snapshot
---@return string|nil errorReason
function RmNegotiationManager.startListedBuy(farmlandId, farmId)
    if g_server ~= nil then
        return doStartListedBuy(farmlandId, farmId)
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(
            RmNegotiationRequestEvent.new("start_listed", farmlandId, 0, false, "")
        )
        return nil, "pending"
    end
end

--- Internal: execute startUnlistedBuy on host
---@param farmlandId number
---@param farmId number
---@return table|nil snapshot
---@return string|nil errorReason
local function doStartUnlistedBuy(farmlandId, farmId)
    Log:trace(">>> doStartUnlistedBuy(farmlandId=%d, farmId=%d)", farmlandId, farmId)
    -- Validate
    local canNeg, reason = RmNegotiationManager.canNegotiate(farmlandId, farmId)
    if not canNeg then return nil, reason end
    local farmland = g_farmlandManager:getFarmlandById(farmlandId)
    if farmland == nil then return nil, "invalid_farmland" end
    if farmland.farmId == farmId then return nil, "own_farmland" end
    -- Cancel any existing session
    RmNegotiationManager.cancelSession(farmId)
    -- Generate fresh profile (unlisted = new person each time)
    local marketValue = getMarketValue(farmlandId)
    if marketValue == nil or marketValue <= 0 then return nil, "invalid_market_value" end
    local result = RmNegotiationEngine.generateUnlistedSeller(getPreset(), marketValue)
    if result == nil then return nil, "profile_generation_failed" end
    -- Check dismissal
    if result.dismissed then
        Log:info("NEGOTIATION: Dismissed by unlisted seller farmland %d", farmlandId)
        applyCooldown(farmlandId, farmId, RmNegotiationEngine.MODE_UNLISTED_BUY, RmNegotiationEngine.OUTCOME_DISMISSED)
        -- Return a completed snapshot with dismissed outcome
        return {
            farmlandId = farmlandId,
            mode = RmNegotiationEngine.MODE_UNLISTED_BUY,
            round = 0,
            state = "completed",
            lastCounter = nil,
            offers = {},
            pendingProposal = nil,
            outcome = RmNegotiationEngine.OUTCOME_DISMISSED,
            finalPrice = nil,
            anchorPrice = nil,
            rejectFloor = nil,
        }
    end
    -- Create session
    RmNegotiationManager.sessions[farmId] = {
        farmlandId = farmlandId,
        farmId = farmId,
        mode = RmNegotiationEngine.MODE_UNLISTED_BUY,
        profile = result,
        round = 1,
        state = "active",
        lastCounter = nil,
        offers = {},
        pendingProposal = nil,
        outcome = nil,
        finalPrice = nil,
    }
    -- Acquire lock
    RmNegotiationManager.locks[farmlandId] = farmId
    Log:info("NEGOTIATION: Started unlisted buy on farmland %d (demand=%.0f)", farmlandId, result.anchorPrice)
    return RmNegotiationManager.createSnapshot(RmNegotiationManager.sessions[farmId])
end

--- Start an unlisted buy negotiation.
---@param farmlandId number
---@param farmId number
---@return table|nil snapshot
---@return string|nil errorReason
function RmNegotiationManager.startUnlistedBuy(farmlandId, farmId)
    if g_server ~= nil then
        return doStartUnlistedBuy(farmlandId, farmId)
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(
            RmNegotiationRequestEvent.new("start_unlisted", farmlandId, 0, false, "")
        )
        return nil, "pending"
    end
end

--- Internal: execute startSell on host
---@param farmlandId number
---@param farmId number
---@param listingPrice number Player's listing price (must be > 0)
---@return table|nil snapshot
---@return string|nil errorReason
local function doStartSell(farmlandId, farmId, listingPrice)
    Log:trace(">>> doStartSell(farmlandId=%d, farmId=%d, listingPrice=%.0f)", farmlandId, farmId, listingPrice)
    -- Validate listing price
    if type(listingPrice) ~= "number" or listingPrice <= 0 then
        return nil, "invalid_listing_price"
    end
    -- Validate
    local canNeg, reason = RmNegotiationManager.canNegotiate(farmlandId, farmId)
    if not canNeg then return nil, reason end
    local farmland = g_farmlandManager:getFarmlandById(farmlandId)
    if farmland == nil then return nil, "invalid_farmland" end
    if farmland.farmId ~= farmId then return nil, "not_owned" end
    -- Cancel any existing session
    RmNegotiationManager.cancelSession(farmId)
    -- Get market value (server-authoritative)
    local marketValue = getMarketValue(farmlandId)
    if marketValue == nil or marketValue <= 0 then return nil, "invalid_market_value" end
    -- Generate NPC buyer using player's listing price
    local buyerProfile = RmNegotiationEngine.generateNpcBuyer(listingPrice, marketValue)
    if buyerProfile == nil then return nil, "profile_generation_failed" end
    -- Create session
    RmNegotiationManager.sessions[farmId] = {
        farmlandId = farmlandId,
        farmId = farmId,
        mode = RmNegotiationEngine.MODE_SELL,
        profile = buyerProfile,
        round = 1,
        state = "active",
        lastCounter = buyerProfile.npcOpening,
        offers = {},
        pendingProposal = nil,
        outcome = nil,
        finalPrice = nil,
    }
    -- Acquire lock
    RmNegotiationManager.locks[farmlandId] = farmId
    Log:info("NEGOTIATION: Started sell on farmland %d (listing=%.0f, NPC opening=%.0f)",
        farmlandId, listingPrice, buyerProfile.npcOpening)
    return RmNegotiationManager.createSnapshot(RmNegotiationManager.sessions[farmId])
end

--- Start a sell negotiation.
---@param farmlandId number
---@param farmId number
---@param listingPrice number Player's listing price
---@return table|nil snapshot
---@return string|nil errorReason
function RmNegotiationManager.startSell(farmlandId, farmId, listingPrice)
    if g_server ~= nil then
        return doStartSell(farmlandId, farmId, listingPrice)
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(
            RmNegotiationRequestEvent.new("start_sell", farmlandId, listingPrice, false, "")
        )
        return nil, "pending"
    end
end

-- =============================================================================
-- PUBLIC API - Action Functions (with host/client routing)
-- =============================================================================

--- Internal: execute submitOffer on host
---@param farmId number
---@param amount number
---@return table|nil snapshot
---@return string|nil errorReason
local function doSubmitOffer(farmId, amount)
    Log:trace(">>> doSubmitOffer(farmId=%d, amount=%.0f)", farmId, amount)
    local session = RmNegotiationManager.sessions[farmId]
    if session == nil then return nil, "no_session" end
    if session.state ~= "active" then return nil, "not_active" end
    if session.mode == RmNegotiationEngine.MODE_SELL then return nil, "wrong_mode" end
    if type(amount) ~= "number" or amount <= 0 then return nil, "invalid_amount" end

    local maxRounds = RmNegotiationEngine.getMaxRounds()

    -- Round exhausted restriction (round > maxRounds)
    if session.round > maxRounds then
        if session.lastCounter ~= nil and amount >= session.lastCounter then
            -- Accept the seller's standing counter-offer
            return completeSession(farmId, RmNegotiationEngine.OUTCOME_DEAL, session.lastCounter)
        else
            return nil, "rounds_exhausted"
        end
    end

    -- Call engine
    local result = RmNegotiationEngine.evaluateOffer(session.profile, amount, session.round)
    if result == nil then return nil, "engine_error" end

    -- Record offer
    table.insert(session.offers, { round = session.round, offer = amount, counter = nil })
    local lastOfferIdx = #session.offers

    -- Handle result
    if result.action == "accepted" then
        return completeSession(farmId, RmNegotiationEngine.OUTCOME_DEAL, result.price)
    elseif result.action == "rejected" then
        return completeSession(farmId, RmNegotiationEngine.OUTCOME_REJECTED, nil)
    elseif result.action == "converged_offer" then
        local counter = result.counter
        -- Monotonic: seller counter must not exceed previous counter
        if session.lastCounter ~= nil and counter >= session.lastCounter then
            local gap = session.lastCounter - amount
            local step = math.max(math.floor(gap * 0.01), 1)
            counter = math.max(session.lastCounter - step, amount + 1)
        end
        session.state = "proposal"
        session.pendingProposal = {
            type = "convergence",
            price = result.price,
            counter = counter,
        }
        session.offers[lastOfferIdx].counter = counter
        return RmNegotiationManager.createSnapshot(session)
    elseif result.action == "countered" then
        local counter = result.counter
        -- Monotonic: seller counter must not exceed previous counter
        if session.lastCounter ~= nil and counter >= session.lastCounter then
            local gap = session.lastCounter - amount
            local step = math.max(math.floor(gap * 0.01), 1)
            counter = math.max(session.lastCounter - step, amount + 1)
        end
        session.offers[lastOfferIdx].counter = counter
        session.lastCounter = counter
        session.round = session.round + 1
        return RmNegotiationManager.createSnapshot(session)
    end

    return nil, "unexpected_result"
end

--- Submit a buy offer.
---@param farmId number
---@param amount number Player's offer
---@return table|nil snapshot
---@return string|nil errorReason
function RmNegotiationManager.submitOffer(farmId, amount)
    if g_server ~= nil then
        return doSubmitOffer(farmId, amount)
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(
            RmNegotiationRequestEvent.new("offer", 0, amount, false, "")
        )
        return nil, "pending"
    end
end

--- Internal: execute submitAsk on host
---@param farmId number
---@param amount number
---@return table|nil snapshot
---@return string|nil errorReason
local function doSubmitAsk(farmId, amount)
    Log:trace(">>> doSubmitAsk(farmId=%d, amount=%.0f)", farmId, amount)
    local session = RmNegotiationManager.sessions[farmId]
    if session == nil then return nil, "no_session" end
    if session.state ~= "active" then return nil, "not_active" end
    if session.mode ~= RmNegotiationEngine.MODE_SELL then return nil, "wrong_mode" end
    if type(amount) ~= "number" or amount <= 0 then return nil, "invalid_amount" end

    local maxRounds = RmNegotiationEngine.getMaxRounds()

    -- Round exhausted restriction
    if session.round > maxRounds then
        if session.lastCounter ~= nil and amount <= session.lastCounter then
            -- Accept the NPC's standing offer
            return completeSession(farmId, RmNegotiationEngine.OUTCOME_DEAL, session.lastCounter)
        else
            return nil, "rounds_exhausted"
        end
    end

    -- Call engine
    local result = RmNegotiationEngine.evaluatePlayerAsk(session.profile, amount, session.round)
    if result == nil then return nil, "engine_error" end

    -- Record offer (npcResponse filled in below based on result)
    table.insert(session.offers, { round = session.round, npcOffer = session.lastCounter, playerAsk = amount, npcResponse = nil })
    local lastOfferIdx = #session.offers

    -- Handle result
    if result.action == "accepted" then
        session.offers[lastOfferIdx].npcResponse = result.price
        return completeSession(farmId, RmNegotiationEngine.OUTCOME_DEAL, result.price)
    elseif result.action == "npc_walked" then
        return completeSession(farmId, RmNegotiationEngine.OUTCOME_NPC_WALKED, nil)
    elseif result.action == "converged_offer" then
        local npcOffer = result.npcOffer
        -- Monotonic: NPC buyer offer must not drop below previous offer
        if session.lastCounter ~= nil and npcOffer <= session.lastCounter then
            local gap = amount - session.lastCounter
            local step = math.max(math.floor(gap * 0.01), 1)
            npcOffer = math.min(session.lastCounter + step, amount - 1)
        end
        session.offers[lastOfferIdx].npcResponse = npcOffer
        session.state = "proposal"
        session.pendingProposal = {
            type = "convergence",
            price = result.price,
            counter = npcOffer,
        }
        return RmNegotiationManager.createSnapshot(session)
    elseif result.action == "countered" then
        local npcOffer = result.npcOffer
        -- Monotonic: NPC buyer offer must not drop below previous offer
        if session.lastCounter ~= nil and npcOffer <= session.lastCounter then
            local gap = amount - session.lastCounter
            local step = math.max(math.floor(gap * 0.01), 1)
            npcOffer = math.min(session.lastCounter + step, amount - 1)
        end
        session.offers[lastOfferIdx].npcResponse = npcOffer
        session.lastCounter = npcOffer
        session.round = session.round + 1
        return RmNegotiationManager.createSnapshot(session)
    end

    return nil, "unexpected_result"
end

--- Submit a sell ask.
---@param farmId number
---@param amount number Player's asking price
---@return table|nil snapshot
---@return string|nil errorReason
function RmNegotiationManager.submitAsk(farmId, amount)
    if g_server ~= nil then
        return doSubmitAsk(farmId, amount)
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(
            RmNegotiationRequestEvent.new("ask", 0, amount, false, "")
        )
        return nil, "pending"
    end
end

--- Internal: execute walkaway on host
---@param farmId number
---@return table|nil snapshot
---@return string|nil errorReason
local function doWalkaway(farmId)
    Log:trace(">>> doWalkaway(farmId=%d)", farmId)
    local session = RmNegotiationManager.sessions[farmId]
    if session == nil then return nil, "no_session" end
    if session.state ~= "active" then return nil, "not_active" end

    local maxRounds = RmNegotiationEngine.getMaxRounds()
    local cappedRound = math.min(session.round, maxRounds)

    if session.mode == RmNegotiationEngine.MODE_SELL then
        -- Sell walkaway
        local lastNpcOffer = session.lastCounter or 0
        local lastPlayerAsk = 0
        if #session.offers > 0 then
            lastPlayerAsk = session.offers[#session.offers].playerAsk or 0
        end
        local result = RmNegotiationEngine.evaluateSellWalkaway(
            session.profile, lastNpcOffer, lastPlayerAsk, cappedRound)
        if result ~= nil and result.action == "last_ditch_offer" then
            session.state = "proposal"
            session.pendingProposal = { type = "last_ditch", price = result.price }
            return RmNegotiationManager.createSnapshot(session)
        end
        return completeSession(farmId, RmNegotiationManager.OUTCOME_WALKAWAY, nil)
    else
        -- Buy walkaway
        local lastOffer = 0
        if #session.offers > 0 then
            lastOffer = session.offers[#session.offers].offer or 0
        end
        local result = RmNegotiationEngine.evaluateWalkaway(
            session.profile, lastOffer, cappedRound)
        if result ~= nil and result.action == "last_ditch_offer" then
            session.state = "proposal"
            session.pendingProposal = { type = "last_ditch", price = result.price }
            return RmNegotiationManager.createSnapshot(session)
        end
        return completeSession(farmId, RmNegotiationManager.OUTCOME_WALKAWAY, nil)
    end
end

--- Player walks away from negotiation.
---@param farmId number
---@return table|nil snapshot
---@return string|nil errorReason
function RmNegotiationManager.walkaway(farmId)
    if g_server ~= nil then
        return doWalkaway(farmId)
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(
            RmNegotiationRequestEvent.new("walkaway", 0, 0, false, "")
        )
        return nil, "pending"
    end
end

--- Internal: execute respondToProposal on host
---@param farmId number
---@param accept boolean
---@return table|nil snapshot
---@return string|nil errorReason
local function doRespondToProposal(farmId, accept)
    Log:trace(">>> doRespondToProposal(farmId=%d, accept=%s)", farmId, tostring(accept))
    local session = RmNegotiationManager.sessions[farmId]
    if session == nil then return nil, "no_session" end
    if session.state ~= "proposal" then return nil, "not_proposal" end
    if session.pendingProposal == nil then return nil, "no_proposal" end

    if accept then
        return completeSession(farmId, RmNegotiationEngine.OUTCOME_DEAL, session.pendingProposal.price)
    end

    -- Decline
    if session.pendingProposal.type == "convergence" then
        session.state = "active"
        session.lastCounter = session.pendingProposal.counter
        session.pendingProposal = nil
        session.round = session.round + 1
        return RmNegotiationManager.createSnapshot(session)
    elseif session.pendingProposal.type == "last_ditch" then
        return completeSession(farmId, RmNegotiationManager.OUTCOME_WALKAWAY, nil)
    end

    return nil, "unexpected_proposal_type"
end

--- Accept or decline a convergence/last-ditch proposal.
---@param farmId number
---@param accept boolean
---@return table|nil snapshot
---@return string|nil errorReason
function RmNegotiationManager.respondToProposal(farmId, accept)
    if g_server ~= nil then
        return doRespondToProposal(farmId, accept)
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(
            RmNegotiationRequestEvent.new("respond", 0, 0, accept, "")
        )
        return nil, "pending"
    end
end

--- Cancel session without cooldown.
---@param farmId number
---@return boolean success
function RmNegotiationManager.cancelSession(farmId)
    local session = RmNegotiationManager.sessions[farmId]
    if session == nil then return false end
    -- Release lock
    RmNegotiationManager.locks[session.farmlandId] = nil
    -- Clear session (no cooldown)
    RmNegotiationManager.sessions[farmId] = nil
    Log:debug("NEGOTIATION: Cancelled session for farm %d", farmId)
    return true
end

--- Get sanitized snapshot of current session.
---@param farmId number
---@return table|nil snapshot
function RmNegotiationManager.getSession(farmId)
    return RmNegotiationManager.createSnapshot(RmNegotiationManager.sessions[farmId])
end

--- Get cooldown info for display purposes.
---@param farmlandId number
---@param farmId number
---@return table|nil cooldownInfo { remaining=N, lastOutcome=string } or nil
function RmNegotiationManager.getCooldownInfo(farmlandId, farmId)
    if RmNegotiationManager.cooldowns[farmlandId] == nil then return nil end
    return RmNegotiationManager.cooldowns[farmlandId][farmId]
end

-- =============================================================================
-- PERIOD CHANGE HANDLER
-- =============================================================================

function RmNegotiationManager.onPeriodChanged()
    if g_server == nil then return end
    local expired = 0
    for farmlandId, farms in pairs(RmNegotiationManager.cooldowns) do
        for farmId, cd in pairs(farms) do
            cd.remaining = cd.remaining - 1
            if cd.remaining <= 0 then
                farms[farmId] = nil
                expired = expired + 1
            end
        end
        if next(farms) == nil then
            RmNegotiationManager.cooldowns[farmlandId] = nil
        end
    end
    if expired > 0 then
        Log:debug("COOLDOWN: %d cooldowns expired on period change", expired)
    end

    -- Safety net: clear any stale pendingDeals (should be empty, but defensive)
    if next(RmNegotiationManager.pendingDeals) ~= nil then
        Log:warning("Clearing stale pendingDeals entries")
        RmNegotiationManager.pendingDeals = {}
    end
end

-- =============================================================================
-- OWNERSHIP CHANGE HOOK
-- =============================================================================

function RmNegotiationManager.onOwnershipChanged(farmlandId)
    -- Clear negotiated deal bypass flag (listen server fires event twice)
    RmNegotiationManager.pendingDeals[farmlandId] = nil
    -- Clear cached seller profile
    RmNegotiationManager.sellerProfiles[farmlandId] = nil
    -- Clear all cooldowns for this farmland
    RmNegotiationManager.cooldowns[farmlandId] = nil
    -- Release lock
    RmNegotiationManager.locks[farmlandId] = nil
    -- Cancel any active sessions for this farmland
    for farmId, session in pairs(RmNegotiationManager.sessions) do
        if session.farmlandId == farmlandId then
            RmNegotiationManager.sessions[farmId] = nil
        end
    end
    Log:debug("OWNERSHIP: Cleared negotiation state for farmland %d", farmlandId)
end

-- =============================================================================
-- LISTING PRICE SUPPORT
-- =============================================================================

--- Ensure all listed fields have cached seller profiles and listing prices.
--- Generates profiles for any listed field that doesn't have one yet, and
--- writes listingPrice onto availability entries for sync to clients.
--- Server-only: profile generation involves randomness, must be authoritative.
function RmNegotiationManager.ensureListedProfiles()
    if g_server == nil then return end

    local generated = 0
    for farmlandId, entry in pairs(RmFmAvailability.availability) do
        if entry.isForSale then
            local profile = RmNegotiationManager.sellerProfiles[farmlandId]
            if profile == nil then
                local marketValue = getMarketValue(farmlandId)
                if marketValue ~= nil and marketValue > 0 then
                    profile = RmNegotiationEngine.generateListedSeller(getPreset(), marketValue)
                    if profile ~= nil then
                        RmNegotiationManager.sellerProfiles[farmlandId] = profile
                        generated = generated + 1
                    end
                end
            end
            -- Write listing price onto availability entry (synced to clients)
            if profile ~= nil then
                entry.listingPrice = math.floor(profile.anchorPrice)
            end
        else
            entry.listingPrice = nil
        end
    end
    if generated > 0 then
        Log:info("NEGOTIATION: Generated %d seller profiles for listed fields", generated)
    end
end

--- Get the listing price for a farmland (works on both server and client).
--- Server: reads from cached seller profile.
--- Client: reads from synced availability entry.
---@param farmlandId number
---@return number|nil listingPrice
function RmNegotiationManager.getListingPrice(farmlandId)
    -- Server: authoritative profile data
    local profile = RmNegotiationManager.sellerProfiles[farmlandId]
    if profile ~= nil then
        return profile.anchorPrice
    end
    -- Client fallback: synced listing price on availability entry
    local entry = RmFmAvailability.availability[farmlandId]
    if entry ~= nil and entry.listingPrice ~= nil and entry.listingPrice > 0 then
        return entry.listingPrice
    end
    return nil
end

-- =============================================================================
-- LIFECYCLE FUNCTIONS
-- =============================================================================

--- Initialize manager (called from BaseMission.loadMapFinished)
function RmNegotiationManager.initialize()
    Log:trace(">>> RmNegotiationManager.initialize()")
    if g_server == nil then
        Log:trace("<<< initialize() [not server]")
        return
    end
    -- Subscribe to period changes
    g_messageCenter:subscribe(MessageType.PERIOD_CHANGED, RmNegotiationManager.onPeriodChanged, RmNegotiationManager)
    -- Register console commands
    addConsoleCommand("fmNegotiate", "Start negotiation on farmland (fmNegotiate <farmlandId>)",
        "consoleStartNegotiation", RmNegotiationManager)
    addConsoleCommand("fmSell", "Sell farmland (fmSell <farmlandId> [listingPrice])",
        "consoleSell", RmNegotiationManager)
    addConsoleCommand("fmOffer", "Submit offer/ask (fmOffer <amount>)",
        "consoleOffer", RmNegotiationManager)
    addConsoleCommand("fmWalkaway", "Walk away from negotiation",
        "consoleWalkaway", RmNegotiationManager)
    addConsoleCommand("fmRespond", "Respond to proposal (fmRespond accept|decline)",
        "consoleRespond", RmNegotiationManager)
    addConsoleCommand("fmCancel", "Cancel current negotiation",
        "consoleCancel", RmNegotiationManager)
    addConsoleCommand("fmSession", "Show current negotiation session",
        "consoleSession", RmNegotiationManager)
    addConsoleCommand("fmCooldowns", "Show active cooldowns",
        "consoleCooldowns", RmNegotiationManager)
    Log:debug("NegotiationManager initialized")
    Log:trace("<<< RmNegotiationManager.initialize()")
end

--- Cleanup manager (called from BaseMission.delete)
function RmNegotiationManager.cleanup()
    Log:trace(">>> RmNegotiationManager.cleanup()")
    -- Unsubscribe from period changes
    g_messageCenter:unsubscribe(MessageType.PERIOD_CHANGED, RmNegotiationManager)
    -- Remove console commands
    removeConsoleCommand("fmNegotiate")
    removeConsoleCommand("fmSell")
    removeConsoleCommand("fmOffer")
    removeConsoleCommand("fmWalkaway")
    removeConsoleCommand("fmRespond")
    removeConsoleCommand("fmCancel")
    removeConsoleCommand("fmSession")
    removeConsoleCommand("fmCooldowns")
    -- Clear state tables
    RmNegotiationManager.sessions = {}
    RmNegotiationManager.cooldowns = {}
    RmNegotiationManager.locks = {}
    RmNegotiationManager.sellerProfiles = {}
    RmNegotiationManager.pendingDeals = {}
    Log:debug("NegotiationManager cleaned up")
    Log:trace("<<< RmNegotiationManager.cleanup()")
end

-- =============================================================================
-- PERSISTENCE
-- =============================================================================

--- Save negotiation state (profiles + cooldowns) to savegame XML
---@param xmlFile table Already-opened XMLFile handle
function RmNegotiationManager.saveToXMLFile(xmlFile)
    Log:trace(">>> RmNegotiationManager.saveToXMLFile()")

    if g_server == nil then
        Log:trace("  Not server, skipping")
        return
    end

    -- Collect union of farmlandIds from sellerProfiles and cooldowns
    local farmlandIds = {}
    for farmlandId, _ in pairs(RmNegotiationManager.sellerProfiles) do
        farmlandIds[farmlandId] = true
    end
    for farmlandId, _ in pairs(RmNegotiationManager.cooldowns) do
        farmlandIds[farmlandId] = true
    end

    local key = "rmFarmlandMarket.negotiations"
    local i = 0
    local profileCount, cooldownCount = 0, 0

    for farmlandId, _ in pairs(farmlandIds) do
        local entryKey = string.format("%s.farmland(%d)", key, i)
        xmlFile:setValue(entryKey .. "#id", farmlandId)

        -- Write seller profile if exists
        local profile = RmNegotiationManager.sellerProfiles[farmlandId]
        if profile ~= nil then
            local pKey = entryKey .. ".sellerProfile"
            xmlFile:setValue(pKey .. "#mode", profile.mode)
            xmlFile:setValue(pKey .. "#preset", profile.preset)
            xmlFile:setValue(pKey .. "#marketValue", profile.marketValue)
            xmlFile:setValue(pKey .. "#anchorPrice", profile.anchorPrice)
            xmlFile:setValue(pKey .. "#listingPrice", profile.listingPrice)
            xmlFile:setValue(pKey .. "#reservation", profile.reservation)
            xmlFile:setValue(pKey .. "#stubbornness", profile.stubbornness)
            xmlFile:setValue(pKey .. "#rejectFloor", profile.rejectFloor)
            profileCount = profileCount + 1
            Log:trace("  NEG: Saved profile for farmland %d (mode=%s)", farmlandId, profile.mode)
        end

        -- Write cooldowns if exist
        local farms = RmNegotiationManager.cooldowns[farmlandId]
        if farms ~= nil then
            local j = 0
            for farmId, cd in pairs(farms) do
                if cd.remaining > 0 then
                    local cdKey = string.format("%s.cooldown(%d)", entryKey, j)
                    xmlFile:setValue(cdKey .. "#farmId", farmId)
                    xmlFile:setValue(cdKey .. "#remaining", cd.remaining)
                    xmlFile:setValue(cdKey .. "#lastOutcome", cd.lastOutcome)
                    cooldownCount = cooldownCount + 1
                    j = j + 1
                end
            end
        end

        i = i + 1
    end

    Log:debug("NEG: Saved %d profiles, %d cooldowns across %d farmlands", profileCount, cooldownCount, i)
    Log:debug("Negotiation state saved")
    Log:trace("<<< RmNegotiationManager.saveToXMLFile()")
end

--- Load negotiation state (profiles + cooldowns) from savegame XML
---@param xmlFile table Already-opened XMLFile handle
function RmNegotiationManager.loadFromXMLFile(xmlFile)
    Log:trace(">>> RmNegotiationManager.loadFromXMLFile()")

    if g_server == nil then
        Log:trace("<<< loadFromXMLFile() [not server]")
        return
    end

    local key = "rmFarmlandMarket.negotiations"
    local i = 0
    local profileCount, cooldownCount = 0, 0

    while true do
        local entryKey = string.format("%s.farmland(%d)", key, i)
        if not xmlFile:hasProperty(entryKey) then
            break
        end

        local farmlandId = xmlFile:getValue(entryKey .. "#id")
        if farmlandId ~= nil then
            -- Load seller profile if present
            local pKey = entryKey .. ".sellerProfile"
            if xmlFile:hasProperty(pKey) then
                local mode = xmlFile:getValue(pKey .. "#mode")
                local preset = xmlFile:getValue(pKey .. "#preset")
                local marketValue = xmlFile:getValue(pKey .. "#marketValue")
                local anchorPrice = xmlFile:getValue(pKey .. "#anchorPrice")
                local listingPrice = xmlFile:getValue(pKey .. "#listingPrice")
                local reservation = xmlFile:getValue(pKey .. "#reservation")
                local stubbornness = xmlFile:getValue(pKey .. "#stubbornness")
                local rejectFloor = xmlFile:getValue(pKey .. "#rejectFloor")

                -- Validate critical fields before storing
                if mode ~= nil and anchorPrice ~= nil and reservation ~= nil
                        and stubbornness ~= nil and rejectFloor ~= nil then
                    RmNegotiationManager.sellerProfiles[farmlandId] = {
                        mode = mode,
                        preset = preset,
                        marketValue = marketValue,
                        anchorPrice = anchorPrice,
                        listingPrice = listingPrice,
                        reservation = reservation,
                        stubbornness = stubbornness,
                        rejectFloor = rejectFloor,
                    }
                    profileCount = profileCount + 1
                    Log:trace("  NEG: Loaded profile for farmland %d (mode=%s)", farmlandId, tostring(mode))
                else
                    Log:warning("NEG: Skipping corrupt profile for farmland %d (missing fields)", farmlandId)
                end
            end

            -- Load cooldowns if present
            local j = 0
            while true do
                local cdKey = string.format("%s.cooldown(%d)", entryKey, j)
                if not xmlFile:hasProperty(cdKey) then
                    break
                end

                local farmId = xmlFile:getValue(cdKey .. "#farmId")
                local remaining = xmlFile:getValue(cdKey .. "#remaining")
                local lastOutcome = xmlFile:getValue(cdKey .. "#lastOutcome")

                -- Skip expired cooldowns
                if farmId ~= nil and remaining ~= nil and remaining > 0 then
                    if RmNegotiationManager.cooldowns[farmlandId] == nil then
                        RmNegotiationManager.cooldowns[farmlandId] = {}
                    end
                    RmNegotiationManager.cooldowns[farmlandId][farmId] = {
                        remaining = remaining,
                        lastOutcome = lastOutcome,
                    }
                    cooldownCount = cooldownCount + 1
                    Log:trace("  NEG: Loaded cooldown farmland %d farm %d remaining=%d outcome=%s",
                        farmlandId, farmId, remaining, tostring(lastOutcome))
                end

                j = j + 1
            end
        end

        i = i + 1
    end

    Log:debug("NEG: Loaded %d profiles, %d cooldowns from %d farmland entries", profileCount, cooldownCount, i)
    Log:debug("Negotiation state loaded")
    Log:trace("<<< RmNegotiationManager.loadFromXMLFile()")
end

-- =============================================================================
-- CONSOLE COMMANDS (server-only for Chunk A)
-- =============================================================================

--- Console: Start negotiation
---@param farmlandIdStr string
---@return string output
function RmNegotiationManager:consoleStartNegotiation(farmlandIdStr)
    local farmlandId = tonumber(farmlandIdStr)
    if farmlandId == nil then return "Usage: fmNegotiate <farmlandId>" end
    local farmId = g_currentMission:getFarmId()
    -- Auto-detect mode
    local snapshot, err
    if RmFmAvailability.isForSale(farmlandId) then
        snapshot, err = RmNegotiationManager.startListedBuy(farmlandId, farmId)
    else
        snapshot, err = RmNegotiationManager.startUnlistedBuy(farmlandId, farmId)
    end
    if snapshot == nil then
        return string.format("Failed: %s", tostring(err))
    end
    if snapshot.outcome == RmNegotiationEngine.OUTCOME_DISMISSED then
        return string.format("Farmland %d: Seller dismissed your approach. Cooldown active.", farmlandId)
    end
    return string.format("Farmland %d: Negotiation started (%s). Anchor=%.0f RejectFloor=%.0f",
        farmlandId, snapshot.mode, snapshot.anchorPrice or 0, snapshot.rejectFloor or 0)
end

--- Console: Start sell negotiation
---@param farmlandIdStr string
---@param listingPriceStr string|nil
---@return string output
function RmNegotiationManager:consoleSell(farmlandIdStr, listingPriceStr)
    local farmlandId = tonumber(farmlandIdStr)
    if farmlandId == nil then return "Usage: fmSell <farmlandId> [listingPrice]" end
    local farmId = g_currentMission:getFarmId()
    -- Default listing price: 110% of market value (for testing convenience)
    local listingPrice = tonumber(listingPriceStr)
    if listingPrice == nil then
        local farmland = g_farmlandManager:getFarmlandById(farmlandId)
        if farmland == nil then
            return string.format("Farmland %d not found", farmlandId)
        end
        listingPrice = math.floor(farmland.price * 1.1)
    end
    local snapshot, err = RmNegotiationManager.startSell(farmlandId, farmId, listingPrice)
    if snapshot == nil then
        return string.format("Failed: %s", tostring(err))
    end
    return string.format("Farmland %d: Sell started (listing=%.0f). NPC opening bid=%.0f",
        farmlandId, listingPrice, snapshot.lastCounter or 0)
end

--- Console: Submit offer or ask
---@param amountStr string
---@return string output
function RmNegotiationManager:consoleOffer(amountStr)
    local amount = tonumber(amountStr)
    if amount == nil then return "Usage: fmOffer <amount>" end
    local farmId = g_currentMission:getFarmId()
    local session = RmNegotiationManager.sessions[farmId]
    if session == nil then return "No active session" end
    local snapshot, err
    if session.mode == RmNegotiationEngine.MODE_SELL then
        snapshot, err = RmNegotiationManager.submitAsk(farmId, amount)
    else
        snapshot, err = RmNegotiationManager.submitOffer(farmId, amount)
    end
    if snapshot == nil then
        return string.format("Failed: %s", tostring(err))
    end
    if snapshot.outcome == RmNegotiationEngine.OUTCOME_DEAL then
        return string.format("DEAL at $%.0f!", snapshot.finalPrice)
    elseif snapshot.outcome == RmNegotiationEngine.OUTCOME_REJECTED then
        return "REJECTED - offer too low"
    elseif snapshot.outcome == RmNegotiationEngine.OUTCOME_NPC_WALKED then
        return "NPC WALKED AWAY - ask too high"
    elseif snapshot.state == "proposal" then
        return string.format("PROPOSAL (%s): $%.0f - use fmRespond accept|decline",
            snapshot.pendingProposal.type, snapshot.pendingProposal.price)
    else
        return string.format("Round %d - Counter: $%.0f", snapshot.round, snapshot.lastCounter or 0)
    end
end

--- Console: Walk away
---@return string output
function RmNegotiationManager:consoleWalkaway()
    local farmId = g_currentMission:getFarmId()
    local snapshot, err = RmNegotiationManager.walkaway(farmId)
    if snapshot == nil then
        return string.format("Failed: %s", tostring(err))
    end
    if snapshot.state == "proposal" then
        return string.format("LAST-DITCH OFFER: $%.0f - use fmRespond accept|decline",
            snapshot.pendingProposal.price)
    end
    return "Walked away"
end

--- Console: Respond to proposal
---@param responseStr string
---@return string output
function RmNegotiationManager:consoleRespond(responseStr)
    if responseStr == nil then return "Usage: fmRespond accept|decline" end
    local accept = (responseStr == "accept" or responseStr == "yes" or responseStr == "y")
    local farmId = g_currentMission:getFarmId()
    local snapshot, err = RmNegotiationManager.respondToProposal(farmId, accept)
    if snapshot == nil then
        return string.format("Failed: %s", tostring(err))
    end
    if snapshot.outcome == RmNegotiationEngine.OUTCOME_DEAL then
        return string.format("DEAL at $%.0f!", snapshot.finalPrice)
    elseif snapshot.outcome == RmNegotiationManager.OUTCOME_WALKAWAY then
        return "Declined and walked away"
    else
        return string.format("Declined. Round %d - Counter: $%.0f", snapshot.round, snapshot.lastCounter or 0)
    end
end

--- Console: Cancel negotiation
---@return string output
function RmNegotiationManager:consoleCancel()
    local farmId = g_currentMission:getFarmId()
    if RmNegotiationManager.cancelSession(farmId) then
        return "Negotiation cancelled"
    end
    return "No active session to cancel"
end

--- Console: Show current session
---@return string output
function RmNegotiationManager:consoleSession()
    local farmId = g_currentMission:getFarmId()
    local snapshot = RmNegotiationManager.getSession(farmId)
    if snapshot == nil then return "No active session" end
    local parts = {
        string.format("Farmland: %d", snapshot.farmlandId),
        string.format("Mode: %s", snapshot.mode),
        string.format("Round: %d", snapshot.round),
        string.format("State: %s", snapshot.state),
    }
    if snapshot.anchorPrice then
        table.insert(parts, string.format("Anchor: $%.0f", snapshot.anchorPrice))
    end
    if snapshot.rejectFloor then
        table.insert(parts, string.format("Reject Floor: $%.0f", snapshot.rejectFloor))
    end
    if snapshot.lastCounter then
        table.insert(parts, string.format("Last Counter: $%.0f", snapshot.lastCounter))
    end
    if snapshot.pendingProposal then
        table.insert(parts, string.format("Proposal: %s at $%.0f",
            snapshot.pendingProposal.type, snapshot.pendingProposal.price))
    end
    if #snapshot.offers > 0 then
        table.insert(parts, "Offers:")
        for i, o in ipairs(snapshot.offers) do
            if o.offer then
                table.insert(parts, string.format("  R%d: offer=$%.0f counter=%s",
                    o.round, o.offer, o.counter and string.format("$%.0f", o.counter) or "n/a"))
            else
                table.insert(parts, string.format("  R%d: npcOffer=$%.0f ask=$%.0f response=%s",
                    o.round, o.npcOffer or 0, o.playerAsk or 0,
                    o.npcResponse and string.format("$%.0f", o.npcResponse) or "n/a"))
            end
        end
    end
    return table.concat(parts, "\n")
end

--- Console: Show cooldowns
---@return string output
function RmNegotiationManager:consoleCooldowns()
    local parts = {}
    local count = 0
    for farmlandId, farms in pairs(RmNegotiationManager.cooldowns) do
        for farmId, cd in pairs(farms) do
            table.insert(parts, string.format("  Farmland %d / Farm %d: %d periods remaining (%s)",
                farmlandId, farmId, cd.remaining, cd.lastOutcome))
            count = count + 1
        end
    end
    if count == 0 then return "No active cooldowns" end
    table.insert(parts, 1, string.format("Active cooldowns (%d):", count))
    return table.concat(parts, "\n")
end

-- =============================================================================
-- SOURCE-TIME HOOKS
-- =============================================================================

-- Ownership change hook (with savegame load guard)
FarmlandManager.setLandOwnership = Utils.appendedFunction(
    FarmlandManager.setLandOwnership,
    function(self, farmlandId, farmId, loadFromSavegame)
        if not loadFromSavegame then
            RmNegotiationManager.onOwnershipChanged(farmlandId)
        end
    end
)

-- Lifecycle hooks
BaseMission.loadMapFinished = Utils.appendedFunction(
    BaseMission.loadMapFinished,
    RmNegotiationManager.initialize
)

BaseMission.delete = Utils.appendedFunction(
    BaseMission.delete,
    RmNegotiationManager.cleanup
)

Log:debug("RmNegotiationManager module loaded")
