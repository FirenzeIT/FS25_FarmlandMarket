-- RmWatchlistUI - Map-frame integration for the Watchlist feature.
-- Author: Ritter
--
-- Step 1 only: clones the Back button in the map frame's bottom buttonBox
-- to insert a Watchlist button visible only on the Farmlands subcategory,
-- and opens a skeleton RmWatchlistDialog when clicked. Future steps populate
-- the dialog body.

RmWatchlistUI = {}

local Log = RmLogging.getLogger("FarmlandMarket")

-- Cloned controls awaiting FocusManager registration.
local fmClonedControls = {}

-- ============================================================================
-- HELPERS
-- ============================================================================

--- Recursively assign unique focusIds to a cloned element and all its children.
--- Cloned elements inherit duplicate focusIds from their templates, which breaks
--- FocusManager navigation. Mirrors RmFmSettings.updateFocusIds.
---@param element table|nil GUI element
local function updateFocusIds(element)
    if not element then return end
    element.focusId = FocusManager:serveAutoFocusId()
    if element.elements ~= nil then
        for _, child in pairs(element.elements) do
            updateFocusIds(child)
        end
    end
end

--- Predicate: should the Watchlist button be visible for the given subcategory state?
--- Single source of truth shared by visibility checks and tests.
---@param state number|nil InGameMenuMapFrame subcategory enum value
---@return boolean
function RmWatchlistUI.shouldShow(state)
    Log:trace(">>> RmWatchlistUI.shouldShow(state=%s)", tostring(state))
    local result = state == InGameMenuMapFrame.MAP_FARMLANDS
    Log:trace("<<< RmWatchlistUI.shouldShow -> %s", tostring(result))
    return result
end

--- Open the skeleton Watchlist dialog.
function RmWatchlistUI.openDialog()
    Log:trace(">>> RmWatchlistUI.openDialog()")
    RmWatchlistDialog.show()
    Log:trace("<<< RmWatchlistUI.openDialog()")
end

--- Action-event handler for MENU_EXTRA_2 (the C key by default), registered on
--- the InGameMenuMapFrame instance during onFrameOpen. Only opens the dialog
--- when the Watchlist button is currently visible (Farmlands subcategory).
---@param self table InGameMenuMapFrame instance
local function onMenuExtra2KeyEvent(self)
    Log:trace(">>> RmWatchlistUI.onMenuExtra2KeyEvent")
    local state = nil
    if self.mapOverviewSelector ~= nil then
        state = self.mapOverviewSelector:getState()
    end
    if not RmWatchlistUI.shouldShow(state) then
        Log:trace("RmWatchlistUI.onMenuExtra2KeyEvent: not on Farmlands subcat, ignore")
        return
    end
    RmWatchlistUI.openDialog()
    Log:trace("<<< RmWatchlistUI.onMenuExtra2KeyEvent")
end

--- Insert a child element into a parent's element list at a specific index.
---@param parent table BoxLayout / container element
---@param child table element to insert
---@param index number 1-based index in parent.elements
local function insertElementAt(parent, child, index)
    if parent.elements == nil then return end
    table.insert(parent.elements, index, child)
    child.parent = parent
end

--- Find the index of an element in its parent's elements array.
---@param parent table
---@param element table
---@return number|nil 1-based index, or nil if not found
local function indexOfElement(parent, element)
    if parent == nil or parent.elements == nil then return nil end
    for i, e in ipairs(parent.elements) do
        if e == element then
            return i
        end
    end
    return nil
end

-- ============================================================================
-- HOOK BODIES
-- ============================================================================

