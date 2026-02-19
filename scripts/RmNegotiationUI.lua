--[[
    RmNegotiationUI.lua
    UI controller for farmland negotiation.

    Orchestrates:
    - Buy/sell intercepts on InGameMenuMapFrame
    - Multi-round dialog flow (TextInputDialog, YesNoDialog, InfoDialog)
    - Host/client async result handling
    - Purchase/sale execution via FarmlandStateEvent

    UI reads from session snapshots only - never calls engine directly.
    Works identically in single-player and multiplayer.

    Author: Ritter
]]

-- =============================================================================
-- MODULE DECLARATION
-- =============================================================================

RmNegotiationUI = {}

local Log = RmLogging.getLogger("FarmlandMarket")

-- =============================================================================
-- OUTCOME CONSTANT ASSERTIONS (catch nil references early)
-- =============================================================================

assert(RmNegotiationEngine.OUTCOME_DEAL ~= nil, "OUTCOME_DEAL is nil")
assert(RmNegotiationEngine.OUTCOME_REJECTED ~= nil, "OUTCOME_REJECTED is nil")
assert(RmNegotiationEngine.OUTCOME_DISMISSED ~= nil, "OUTCOME_DISMISSED is nil")
assert(RmNegotiationEngine.OUTCOME_NPC_WALKED ~= nil, "OUTCOME_NPC_WALKED is nil")
assert(RmNegotiationManager.OUTCOME_WALKAWAY ~= nil, "OUTCOME_WALKAWAY is nil")
assert(RmNegotiationEngine.MODE_LISTED_BUY ~= nil, "MODE_LISTED_BUY is nil")
assert(RmNegotiationEngine.MODE_UNLISTED_BUY ~= nil, "MODE_UNLISTED_BUY is nil")
assert(RmNegotiationEngine.MODE_SELL ~= nil, "MODE_SELL is nil")

-- =============================================================================
-- CLIENT-SIDE STATE
-- =============================================================================

-- Callback for pending async results (client-only)
RmNegotiationUI.pendingCallback = nil

-- Current negotiation context (set when flow starts)
RmNegotiationUI.currentFarmlandId = nil
RmNegotiationUI.currentFarmId = nil
RmNegotiationUI.currentMode = nil  -- "listed_buy"|"unlisted_buy"|"sell"

-- =============================================================================
-- FORWARD DECLARATIONS (Lua 5.1: local functions with circular refs)
-- =============================================================================

local handleResult
local showBuyRound
local showBuyAmountInput
local showBuyAcceptOrCounter
local showSellRound
local showSellAmountInput
local showSellAcceptOrCounter
local executeDeal
local showAmountInput

-- =============================================================================
-- INTERNAL HELPERS (local)
-- =============================================================================

