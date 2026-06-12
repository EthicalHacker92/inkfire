--[[
InkFire — main.lua
Plugin shell. Owns lifecycle, menu/dispatcher registration, settings,
and navigation between Hearth (home), Library, and Transfer.

Design stance (see docs/DESIGN.md): polish, don't replace. Hearth is a
full-screen widget shown over the stock file manager — no monkey-patching,
so KOReader updates can't break the device. Swipe down anywhere → stock UI.
--]]

local Device          = require("device")
local Dispatcher      = require("dispatcher")
local InfoMessage     = require("ui/widget/infomessage")
local InputDialog     = require("ui/widget/inputdialog")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger          = require("logger")
local _               = require("gettext")
local T               = require("ffi/util").template

local S        = require("plugins/inkfire.koplugin/style")
local Data     = require("plugins/inkfire.koplugin/data")
local Transfer = require("plugins/inkfire.koplugin/transfer")

-- Heavier screens load on first use (require() caches them after that).
local function loadHearth()  return require("plugins/inkfire.koplugin/home")    end
local function loadLibrary() return require("plugins/inkfire.koplugin/library") end

-- Auto-open once per KOReader launch, not on every FileManager respawn.
local _booted = false

local InkFire = WidgetContainer:extend{
    name = "inkfire",
    is_doc_only = false,
}

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

function InkFire:init()
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- Welcome screen on boot: only in file-manager context, only once,
    -- only if the user hasn't turned it off.
    if not _booted
        and not (self.ui and self.ui.document)
        and G_reader_settings:nilOrTrue("inkfire_auto_home") then
        _booted = true
        UIManager:nextTick(function() self:showHome() end)
    end

    -- Keep the transfer server alive across reader/file-manager switches.
    if Transfer.isRunning() then
        self:scheduleTransferPoll()
    end
end

function InkFire:onDispatcherRegisterActions()
    Dispatcher:registerAction("inkfire_home", {
        category = "none",
        event    = "InkFireHome",
        title    = _("InkFire: open Hearth"),
        general  = true,
    })
end

function InkFire:onInkFireHome()
    self:showHome()
    return true
end

-- ── Navigation ────────────────────────────────────────────────────────────────

function InkFire:showHome()
    if self._home then
        UIManager:close(self._home)
        self._home = nil
    end
    local Hearth = loadHearth()
    self._home = Hearth:new{
        on_open_file     = function(file) self:openFile(file) end,
        on_open_library  = function() self:showLibrary() end,
        on_open_transfer = function() self:toggleTransfer() end,
        on_open_settings = function() self:showSettings() end,
        on_set_goal      = function() self:editGoal() end,
    }
    UIManager:show(self._home)
end

function InkFire:showLibrary()
    local Library = loadLibrary()
    self._library = Library:new{
        on_open_file = function(file) self:openFile(file) end,
    }
    UIManager:show(self._library)
end

function InkFire:openFile(file)
    if not file then return end
    -- Tear down our screens first so the reader paints clean.
    if self._library then UIManager:close(self._library); self._library = nil end
    if self._home    then UIManager:close(self._home);    self._home = nil    end
    Data.dropCoverCache()
    local ok, err = pcall(function()
        local ReaderUI = require("apps/reader/readerui")
        ReaderUI:showReader(file)
    end)
    if not ok then
        logger.warn("InkFire openFile failed:", err)
        UIManager:show(InfoMessage:new{
            text = T(_("Couldn't open:\n%1"), file), timeout = 3,
        })
    end
end

-- ── Transfer ──────────────────────────────────────────────────────────────────

function InkFire:toggleTransfer()
    if Transfer.isRunning() then
        local done = select(1, Transfer.counts())
        Transfer.stop()
        UIManager:show(InfoMessage:new{
            text = done > 0
                and T(_("Transfer stopped. %1 file(s) received."), done)
                or  _("Transfer stopped."),
            timeout = 3,
        })
        return
    end

    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then
        NetworkMgr:beforeWifiAction(function() self:startTransfer() end)
    else
        self:startTransfer()
    end
end

function InkFire:startTransfer()
    local result = Transfer.start("/mnt/onboard")
    if result.error then
        UIManager:show(InfoMessage:new{
            text = T(_("Transfer couldn't start: %1"), result.error), timeout = 4,
        })
        return
    end
    self:scheduleTransferPoll()
    UIManager:show(InfoMessage:new{
        text = T(_("Drop files from any browser on your WiFi:\n\n%1\n\nManga lands in manga/, books in books/.\nTap Transfer again to stop."), result.url),
    })
end

function InkFire:scheduleTransferPoll()
    if self._poll_scheduled then return end
    self._poll_scheduled = true
    local function tick()
        self._poll_scheduled = false
        if not Transfer.isRunning() then return end
        pcall(Transfer.poll)
        self._poll_scheduled = true
        UIManager:scheduleIn(0.2, tick)
    end
    UIManager:scheduleIn(0.2, tick)
end

-- ── Settings ──────────────────────────────────────────────────────────────────

function InkFire:showSettings()
    local auto = G_reader_settings:nilOrTrue("inkfire_auto_home")
    local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
    local dialog
    dialog = ButtonDialogTitle:new{
        title = "InkFire",
        buttons = {
            {{
                text = auto and _("Show Hearth on startup: on")
                            or  _("Show Hearth on startup: off"),
                callback = function()
                    G_reader_settings:saveSetting("inkfire_auto_home", not auto)
                    UIManager:close(dialog)
                    UIManager:show(InfoMessage:new{
                        text = (not auto)
                            and _("Hearth will greet you on startup.")
                            or  _("Startup Hearth off. Find it in Tools."),
                        timeout = 2,
                    })
                end,
            }},
            {{
                text = T(_("Daily goal: %1 min"), Data.dailyGoalMinutes()),
                callback = function()
                    UIManager:close(dialog)
                    self:editGoal()
                end,
            }},
            {{
                text = _("Close"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    UIManager:show(dialog)
end

function InkFire:editGoal()
    local dialog
    dialog = InputDialog:new{
        title = _("Daily reading goal (minutes)"),
        input = tostring(Data.dailyGoalMinutes()),
        input_type = "number",
        buttons = {{
            {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local v = tonumber(dialog:getInputText())
                    UIManager:close(dialog)
                    if v and v > 0 and v <= 24 * 60 then
                        Data.setDailyGoalMinutes(math.floor(v))
                        UIManager:show(InfoMessage:new{
                            text = T(_("Goal set: %1 minutes a day."), math.floor(v)),
                            timeout = 2,
                        })
                        if self._home then self._home:refresh() end
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ── Main menu entry (discoverability + escape hatch) ──────────────────────────

function InkFire:addToMainMenu(menu_items)
    menu_items.inkfire = {
        text = _("InkFire Hearth"),
        sorting_hint = "tools",
        callback = function() self:showHome() end,
    }
end

return InkFire
