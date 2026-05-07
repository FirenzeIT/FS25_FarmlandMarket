-- RmWatchlistDialog - Skeleton modal dialog for the Watchlist feature.
-- Author: Ritter
--
-- MessageDialog subclass. Step 1 only: title text + Back button.
-- Future steps populate the dialog body with the watchlist contents.

local Log = RmLogging.getLogger("FarmlandMarket")

---@class RmWatchlistDialog : MessageDialog
RmWatchlistDialog = {}
local RmWatchlistDialog_mt = Class(RmWatchlistDialog, MessageDialog)

-- ============================================================================
-- CONSTRUCTOR
-- ============================================================================

--- Creates a new RmWatchlistDialog instance.
---@param target table|nil
---@param customMt table|nil
---@return RmWatchlistDialog
function RmWatchlistDialog.new(target, customMt)
    Log:trace(">>> RmWatchlistDialog.new()")
    ---@type RmWatchlistDialog
    ---@diagnostic disable-next-line: assign-type-mismatch
    local self = MessageDialog.new(target, customMt or RmWatchlistDialog_mt)
    return self
end

-- ============================================================================
-- STATIC METHODS
-- ============================================================================

--- Registers the dialog with the GUI system.
function RmWatchlistDialog.register()
    Log:trace(">>> RmWatchlistDialog.register()")
    local modDir = RmFarmlandMarket.modDirectory
    local dialog = RmWatchlistDialog.new(g_i18n)
    g_gui:loadGui(modDir .. "gui/RmWatchlistDialog.xml", "RmWatchlistDialog", dialog)
    -- Verify actual GUI registration, not just constructor success.
    -- Loaded custom dialogs land in g_gui.guis[name], same as RmNegotiationDialog.
    if g_gui.guis ~= nil and g_gui.guis["RmWatchlistDialog"] ~= nil then
        Log:info("RmWatchlistDialog registered")
    else
        Log:error("Failed to register RmWatchlistDialog (g_gui.guis lookup empty)")
    end
    Log:trace("<<< RmWatchlistDialog.register()")
end

--- Opens the watchlist dialog via the GUI system.
function RmWatchlistDialog.show()
    Log:trace(">>> RmWatchlistDialog.show()")
    if g_gui == nil then
        Log:trace("RmWatchlistDialog.show: g_gui is nil, abort")
        return
    end
    -- Custom-loaded dialogs are tracked in g_gui.guis[name], not g_gui.dialogs.
    -- (Matches RmNegotiationDialog and tests/RmNegotiationUITests.)
    if g_gui.guis == nil or g_gui.guis["RmWatchlistDialog"] == nil then
        Log:trace("RmWatchlistDialog.show: dialog not registered, abort")
        return
    end
    g_gui:showDialog("RmWatchlistDialog")
    Log:trace("<<< RmWatchlistDialog.show()")
end

--- Returns the dialog instance from the GUI system.
---@return RmWatchlistDialog|nil
function RmWatchlistDialog.getInstance()
    local entry = g_gui.guis["RmWatchlistDialog"]
    return entry and entry.target or nil
end

-- ============================================================================
-- INSTANCE METHODS
-- ============================================================================

--- Override to log the close path before delegating to MessageDialog.
--- Wired from RmWatchlistDialog.xml: <Button onClick="onClickBack" .../>
function RmWatchlistDialog:onClickBack()
    Log:trace(">>> RmWatchlistDialog:onClickBack()")
    RmWatchlistDialog:superClass().onClickBack(self)
    Log:trace("<<< RmWatchlistDialog:onClickBack()")
end