--- Patch the live frame instance's mapOverviewSelector.onClickCallback to point
--- at the (now-wrapped) onClickMapOverviewSelector method.
---
--- WHY: GUI XML callbacks are captured by reference at load time, so wrapping
--- the class method afterwards has no effect on already-instantiated controls.
--- Without this re-bind, user arrow clicks dispatch to the unwrapped original
--- and our hook never fires. Same per-instance patch pattern RmNegotiationUI
--- uses for BUY/SELL contextActions.
---@param self table InGameMenuMapFrame instance
local function patchMapOverviewSelectorCallback(self)
    if self.mapOverviewSelector == nil then
        return
    end
    if self.mapOverviewSelector.onClickCallback == self.onClickMapOverviewSelector then
        return  -- already pointing at the live wrapped method
    end
    self.mapOverviewSelector.onClickCallback = self.onClickMapOverviewSelector
    Log:trace("RmWatchlistUI: patched mapOverviewSelector.onClickCallback to live wrapped method")
end

--- Append-hook body for InGameMenuMapFrame.onFrameOpen.
--- Creates the Watchlist button on first call, refreshes visibility on every call.
---@param self table InGameMenuMapFrame instance
local function onFrameOpenHook(self)
    Log:trace(">>> RmWatchlistUI.onFrameOpenHook")

    -- Always patch the live instance callback first - even if button creation
    -- below bails early, we still want subsequent subcat clicks to dispatch.
    patchMapOverviewSelectorCallback(self)

    -- Register the MENU_EXTRA_2 keyboard handler explicitly. The map frame's
    -- input context drops MENU_EXTRA_2 from the standard button-action path,
    -- so the cloned button's inputActionName alone wouldn't dispatch on
    -- keypress. By the time our append-hook fires, the slot is clean - we
    -- register fresh, no de-dup needed. The handler guards on subcategory
    -- state, so the C key only opens the dialog when the button is visible.
    g_inputBinding:registerActionEvent(InputAction.MENU_EXTRA_2, self,
        onMenuExtra2KeyEvent, false, true, false, true)

    if self.buttonBack == nil then
        Log:error("RmWatchlistUI: self.buttonBack is nil on InGameMenuMapFrame instance; skipping watchlist button creation")
        if self.elements ~= nil then
            for i, e in ipairs(self.elements) do
                Log:error("  element[%d] id=%s name=%s", i, tostring(e.id), tostring(e.name))
            end
        end
        return
    end

    if self.rmFmWatchlistButton == nil then
        Log:trace("RmWatchlistUI.onFrameOpenHook: first call, cloning buttonBack")
        local btn = self.buttonBack:clone()
        btn:setText(g_i18n:getText("rm_fm_btn_watchlist"))
        -- inputActionName drives the rendered key glyph and lets mouse click
        -- fire onClickCallback. Keyboard dispatch in this frame goes through
        -- the explicit g_inputBinding:registerActionEvent above instead of the
        -- standard button-discovery path.
        btn:setInputAction("MENU_EXTRA_2")
        btn.onClickCallback = RmWatchlistUI.openDialog

        -- Repair focus state for the cloned subtree.
        updateFocusIds(btn)
        table.insert(fmClonedControls, btn)

        -- Insert into buttonBox immediately after buttonBack and before buttonNext.
        local parent = self.buttonBack.parent
        if parent == nil or parent.elements == nil then
            Log:error("RmWatchlistUI: buttonBack has no parent/elements; cannot insert watchlist button")
            return
        end
        local backIndex = indexOfElement(parent, self.buttonBack)
        if backIndex == nil then
            Log:error("RmWatchlistUI: buttonBack not found in parent.elements; cannot insert watchlist button")
            return
        end
        insertElementAt(parent, btn, backIndex + 1)

        -- Default (0,0) anchor and pivot are required for BoxLayout to
        -- position the button correctly. A cloned element can inherit
        -- non-default values from its source, which causes BoxLayout to
        -- misplace or drop it on subsequent relayouts (e.g. on subcategory
        -- change).
        if btn.setAnchor ~= nil then btn:setAnchor(0, 0) end
        if btn.setPivot ~= nil then btn:setPivot(0, 0) end

        self.rmFmWatchlistButton = btn

        -- Register the cloned button with FocusManager immediately, while the
        -- map GUI's focus context is current. The setGui-append fallback below
        -- only runs on later GUI transitions, so first-open keyboard/controller
        -- navigation would otherwise skip the button.
        if FocusManager.currentFocusData ~= nil
            and FocusManager.currentFocusData.idToElementMapping ~= nil then
            if FocusManager:loadElementFromCustomValues(btn, nil, nil, false, false) then
                Log:debug("Watchlist button created and registered with FocusManager (insertedIndex=%d)", backIndex + 1)
            else
                Log:warning("Watchlist button created but FocusManager registration failed (insertedIndex=%d)", backIndex + 1)
            end
        else
            Log:debug("Watchlist button created (insertedIndex=%d); FocusManager not yet ready, will register via setGui hook", backIndex + 1)
        end
    else
        Log:debug("Watchlist button reused (cached on map frame instance)")
    end

    local btn = self.rmFmWatchlistButton
    local state = nil
    if self.mapOverviewSelector ~= nil then
        state = self.mapOverviewSelector:getState()
    end
    btn:setVisible(RmWatchlistUI.shouldShow(state))
    if self.buttonBack.parent ~= nil and self.buttonBack.parent.invalidateLayout ~= nil then
        self.buttonBack.parent:invalidateLayout()
    end

    Log:trace("<<< RmWatchlistUI.onFrameOpenHook")