--- Call a NegotiationManager API function, handling host/client routing.
--- On host: calls apiFn immediately, invokes onResult with return values.
--- On client: stores onResult as pendingCallback, apiFn returns nil/"pending".
---@param apiFn function The manager API function to call
---@param args table Array of arguments to pass
---@param onResult function Callback: function(snapshot, errorReason)
local function callManagerAPI(apiFn, args, onResult)
    Log:trace(">>> callManagerAPI()")
    local snapshot, errorReason = apiFn(unpack(args))

    if g_server ~= nil then
        -- HOST: immediate result
        Log:trace("  callManagerAPI: host path, immediate result")
        onResult(snapshot, errorReason)
    else
        -- CLIENT: async - result arrives via RmNegotiationResultEvent
        if errorReason == "pending" then
            Log:trace("  callManagerAPI: client path, storing pendingCallback")
            RmNegotiationUI.pendingCallback = onResult
        else
            -- Unexpected: client got immediate result (shouldn't happen)
            Log:warning("callManagerAPI: client got immediate result, dispatching")
            onResult(snapshot, errorReason)
        end
    end
    Log:trace("<<< callManagerAPI()")
end

--- Show an info dialog with a message and optional callback.
---@param text string Dialog message
---@param onClose function|nil Callback when closed
local function showInfo(text, onClose)
    InfoDialog.show(text, onClose or function() end)
end

--- Show a yes/no dialog and invoke callback with boolean.
---@param text string Dialog prompt
---@param onAnswer function Callback: function(accepted)
---@param yesText string|nil Custom yes button text
---@param noText string|nil Custom no button text
local function showYesNo(text, onAnswer, yesText, noText)
    YesNoDialog.show(function(yes)
        onAnswer(yes)
    end, nil, text, nil, yesText, noText)
end

--- Show a text input dialog for entering a monetary amount.
---@param prompt string Dialog prompt
---@param defaultText string Default input value
---@param onInput function Callback: function(amount) - nil if cancelled
---@param confirmText string|nil Custom confirm button text
showAmountInput = function(prompt, defaultText, onInput, confirmText)
    TextInputDialog.show(function(text, confirmed)
        if not confirmed or text == nil or text == "" then
            onInput(nil)
            return
        end
        local amount = tonumber(text)
        if amount == nil or amount <= 0 then
            showInfo(g_i18n:getText("rm_fm_neg_invalidAmount"), function()
                showAmountInput(prompt, defaultText, onInput, confirmText)
            end)
            return
        end
        onInput(math.floor(amount))
    end, nil, defaultText, prompt, nil, 12, confirmText)
end

--- Format a price for display.
---@param amount number
---@return string
local function formatPrice(amount)
    return g_i18n:formatMoney(amount, 0, true, true)
end

-- =============================================================================
-- CORE STATE MACHINE DISPATCHER
-- =============================================================================

--- Process a snapshot after a manager action and show appropriate dialog.
---@param snapshot table|nil Session snapshot
---@param errorReason string|nil Error reason if failed
handleResult = function(snapshot, errorReason)
    Log:trace(">>> handleResult()")

    -- Error case
    if snapshot == nil then
        local msg
        if errorReason == "cooldown" then
            msg = g_i18n:getText("rm_fm_neg_cooldown")
        elseif errorReason == "locked" then
            msg = g_i18n:getText("rm_fm_neg_locked")
        elseif errorReason == "invalid_farmland" then
            msg = g_i18n:getText("rm_fm_neg_invalidFarmland")
        else
            msg = string.format(g_i18n:getText("rm_fm_neg_error"), tostring(errorReason))
        end
        showInfo(msg)
        RmNegotiationUI.clearState()
        Log:trace("<<< handleResult() [error]")
        return
    end

    local state = snapshot.state
    local mode = snapshot.mode
    local outcome = snapshot.outcome

    -- COMPLETED state
    if state == "completed" then
        if outcome == RmNegotiationEngine.OUTCOME_DEAL then
            -- Deal! Execute purchase/sale
            local priceStr = formatPrice(snapshot.finalPrice)
            local msg
            if mode == RmNegotiationEngine.MODE_SELL then
                msg = string.format(g_i18n:getText("rm_fm_neg_dealSell"), priceStr)
            else
                msg = string.format(g_i18n:getText("rm_fm_neg_dealBuy"), priceStr)
            end
            showInfo(msg, function()
                executeDeal(snapshot)
            end)
        elseif outcome == RmNegotiationEngine.OUTCOME_REJECTED then
            showInfo(g_i18n:getText("rm_fm_neg_rejected"))
            RmNegotiationUI.clearState()
        elseif outcome == RmNegotiationEngine.OUTCOME_DISMISSED then
            showInfo(g_i18n:getText("rm_fm_neg_dismissed"))
            RmNegotiationUI.clearState()
        elseif outcome == RmNegotiationEngine.OUTCOME_NPC_WALKED then
            showInfo(g_i18n:getText("rm_fm_neg_npcWalked"))
            RmNegotiationUI.clearState()
        elseif outcome == RmNegotiationManager.OUTCOME_WALKAWAY then
            showInfo(g_i18n:getText("rm_fm_neg_walkedAway"))
            RmNegotiationUI.clearState()
        else
            showInfo(g_i18n:getText("rm_fm_neg_ended"))
            RmNegotiationUI.clearState()
        end
        Log:trace("<<< handleResult() [completed: %s]", outcome)
        return
    end

    -- PROPOSAL state (convergence or last-ditch)
    if state == "proposal" then
        local proposal = snapshot.pendingProposal
        local priceStr = formatPrice(proposal.price)
        local msg, yesText, noText

        if proposal.type == "convergence" then
            msg = string.format(g_i18n:getText("rm_fm_neg_convergence"), priceStr)
            yesText = g_i18n:getText("rm_fm_neg_accept")
            noText = g_i18n:getText("rm_fm_neg_decline")
        else -- "last_ditch"
            msg = string.format(g_i18n:getText("rm_fm_neg_lastDitch"), priceStr)
            yesText = g_i18n:getText("rm_fm_neg_accept")
            noText = g_i18n:getText("rm_fm_neg_walkAway")
        end

        showYesNo(msg, function(accepted)
            callManagerAPI(
                RmNegotiationManager.respondToProposal,
                { RmNegotiationUI.currentFarmId, accepted },
                handleResult
            )
        end, yesText, noText)
        Log:trace("<<< handleResult() [proposal: %s]", proposal.type)
        return
    end

    -- ACTIVE state - show next round input
    if state == "active" then
        if mode == RmNegotiationEngine.MODE_SELL then
            showSellRound(snapshot)
        else
            showBuyRound(snapshot)
        end
        Log:trace("<<< handleResult() [active]")
        return
    end

    Log:warning("handleResult: unexpected state '%s'", tostring(state))
    RmNegotiationUI.clearState()
end

-- =============================================================================
-- BUY ROUND DIALOG
-- =============================================================================

--- Show TextInput for entering a buy offer amount.
---@param snapshot table Session snapshot
---@param prompt string Dialog prompt text
showBuyAmountInput = function(snapshot, prompt)
    showAmountInput(prompt, "", function(amount)
        if amount == nil then
            showYesNo(g_i18n:getText("rm_fm_neg_cancelConfirm"), function(yes)
                if yes then
                    callManagerAPI(
                        RmNegotiationManager.walkaway,
                        { RmNegotiationUI.currentFarmId },
                        handleResult
                    )
                else
                    showBuyRound(snapshot)
                end
            end, g_i18n:getText("rm_fm_neg_walkAway"), g_i18n:getText("rm_fm_neg_continue"))
            return
        end
        callManagerAPI(
            RmNegotiationManager.submitOffer,
            { RmNegotiationUI.currentFarmId, amount },
            handleResult
        )
    end, g_i18n:getText("rm_fm_neg_submit"))
end

--- Show Accept/Counter-offer YesNo for a buy round with a price to respond to.
---@param snapshot table Session snapshot
---@param msg string Dialog message (e.g. "The seller counters at €107,349.")
---@param acceptPrice number Price to accept if player clicks Accept
showBuyAcceptOrCounter = function(snapshot, msg, acceptPrice)
    showYesNo(msg, function(accepted)
        if accepted then
            callManagerAPI(
                RmNegotiationManager.submitOffer,
                { RmNegotiationUI.currentFarmId, acceptPrice },
                handleResult
            )
        else
            showBuyAmountInput(snapshot, g_i18n:getText("rm_fm_neg_enterOffer"))
        end
    end, g_i18n:getText("rm_fm_neg_accept"), g_i18n:getText("rm_fm_neg_counterOffer"))
end

--- Show buy round: display counter info and prompt for offer.
---@param snapshot table Session snapshot
showBuyRound = function(snapshot)
    Log:trace(">>> showBuyRound(round=%d)", snapshot.round)

    -- Round exhausted (round 4) - must accept counter or walk away
    if snapshot.round > RmNegotiationEngine.getMaxRounds() then
        local counterStr = formatPrice(snapshot.lastCounter)
        local msg = string.format(g_i18n:getText("rm_fm_neg_roundsExhausted"), counterStr)
        showYesNo(msg, function(accepted)
            if accepted then
                -- Accept at lastCounter price
                callManagerAPI(
                    RmNegotiationManager.submitOffer,
                    { RmNegotiationUI.currentFarmId, snapshot.lastCounter },
                    handleResult
                )
            else
                callManagerAPI(
                    RmNegotiationManager.walkaway,
                    { RmNegotiationUI.currentFarmId },
                    handleResult
                )
            end
        end, g_i18n:getText("rm_fm_neg_accept"), g_i18n:getText("rm_fm_neg_walkAway"))
        return
    end

    -- Determine if player has a price to accept (counter or unlisted demand)
    local acceptablePrice = snapshot.lastCounter
    local isListedRound1 = snapshot.round == 1
        and RmNegotiationUI.currentMode == RmNegotiationEngine.MODE_LISTED_BUY

    if isListedRound1 then
        -- Listed round 1: player initiates - TextInput only
        local anchorStr = formatPrice(snapshot.anchorPrice)
        local prompt = string.format(g_i18n:getText("rm_fm_neg_listedOpening"), anchorStr)
        showBuyAmountInput(snapshot, prompt)
    elseif snapshot.round == 1 then
        -- Unlisted round 1: owner states demand - Accept or Counter
        local anchorStr = formatPrice(snapshot.anchorPrice)
        local msg = string.format(g_i18n:getText("rm_fm_neg_unlistedOpening"), anchorStr)
        acceptablePrice = snapshot.anchorPrice
        showBuyAcceptOrCounter(snapshot, msg, acceptablePrice)
    else
        -- Rounds 2+: seller counters - Accept or Counter
        local counterStr = formatPrice(snapshot.lastCounter)
        local msg = string.format(g_i18n:getText("rm_fm_neg_sellerCounters"), counterStr)
        showBuyAcceptOrCounter(snapshot, msg, acceptablePrice)
    end

    Log:trace("<<< showBuyRound()")
end

-- =============================================================================
-- SELL ROUND DIALOG
-- =============================================================================

--- Show TextInput for entering a sell counter-ask amount.
---@param snapshot table Session snapshot
---@param prompt string Dialog prompt text
showSellAmountInput = function(snapshot, prompt)
    showAmountInput(prompt, "", function(amount)
        if amount == nil then
            showYesNo(g_i18n:getText("rm_fm_neg_cancelConfirm"), function(yes)
                if yes then
                    callManagerAPI(
                        RmNegotiationManager.walkaway,
                        { RmNegotiationUI.currentFarmId },
                        handleResult
                    )
                else
                    showSellRound(snapshot)
                end
            end, g_i18n:getText("rm_fm_neg_walkAway"), g_i18n:getText("rm_fm_neg_continue"))
            return
        end
        callManagerAPI(
            RmNegotiationManager.submitAsk,
            { RmNegotiationUI.currentFarmId, amount },
            handleResult
        )
    end, g_i18n:getText("rm_fm_neg_submit"))
end

--- Show Accept/Counter-offer YesNo for a sell round with an NPC offer to respond to.
---@param snapshot table Session snapshot
---@param msg string Dialog message (e.g. "A buyer offers €85,000 for your field.")
---@param acceptPrice number Price to accept if player clicks Accept
showSellAcceptOrCounter = function(snapshot, msg, acceptPrice)
    showYesNo(msg, function(accepted)
        if accepted then
            callManagerAPI(
                RmNegotiationManager.submitAsk,
                { RmNegotiationUI.currentFarmId, acceptPrice },
                handleResult
            )
        else
            showSellAmountInput(snapshot, g_i18n:getText("rm_fm_neg_enterCounterAsk"))
        end
    end, g_i18n:getText("rm_fm_neg_accept"), g_i18n:getText("rm_fm_neg_counterOffer"))
end

--- Show sell round: display NPC offer and prompt for accept or counter-ask.
---@param snapshot table Session snapshot
showSellRound = function(snapshot)
    Log:trace(">>> showSellRound(round=%d)", snapshot.round)

    -- Round exhausted - must accept NPC offer or walk away
    if snapshot.round > RmNegotiationEngine.getMaxRounds() then
        local npcOfferStr = formatPrice(snapshot.lastCounter)
        local msg = string.format(g_i18n:getText("rm_fm_neg_sellRoundsExhausted"), npcOfferStr)
        showYesNo(msg, function(accepted)
            if accepted then
                callManagerAPI(
                    RmNegotiationManager.submitAsk,
                    { RmNegotiationUI.currentFarmId, snapshot.lastCounter },
                    handleResult
                )
            else
                callManagerAPI(
                    RmNegotiationManager.walkaway,
                    { RmNegotiationUI.currentFarmId },
                    handleResult
                )
            end
        end, g_i18n:getText("rm_fm_neg_accept"), g_i18n:getText("rm_fm_neg_walkAway"))
        return
    end

    -- NPC always presents a price - Accept or Counter-offer
    local npcOfferStr = formatPrice(snapshot.lastCounter)
    local msg
    if snapshot.round == 1 then
        msg = string.format(g_i18n:getText("rm_fm_neg_npcOpening"), npcOfferStr)
    else
        msg = string.format(g_i18n:getText("rm_fm_neg_npcRaises"), npcOfferStr)
    end

    showSellAcceptOrCounter(snapshot, msg, snapshot.lastCounter)

    Log:trace("<<< showSellRound()")
end

-- =============================================================================
-- EXECUTE DEAL (PURCHASE/SALE)
-- =============================================================================

--- Execute a completed deal by sending FarmlandStateEvent.
---@param snapshot table Completed session snapshot with finalPrice
executeDeal = function(snapshot)
    Log:trace(">>> executeDeal(farmland=%d, price=%.0f, mode=%s)",
        snapshot.farmlandId, snapshot.finalPrice, snapshot.mode)

    -- Guard: g_client required to send events (nil on dedicated server without player)
    if g_client == nil then
        Log:error("executeDeal: g_client is nil, cannot send FarmlandStateEvent")
        RmNegotiationUI.clearState()
        return
    end

    local farmlandId = snapshot.farmlandId
    local farmId = RmNegotiationUI.currentFarmId
    local price = snapshot.finalPrice

    if snapshot.mode == RmNegotiationEngine.MODE_SELL then
        -- SELL: transfer to NPC (farmId=0)
        g_client:getServerConnection():sendEvent(
            FarmlandStateEvent.new(farmlandId, FarmlandManager.NO_OWNER_FARM_ID, price)
        )
        Log:info("NEGOTIATION_UI: Executing sale of farmland %d for %s",
            farmlandId, formatPrice(price))
    else
        -- BUY: validate balance first (advisory - server also validates)
        local farm = g_farmManager:getFarmById(farmId)
        if farm == nil then
            showInfo(g_i18n:getText("rm_fm_neg_error"))
            RmNegotiationUI.clearState()
            return
        end
        if farm:getBalance() < price then
            showInfo(g_i18n:getText("rm_fm_neg_insufficientFunds"))
            RmNegotiationUI.clearState()
            return
        end

        -- Set pendingDeals bypass for availability check (host only - server already set in completeSession)
        if g_server ~= nil then
            RmNegotiationManager.pendingDeals[farmlandId] = true
        end

        -- Send purchase event
        g_client:getServerConnection():sendEvent(
            FarmlandStateEvent.new(farmlandId, farmId, price)
        )
        Log:info("NEGOTIATION_UI: Executing purchase of farmland %d for %s",
            farmlandId, formatPrice(price))
    end

    RmNegotiationUI.clearState()
    Log:trace("<<< executeDeal()")
end

-- =============================================================================
-- PUBLIC API - ENTRY POINTS
-- =============================================================================

--- Start a buy negotiation (listed or unlisted).
---@param farmlandId number
---@param farmId number
---@param isListed boolean Whether the field is listed for sale
function RmNegotiationUI.startBuyNegotiation(farmlandId, farmId, isListed)
    Log:trace(">>> startBuyNegotiation(farmland=%d, farm=%d, listed=%s)",
        farmlandId, farmId, tostring(isListed))

    RmNegotiationUI.currentFarmlandId = farmlandId
    RmNegotiationUI.currentFarmId = farmId
    RmNegotiationUI.currentMode = isListed and
        RmNegotiationEngine.MODE_LISTED_BUY or RmNegotiationEngine.MODE_UNLISTED_BUY

    local apiFn = isListed and
        RmNegotiationManager.startListedBuy or RmNegotiationManager.startUnlistedBuy

    callManagerAPI(apiFn, { farmlandId, farmId }, handleResult)
    Log:trace("<<< startBuyNegotiation()")
end

--- Start a sell negotiation: prompt player for listing price, then start session.
---@param farmlandId number
---@param farmId number
function RmNegotiationUI.startSellNegotiation(farmlandId, farmId)
    Log:trace(">>> startSellNegotiation(farmland=%d, farm=%d)", farmlandId, farmId)

    RmNegotiationUI.currentFarmlandId = farmlandId
    RmNegotiationUI.currentFarmId = farmId
    RmNegotiationUI.currentMode = RmNegotiationEngine.MODE_SELL

    -- Get market value for reference display
    local farmland = g_farmlandManager:getFarmlandById(farmlandId)
    if farmland == nil then
        showInfo(g_i18n:getText("rm_fm_neg_invalidFarmland"))
        RmNegotiationUI.clearState()
        return
    end
    local marketValue = farmland.price
    local marketStr = formatPrice(marketValue)

    -- Prompt player to enter their listing price
    local prompt = string.format(g_i18n:getText("rm_fm_neg_enterListingPrice"), marketStr)
    local defaultText = tostring(math.floor(marketValue))

    showAmountInput(prompt, defaultText, function(listingPrice)
        if listingPrice == nil then
            -- Player cancelled - abort sell
            RmNegotiationUI.clearState()
            return
        end
        callManagerAPI(
            RmNegotiationManager.startSell,
            { farmlandId, farmId, listingPrice },
            handleResult
        )
    end, g_i18n:getText("rm_fm_neg_submit"))
    Log:trace("<<< startSellNegotiation()")
end

-- =============================================================================
-- PUBLIC API - ASYNC RESULT RECEIVER
-- =============================================================================

--- Called by RmNegotiationResultEvent:run() on client when result arrives.
---@param success boolean
---@param errorReason string
---@param snapshot table|nil
function RmNegotiationUI.onResultReceived(success, errorReason, snapshot)
    Log:trace(">>> onResultReceived(success=%s)", tostring(success))

    local callback = RmNegotiationUI.pendingCallback
    RmNegotiationUI.pendingCallback = nil

    if callback == nil then
        Log:debug("NEGOTIATION_UI: Result received but no pending callback (console command?)")
        return
    end

    if success then
        callback(snapshot, nil)
    else
        callback(nil, errorReason)
    end

    Log:trace("<<< onResultReceived()")
end

-- =============================================================================
-- PUBLIC API - STATE MANAGEMENT
-- =============================================================================

--- Clear UI state (called after negotiation ends or is cancelled).
function RmNegotiationUI.clearState()
    RmNegotiationUI.pendingCallback = nil
    RmNegotiationUI.currentFarmlandId = nil
    RmNegotiationUI.currentFarmId = nil
    RmNegotiationUI.currentMode = nil
end

--- Cancel any active negotiation for the current farm.
function RmNegotiationUI.cancelActiveNegotiation()
    if RmNegotiationUI.currentFarmId ~= nil then
        Log:debug("NEGOTIATION_UI: Cancelling active negotiation")
        RmNegotiationManager.cancelSession(RmNegotiationUI.currentFarmId)
        RmNegotiationUI.clearState()
    end
end

-- =============================================================================
-- HOOKS (set up at source time)
-- =============================================================================

--- Store original callbacks for fallback (vanilla behavior).
--- These are captured BEFORE any override, so they're the true originals.
local originalOnClickBuy = InGameMenuMapFrame.onClickBuy
local originalOnClickSell = InGameMenuMapFrame.onClickSell

--- Buy interceptor: replaces the contextActions callback on the live instance.
--- Called as callback(self) where self is the InGameMenuMapFrame instance.
local function onClickBuyInterceptor(self)
    Log:trace(">>> onClickBuy interceptor")

    -- Skip if negotiation disabled
    if not RmFmSettings.isNegotiationEnabled() then
        Log:trace("  Negotiation disabled, falling through to vanilla")
        return originalOnClickBuy(self)
    end

    -- Get current hotspot farmland
    local hotspot = self.currentHotspot
    if hotspot == nil or hotspot.getFarmland == nil then
        return originalOnClickBuy(self)
    end
    local farmland = hotspot:getFarmland()
    if farmland == nil then
        return originalOnClickBuy(self)
    end

    local farmlandId = farmland.id
    local farmId = g_currentMission:getFarmId()

    -- Check if field is already owned by player
    if farmland.farmId == farmId then
        return originalOnClickBuy(self)
    end

    -- Determine listed vs unlisted
    local isListed = RmFmAvailability.isForSale(farmlandId)
    local isEligible = RmFmAvailability.isEligibleForAvailability(farmland)

    -- For non-eligible farmlands (e.g., NPC farmlands that never rotate), use vanilla
    if not isEligible and not isListed then
        return originalOnClickBuy(self)
    end

    -- Start negotiation
    RmNegotiationUI.startBuyNegotiation(farmlandId, farmId, isListed)
    Log:trace("<<< onClickBuy interceptor [negotiation started]")
    return true
end

--- Sell interceptor: replaces the contextActions callback on the live instance.
local function onClickSellInterceptor(self)
    Log:trace(">>> onClickSell interceptor")

    -- Skip if negotiation disabled
    if not RmFmSettings.isNegotiationEnabled() then
        return originalOnClickSell(self)
    end

    -- Get current hotspot farmland
    local hotspot = self.currentHotspot
    if hotspot == nil or hotspot.getFarmland == nil then
        return originalOnClickSell(self)
    end
    local farmland = hotspot:getFarmland()
    if farmland == nil then
        return originalOnClickSell(self)
    end

    local farmlandId = farmland.id
    local farmId = g_currentMission:getFarmId()

    -- Only intercept if player owns this field
    if farmland.farmId ~= farmId then
        return originalOnClickSell(self)
    end

    -- Start sell negotiation
    RmNegotiationUI.startSellNegotiation(farmlandId, farmId)
    Log:trace("<<< onClickSell interceptor [negotiation started]")
    return true
end

--- Patch contextActions callbacks on the live InGameMenuMapFrame instance.
--- Utils.overwrittenFunction on onClickBuy/onClickSell has no effect because the
--- button callbacks are captured as direct function references at GUI init time.
--- We patch the stored references on each frame open instead.
InGameMenuMapFrame.onFrameOpen = Utils.appendedFunction(
    InGameMenuMapFrame.onFrameOpen,
    function(self)
        local actions = InGameMenuMapFrame.ACTIONS
        if self.contextActions == nil or actions == nil then
            return
        end

        local buyAction = self.contextActions[actions.BUY]
        if buyAction ~= nil then
            buyAction.callback = onClickBuyInterceptor
            Log:trace("HOOK: Patched BUY contextAction callback on instance")
        end

        local sellAction = self.contextActions[actions.SELL]
        if sellAction ~= nil then
            sellAction.callback = onClickSellInterceptor
            Log:trace("HOOK: Patched SELL contextAction callback on instance")
        end
    end
)

--- Cancel active negotiation when map frame closes.
InGameMenuMapFrame.onFrameClose = Utils.appendedFunction(
    InGameMenuMapFrame.onFrameClose,
    function(self)
        RmNegotiationUI.cancelActiveNegotiation()
    end
)

Log:debug("RmNegotiationUI module loaded")