end

--- Append-hook body for InGameMenuMapFrame.onClickMapOverviewSelector.
--- Refreshes Watchlist button visibility when the player toggles subcategory dots.
---@param self table InGameMenuMapFrame instance
---@param state number new subcategory state
local function onClickMapOverviewSelectorHook(self, state)
    Log:trace(">>> RmWatchlistUI.onClickMapOverviewSelectorHook(state=%s)", tostring(state))
    if self.rmFmWatchlistButton == nil then
        Log:trace("RmWatchlistUI.onClickMapOverviewSelectorHook: button not yet created, skip")
        return
    end
    local visible = RmWatchlistUI.shouldShow(state)
    self.rmFmWatchlistButton:setVisible(visible)
    if self.buttonBack ~= nil and self.buttonBack.parent ~= nil
        and self.buttonBack.parent.invalidateLayout ~= nil then
        self.buttonBack.parent:invalidateLayout()
    end
    Log:trace("<<< RmWatchlistUI.onClickMapOverviewSelectorHook (visible=%s)", tostring(visible))
end

-- ============================================================================
-- HOOK INSTALLATION
-- ============================================================================

InGameMenuMapFrame.onFrameOpen = Utils.appendedFunction(
    InGameMenuMapFrame.onFrameOpen,
    onFrameOpenHook
)

InGameMenuMapFrame.onClickMapOverviewSelector = Utils.appendedFunction(
    InGameMenuMapFrame.onClickMapOverviewSelector,
    onClickMapOverviewSelectorHook
)

-- Register cloned controls with FocusManager once the GUI is set up.
-- Without this, cloned elements are not reachable via keyboard/controller
-- navigation. Mirrors RmFmSettings hook.
FocusManager.setGui = Utils.appendedFunction(FocusManager.setGui, function(_, gui)
    if gui == nil or #fmClonedControls == 0 then return end

    local registered = 0
    for _, control in ipairs(fmClonedControls) do
        if not control.focusId
            or not FocusManager.currentFocusData.idToElementMapping[control.focusId] then
            if FocusManager:loadElementFromCustomValues(control, nil, nil, false, false) then
                registered = registered + 1
            else
                Log:warning("RmWatchlistUI: failed to register %s with FocusManager",
                    control.id or control.typeName or "?")
            end
        end
    end

    if registered > 0 then
        Log:trace("RmWatchlistUI: registered %d cloned controls with FocusManager", registered)
    end
end)

Log:info("RmWatchlistUI hooks installed")
