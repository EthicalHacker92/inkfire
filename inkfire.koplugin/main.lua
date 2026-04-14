--[[
InkFire — Main UI Router
The ONLY file that touches KOReader UI widgets, UIManager, and WidgetContainer.
All business logic lives in modules/. This file dispatches events and renders results.
--]]

local WidgetContainer  = require("ui/widget/container/widgetcontainer")
local UIManager        = require("ui/uimanager")
local InfoMessage      = require("ui/widget/infomessage")
local ConfirmBox       = require("ui/widget/confirmbox")
local InputDialog      = require("ui/widget/inputdialog")
local Menu             = require("ui/widget/menu")
local TextWidget       = require("ui/widget/textwidget")
local FrameContainer   = require("ui/widget/container/framecontainer")
local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
local Blitbuffer       = require("ffi/blitbuffer")
local Font             = require("ui/font")
local Screen           = require("device/screen")
local NetworkMgr       = require("ui/network/manager")
local logger           = require("logger")
local _                = require("gettext")
local T                = require("ffi/util").template

-- ── Plugin self-path helper ───────────────────────────────────────────────────

local function pluginDir()
    local src = debug.getinfo(1, "S").source
    src = src:sub(2)           -- strip leading @
    src = src:gsub("^%./", "") -- normalize away ./ so require cache keys match submodules
    return src:match("^(.+)/[^/]+$") or "."
end

local PLUGIN_DIR = pluginDir()

-- ── Lazy-load helpers ─────────────────────────────────────────────────────────

local function loadModule(name)
    local ok, mod = pcall(require, PLUGIN_DIR .. "/modules/" .. name)
    if not ok then
        logger.warn("InkFire: failed to load module", name, ":", mod)
        return nil
    end
    return mod
end

-- Module refs — loaded on first use
local State          = nil
local MangaFlow      = nil
local PowerGuard     = nil
local ReadingVault   = nil
local ClipSync       = nil
local SeriesOS       = nil
local TransferBridge = nil

local function getState()
    State = State or loadModule("state")
    return State
end

-- ── Plugin class ──────────────────────────────────────────────────────────────

local InkFire = WidgetContainer:extend{
    name = "inkfire",

    -- MangaFlow runtime state
    _mf_is_manga      = false,
    _mf_series_name   = nil,
    _mf_settings      = nil,
    _mf_total_pages   = 0,
    _mf_current_page  = 0,
    _mf_spread_mode   = false,
    _mf_prev_zoom     = nil,
    _mf_hud           = nil,
}

-- ── Init ──────────────────────────────────────────────────────────────────────

function InkFire:init()
    -- Eager loads: State is the pub/sub backbone (needed before any subscription),
    -- ReadingVault + ClipSync need DB table creation at startup.
    -- All other modules are lazy-loaded on first menu/event access.
    State        = loadModule("state")
    ReadingVault = loadModule("readingvault")
    ClipSync     = loadModule("clipsync")

    if ReadingVault then ReadingVault.init() end
    if ClipSync     then ClipSync.initDB()   end

    self.ui.menu:registerToMainMenu(self)

    -- Show daily memory after 3s
    UIManager:scheduleIn(3, function()
        self:maybeShowDailyMemory()
    end)

    -- Start brightness schedule ticker (60s interval)
    UIManager:scheduleIn(60, function()
        self:scheduleTick()
    end)

    logger.dbg("InkFire: initialized")
end

-- ── Reader event hooks ────────────────────────────────────────────────────────

function InkFire:onReaderReady()
    local doc = self.ui and self.ui.document
    if not doc then return end

    local filepath = doc.file or ""
    self._mf_total_pages = doc:getPageCount() or 0

    -- MangaFlow
    MangaFlow = MangaFlow or loadModule("mangaflow")
    if MangaFlow then
        local result = MangaFlow.onDocumentOpen(filepath, doc)
        self._mf_is_manga    = result.is_manga
        self._mf_series_name = result.series_name
        self._mf_settings    = result.settings
        self._mf_spread_mode = false

        if result.is_manga then
            if result.needs_prompt then
                self:promptMangaMode(result.series_name)
            else
                self:applyMangaSettings(result.settings)
                self:showHUD()
            end
        end
    end

    -- ReadingVault
    if ReadingVault then
        local props = doc.getProps and doc:getProps() or {}
        ReadingVault.onDocumentOpen(filepath, props)
    end
end

function InkFire:onPageUpdate(pageno)
    self._mf_current_page = pageno

    -- Update HUD
    if self._mf_is_manga and self._mf_hud then
        self:showHUD()
    end

    -- Handle spread mode
    if self._mf_is_manga and self._mf_settings then
        MangaFlow = MangaFlow or loadModule("mangaflow")
        if MangaFlow then
            local doc    = self.ui and self.ui.document
            local action = MangaFlow.updateSpreadState(
                doc, pageno, self._mf_settings, self._mf_spread_mode)
            if action == "enter" then
                self:enterSpreadMode()
            elseif action == "exit" then
                self:exitSpreadMode()
            end
        end
    end

    -- ReadingVault page count
    if ReadingVault then ReadingVault.onPageUpdate() end
end

function InkFire:onCloseDocument()
    -- MangaFlow cleanup
    self:removeHUD()
    self:exitSpreadMode()
    if MangaFlow then MangaFlow.onDocumentClose() end
    self._mf_is_manga    = false
    self._mf_series_name = nil
    self._mf_settings    = nil
    self._mf_spread_mode = false

    -- ReadingVault session summary
    if ReadingVault then
        local doc   = self.ui and self.ui.document
        local title = doc and doc.getProps and doc:getProps().title or ""
        local summary = ReadingVault.onDocumentClose(title)
        if summary then
            self:showSessionSummary(summary)
        end
    end
end

-- ── Scheduler tick ────────────────────────────────────────────────────────────

function InkFire:scheduleTick()
    PowerGuard = PowerGuard or loadModule("powerguard")
    if PowerGuard then
        local action, pct = PowerGuard.checkBrightnessSchedule()
        if action == "enter_low" then
            UIManager:show(InfoMessage:new{
                text    = T(_("Battery at %1%%. Low battery mode enabled."), pct),
                timeout = 4,
            })
        end
    end

    -- TransferBridge poll
    if TransferBridge and TransferBridge.isRunning() then
        TransferBridge.poll()
        -- Check if library refresh needed
        local S = getState()
        if S and S.get("transferbridge.refresh_needed") then
            S.set("transferbridge.refresh_needed", false)
            local ok, FM = pcall(require, "apps/filemanager/filemanager")
            if ok and FM and FM.instance then
                FM.instance:onRefresh()
            end
        end
    end

    UIManager:scheduleIn(60, function() self:scheduleTick() end)
end

-- ── TransferBridge poll interval (separate faster tick) ───────────────────────

function InkFire:transferPoll()
    if TransferBridge and TransferBridge.isRunning() then
        TransferBridge.poll()
        UIManager:scheduleIn(0.15, function() self:transferPoll() end)
    end
end

-- ── MangaFlow UI helpers ──────────────────────────────────────────────────────

function InkFire:promptMangaMode(series_name)
    UIManager:show(ConfirmBox:new{
        text    = T(_("MangaFlow detected manga:\n%1\n\nEnable Manga Mode? (RTL, max contrast, pre-cache)"), series_name or ""),
        ok_text = _("Enable"),
        ok_callback = function()
            MangaFlow = MangaFlow or loadModule("mangaflow")
            if MangaFlow then
                self._mf_settings = MangaFlow.confirmMangaMode(series_name)
                self:applyMangaSettings(self._mf_settings)
                self:showHUD()
            end
        end,
        cancel_text = _("Skip"),
    })
end

function InkFire:applyMangaSettings(settings)
    local doc = self.ui and self.ui.document
    if not doc then return end

    -- RTL reading order
    if doc.setReadingOrder then
        local s = settings or {}
        pcall(function()
            doc:setReadingOrder(s.rtl == 1 and 1 or 0)
        end)
    end

    -- Contrast
    if doc.setContrast and settings and settings.contrast then
        local gamma = 0.5 + (settings.contrast / 100) * 1.5
        pcall(function() doc:setContrast(gamma) end)
    end

    -- Pre-cache
    if self.ui.readerrolling and self.ui.readerrolling.setPreCache and settings then
        pcall(function()
            self.ui.readerrolling:setPreCache(settings.precache or 3)
        end)
    end
end

function InkFire:showHUD()
    self:removeHUD()
    MangaFlow = MangaFlow or loadModule("mangaflow")
    if not MangaFlow then return end

    local text = MangaFlow.buildHUDText(
        self._mf_series_name, self._mf_current_page, self._mf_total_pages)
    local face = Font:getFace("infofont", 14)

    self._mf_hud = FrameContainer:new{
        background = Blitbuffer.COLOR_BLACK,
        bordersize = 0,
        padding    = 4,
        TextWidget:new{
            text    = text,
            face    = face,
            fgcolor = Blitbuffer.COLOR_WHITE,
        },
    }
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self._mf_hud.overlap_offset = {
        math.floor((sw - 200) / 2),
        sh - 32,
    }
    UIManager:show(self._mf_hud)
end

function InkFire:removeHUD()
    if self._mf_hud then
        UIManager:close(self._mf_hud)
        self._mf_hud = nil
    end
end

function InkFire:enterSpreadMode()
    self._mf_spread_mode = true
    local zoom = self.ui and self.ui.readerzooming
    if zoom then
        self._mf_prev_zoom = zoom.zoom_mode
        pcall(function() zoom:setZoomMode("pagewidth") end)
    end
end

function InkFire:exitSpreadMode()
    if not self._mf_spread_mode then return end
    self._mf_spread_mode = false
    local zoom = self.ui and self.ui.readerzooming
    if zoom and self._mf_prev_zoom then
        pcall(function() zoom:setZoomMode(self._mf_prev_zoom) end)
        self._mf_prev_zoom = nil
    end
end

-- ── ReadingVault UI helpers ───────────────────────────────────────────────────

function InkFire:showSessionSummary(summary)
    local mins = summary.minutes
    local goal_str
    if summary.hit_goal then
        goal_str = summary.above_goal > 0
            and T(_("%1 min above goal"), summary.above_goal)
            or  _("Goal hit!")
    else
        local remaining = math.ceil((summary.goal_secs - summary.today_secs) / 60)
        goal_str = T(_("%1 min to goal"), remaining)
    end
    local streak_str = summary.streak > 0
        and (" · " .. summary.streak .. _(" day streak 🔥"))
        or  ""

    UIManager:show(InfoMessage:new{
        text    = T(_("Session complete\n\n%1 min read · %2%3"), mins, goal_str, streak_str),
        timeout = 5,
    })
end

function InkFire:editDailyGoal()
    ReadingVault = ReadingVault or loadModule("readingvault")
    if not ReadingVault then return end
    local current = ReadingVault.getDailyGoalMinutes()
    local dialog
    dialog = InputDialog:new{
        title      = _("Daily reading goal (minutes)"),
        input      = tostring(current),
        input_type = "number",
        buttons    = {{
            {
                text     = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text             = _("Save"),
                is_enter_default = true,
                callback         = function()
                    local v = tonumber(dialog:getInputText())
                    if v and v > 0 then
                        ReadingVault.setDailyGoal(v)
                        UIManager:show(InfoMessage:new{
                            text    = T(_("Daily goal set to %1 min."), v),
                            timeout = 2,
                        })
                    end
                    UIManager:close(dialog)
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

function InkFire:editYearlyGoal()
    ReadingVault = ReadingVault or loadModule("readingvault")
    if not ReadingVault then return end
    local current = ReadingVault.getYearlyGoal()
    local dialog
    dialog = InputDialog:new{
        title      = _("Yearly book goal"),
        input      = tostring(current),
        input_type = "number",
        buttons    = {{
            {
                text     = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text             = _("Save"),
                is_enter_default = true,
                callback         = function()
                    local v = tonumber(dialog:getInputText())
                    if v and v > 0 then
                        ReadingVault.setYearlyGoal(v)
                        UIManager:show(InfoMessage:new{
                            text    = T(_("Yearly goal set to %1 books."), v),
                            timeout = 2,
                        })
                    end
                    UIManager:close(dialog)
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

-- ── ClipSync UI helpers ───────────────────────────────────────────────────────

function InkFire:openClipSearch()
    ClipSync = ClipSync or loadModule("clipsync")
    if not ClipSync then return end
    local dialog
    dialog = InputDialog:new{
        title   = _("Search highlights"),
        input   = "",
        buttons = {{
            {
                text     = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text             = _("Search"),
                is_enter_default = true,
                callback         = function()
                    local q = dialog:getInputText()
                    UIManager:close(dialog)
                    if q and q ~= "" then
                        self:showClipSearchResults(q)
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

function InkFire:showClipSearchResults(query)
    ClipSync = ClipSync or loadModule("clipsync")
    if not ClipSync then return end
    local results = ClipSync.searchHighlights(query)
    if #results == 0 then
        UIManager:show(InfoMessage:new{
            text    = T(_("No results for: %1"), query),
            timeout = 2,
        })
        return
    end

    local items = {}
    for _, h in ipairs(results) do
        local preview = h.text:sub(1, 60) .. (h.text:len() > 60 and "…" or "")
        local h_ref   = h
        table.insert(items, {
            text      = preview,
            mandatory = h.book_title,
            callback  = function()
                UIManager:show(InfoMessage:new{
                    text = ('"' .. h_ref.text .. '"\n\n— ' .. (h_ref.book_title or "")),
                })
            end,
        })
    end

    local results_menu = Menu:new{
        title          = T(_("Results: %1 (%2)"), query, #results),
        item_table     = items,
        is_borderless  = true,
        width          = Screen:getWidth(),
        height         = Screen:getHeight(),
        close_callback = function() UIManager:close(results_menu) end,
    }
    UIManager:show(results_menu)
end

function InkFire:maybeShowDailyMemory()
    ClipSync = ClipSync or loadModule("clipsync")
    if not ClipSync then return end
    local h = ClipSync.getDailyMemory()
    if h then
        UIManager:show(InfoMessage:new{
            text    = T(_("💭 Memory\n\n\"%1\"\n\n— %2"), h.text, h.book_title),
            timeout = 8,
        })
    end
end

-- ── SeriesOS UI helpers ───────────────────────────────────────────────────────

function InkFire:openSeriesBrowser(filter)
    SeriesOS = SeriesOS or loadModule("seriosos")
    if not SeriesOS then return end

    UIManager:show(InfoMessage:new{
        text    = _("Loading library…"),
        timeout = 0.5,
    })

    if not self._seriesos_groups then
        self._seriesos_groups = SeriesOS.getGrouped()
    end

    local items = self:buildSeriesMenuItems(self._seriesos_groups, filter or "all")

    if #items == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No series found.\nMake sure KOReader has scanned your library."),
        })
        return
    end

    local label = ({
        all         = _("All Series"),
        unread      = _("Unread"),
        in_progress = _("In Progress"),
        complete    = _("Complete"),
    })[filter or "all"] or _("Series")

    local browser = Menu:new{
        title          = "SeriesOS — " .. label,
        item_table     = items,
        is_borderless  = true,
        is_popout      = false,
        width          = Screen:getWidth(),
        height         = Screen:getHeight(),
        close_callback = function() UIManager:close(browser) end,
    }
    UIManager:show(browser)
end

function InkFire:buildSeriesMenuItems(groups, filter)
    local items = {}
    for _, group in ipairs(groups) do
        local visible = SeriesOS.filterVolumes(group.volumes, filter)
        if #visible > 0 then
            local parts = {}
            if group.vol_range ~= "" then table.insert(parts, group.vol_range) end
            if group.unread      > 0 then table.insert(parts, group.unread      .. " unread")  end
            if group.in_progress > 0 then table.insert(parts, group.in_progress .. " reading") end
            if group.complete    > 0 then table.insert(parts, group.complete    .. " done")    end
            if group.total_time  > 0 then
                local hrs = math.floor(group.total_time / 3600)
                if hrs > 0 then table.insert(parts, hrs .. "h read") end
            end
            local g_ref   = group
            local vis_ref = visible
            table.insert(items, {
                text      = group.name,
                mandatory = table.concat(parts, " · "),
                callback  = function() self:openVolumeList(g_ref, vis_ref) end,
            })
        end
    end
    return items
end

function InkFire:openVolumeList(group, volumes)
    local items = {}
    for _, vol in ipairs(volumes) do
        local prefix = ({ unread = "○ ", in_progress = "◐ ", complete = "● " })[vol.status] or "  "
        local progress = ""
        if vol.pages and vol.pages > 0 then
            progress = math.floor((vol.read_pages / vol.pages) * 100) .. "%"
        end
        if vol.read_time > 60 then
            local mins = math.floor(vol.read_time / 60)
            progress = progress .. (mins >= 60
                and ("  %dh%dm"):format(math.floor(mins/60), mins%60)
                or  "  " .. mins .. "m")
        end
        local vol_ref = vol
        table.insert(items, {
            text          = prefix .. (vol.title ~= "" and vol.title or vol.filename),
            mandatory     = progress,
            callback      = function() self:openVolume(vol_ref) end,
            hold_callback = function() self:showVolumeOptions(vol_ref) end,
        })
    end

    local vol_menu = Menu:new{
        title          = group.name .. " — " .. #volumes .. " volumes",
        item_table     = items,
        is_borderless  = true,
        is_popout      = false,
        width          = Screen:getWidth(),
        height         = Screen:getHeight(),
        close_callback = function() UIManager:close(vol_menu) end,
    }
    UIManager:show(vol_menu)
end

function InkFire:openVolume(vol)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and not lfs.attributes(vol.path, "mode") then
        UIManager:show(InfoMessage:new{
            text = T(_("File not found:\n%1"), vol.path),
        })
        return
    end
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok and ReaderUI then
        ReaderUI:showReader(vol.path)
    else
        local ok2, FM = pcall(require, "apps/filemanager/filemanager")
        if ok2 and FM and FM.instance then FM.instance:onFileOpen(vol.path) end
    end
end

function InkFire:showVolumeOptions(vol)
    SeriesOS = SeriesOS or loadModule("seriosos")
    if not SeriesOS then return end
    local canonical    = SeriesOS.canonicalFilename(vol)
    local rename_label = (vol.filename ~= canonical)
        and T(_("Rename → %1"), canonical)
        or  _("Already canonical name")

    self._vol_options = ButtonDialogTitle:new{
        title = vol.title ~= "" and vol.title or vol.filename,
        buttons = {
            {{
                text     = rename_label,
                enabled  = (vol.filename ~= canonical),
                callback = function()
                    UIManager:close(self._vol_options)
                    local res = SeriesOS.renameVolume(vol, canonical)
                    if res.ok then
                        self._seriesos_groups = nil
                        UIManager:show(InfoMessage:new{
                            text    = T(_("Renamed to:\n%1"), canonical),
                            timeout = 2,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = T(_("Rename failed: %1"), res.error),
                        })
                    end
                end,
            }},
            {{
                text     = _("Mark Complete"),
                callback = function()
                    UIManager:close(self._vol_options)
                    SeriesOS.markComplete(vol)
                    vol.status = "complete"
                    UIManager:show(InfoMessage:new{
                        text    = T(_("Marked complete: %1"), vol.title),
                        timeout = 2,
                    })
                end,
            }, {
                text     = _("Open"),
                callback = function()
                    UIManager:close(self._vol_options)
                    self:openVolume(vol)
                end,
            }},
            {{
                text     = _("Close"),
                callback = function() UIManager:close(self._vol_options) end,
            }},
        },
    }
    UIManager:show(self._vol_options)
end

function InkFire:showDuplicates()
    SeriesOS = SeriesOS or loadModule("seriosos")
    if not SeriesOS then return end
    local groups = self._seriosos_groups or SeriesOS.getGrouped()
    local dupes  = SeriesOS.findDuplicates(groups)

    if #dupes == 0 then
        UIManager:show(InfoMessage:new{ text = _("No duplicates found.") })
        return
    end

    local items = {}
    for _, d in ipairs(dupes) do
        local reason = d.reason == "same_md5" and _("identical file") or _("same title + size")
        local d_ref  = d
        table.insert(items, {
            text      = d.a.filename .. "\n= " .. d.b.filename,
            mandatory = reason,
            callback  = function()
                UIManager:show(ConfirmBox:new{
                    text       = T(_("Delete duplicate?\n\n%1\n\n(keeps: %2)"), d_ref.b.path, d_ref.a.path),
                    ok_text    = _("Delete"),
                    ok_callback = function()
                        local ok, err = os.remove(d_ref.b.path)
                        self._seriosos_groups = nil
                        if ok then
                            UIManager:show(InfoMessage:new{
                                text    = T(_("Deleted: %1"), d_ref.b.filename),
                                timeout = 2,
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = T(_("Delete failed: %1"), tostring(err)),
                            })
                        end
                    end,
                })
            end,
        })
    end

    local dupe_menu = Menu:new{
        title          = T(_("Duplicates (%1)"), #dupes),
        item_table     = items,
        is_borderless  = true,
        width          = Screen:getWidth(),
        height         = Screen:getHeight(),
        close_callback = function() UIManager:close(dupe_menu) end,
    }
    UIManager:show(dupe_menu)
end

-- ── Main menu ─────────────────────────────────────────────────────────────────

function InkFire:addToMainMenu(menu_items)
    menu_items.inkfire = {
        text = _("InkFire"),
        sub_item_table = {
            self:buildMangaFlowMenu(),
            self:buildSeriesOSMenu(),
            self:buildTransferBridgeMenu(),
            self:buildReadingVaultMenu(),
            self:buildPowerGuardMenu(),
            self:buildClipSyncMenu(),
        },
    }
end

-- ── MangaFlow menu ────────────────────────────────────────────────────────────

function InkFire:buildMangaFlowMenu()
    return {
        text = _("MangaFlow"),
        sub_item_table = {
            {
                text_func = function()
                    return self._mf_is_manga
                        and _("Manga Mode: ON  ✓")
                        or  _("Manga Mode: off")
                end,
                callback = function()
                    MangaFlow = MangaFlow or loadModule("mangaflow")
                    if not MangaFlow then return end
                    local new_val = not self._mf_is_manga
                    self._mf_is_manga = MangaFlow.toggleMangaMode(self._mf_series_name, new_val)
                    if self._mf_is_manga then
                        self._mf_settings = MangaFlow.getSettings(self._mf_series_name)
                        self:applyMangaSettings(self._mf_settings)
                        self:showHUD()
                    else
                        self:removeHUD()
                        local doc = self.ui and self.ui.document
                        if doc and doc.setReadingOrder then
                            pcall(function() doc:setReadingOrder(0) end)
                        end
                    end
                end,
                keep_menu_open = true,
            },
            {
                text_func = function()
                    local s = self._mf_settings or {}
                    return s.spread == 1
                        and _("Auto Spread: ON  ✓")
                        or  _("Auto Spread: off")
                end,
                enabled_func = function() return self._mf_is_manga end,
                callback = function()
                    MangaFlow = MangaFlow or loadModule("mangaflow")
                    if not MangaFlow then return end
                    local new_spread = MangaFlow.toggleSpread(self._mf_series_name, self._mf_settings)
                    self._mf_settings = MangaFlow.getSettings(self._mf_series_name)
                    if new_spread == 0 then self:exitSpreadMode() end
                end,
                keep_menu_open = true,
            },
            {
                text = _("Reset Series Settings"),
                enabled_func = function() return self._mf_series_name ~= nil end,
                callback = function()
                    MangaFlow = MangaFlow or loadModule("mangaflow")
                    if MangaFlow then
                        MangaFlow.resetSettings(self._mf_series_name)
                        UIManager:show(InfoMessage:new{
                            text    = T(_("Reset settings for: %1"), self._mf_series_name or ""),
                            timeout = 2,
                        })
                    end
                end,
            },
            {
                text_func    = function() return ("Series: %s"):format(self._mf_series_name or "—") end,
                enabled_func = function() return false end,
            },
        },
    }
end

-- ── SeriesOS menu ─────────────────────────────────────────────────────────────

function InkFire:buildSeriesOSMenu()
    return {
        text = _("SeriesOS"),
        sub_item_table = {
            {
                text     = _("Browse by Series"),
                callback = function() self:openSeriesBrowser("all") end,
            },
            {
                text     = _("▸ Unread"),
                callback = function() self:openSeriesBrowser("unread") end,
            },
            {
                text     = _("▸ In Progress"),
                callback = function() self:openSeriesBrowser("in_progress") end,
            },
            {
                text     = _("▸ Complete"),
                callback = function() self:openSeriesBrowser("complete") end,
            },
            { text = "---" },
            {
                text     = _("Find Duplicates"),
                callback = function() self:showDuplicates() end,
            },
            {
                text     = _("Auto-Rename Files…"),
                callback = function() self:showRenamePreview() end,
            },
            {
                text     = _("Refresh Library Cache"),
                callback = function()
                    self._seriesos_groups = nil
                    UIManager:show(InfoMessage:new{
                        text    = _("Library cache cleared. Re-open browser to reload."),
                        timeout = 2,
                    })
                end,
            },
        },
    }
end

function InkFire:showRenamePreview()
    SeriesOS = SeriesOS or loadModule("seriosos")
    if not SeriesOS then return end
    local groups  = self._seriosos_groups or SeriesOS.getGrouped()
    local pending = SeriesOS.getPendingRenames(groups)

    if #pending == 0 then
        UIManager:show(InfoMessage:new{
            text = _("All files already use canonical names."),
        })
        return
    end

    local lines = {}
    for i = 1, math.min(5, #pending) do
        table.insert(lines, pending[i].vol.filename .. "\n  → " .. pending[i].new_name)
    end
    local extra = (#pending > 5) and ("\n…and " .. (#pending - 5) .. " more") or ""

    UIManager:show(ConfirmBox:new{
        text       = T(_("Rename %1 files?\n\n%2%3"), #pending, table.concat(lines, "\n"), extra),
        ok_text    = _("Rename All"),
        ok_callback = function()
            local done, failed = 0, 0
            for _, p in ipairs(pending) do
                local res = SeriesOS.renameVolume(p.vol, p.new_name)
                if res.ok then done = done + 1 else failed = failed + 1 end
            end
            self._seriesos_groups = nil
            UIManager:show(InfoMessage:new{
                text    = T(_("Renamed %1 files. %2 skipped."), done, failed),
                timeout = 3,
            })
        end,
    })
end

-- ── TransferBridge menu ───────────────────────────────────────────────────────

function InkFire:buildTransferBridgeMenu()
    return {
        text = _("TransferBridge"),
        sub_item_table = {
            {
                text_func = function()
                    TransferBridge = TransferBridge or loadModule("transferbridge")
                    local running = TransferBridge and TransferBridge.isRunning()
                    return running and _("Stop Transfer Server") or _("Start Transfer Server")
                end,
                callback = function()
                    TransferBridge = TransferBridge or loadModule("transferbridge")
                    if not TransferBridge then return end
                    if TransferBridge.isRunning() then
                        TransferBridge.stop()
                        UIManager:show(InfoMessage:new{
                            text    = _("TransferBridge stopped."),
                            timeout = 2,
                        })
                    else
                        if not NetworkMgr:isConnected() then
                            NetworkMgr:beforeWifiAction(function()
                                self:startTransferBridge()
                            end)
                        else
                            self:startTransferBridge()
                        end
                    end
                end,
            },
            {
                text         = _("Show Transfer URL"),
                enabled_func = function()
                    return TransferBridge and TransferBridge.isRunning()
                end,
                callback = function()
                    if not TransferBridge then return end
                    local url = ("http://%s:8765"):format(TransferBridge.getDeviceIP())
                    UIManager:show(InfoMessage:new{
                        text = T(_("TransferBridge\n\n%1\n\nOpen in browser or scan QR."), url),
                    })
                end,
                keep_menu_open = true,
            },
        },
    }
end

function InkFire:startTransferBridge()
    TransferBridge = TransferBridge or loadModule("transferbridge")
    if not TransferBridge then return end
    local result = TransferBridge.start(PLUGIN_DIR, "/mnt/onboard")
    if result.error then
        UIManager:show(InfoMessage:new{
            text = T(_("TransferBridge: could not start — %1"), result.error),
        })
    else
        UIManager:show(InfoMessage:new{
            text = T(_("TransferBridge\n\n%1\n\nOpen in browser or scan QR."), result.url),
        })
        -- Start fast poll loop
        UIManager:scheduleIn(0.15, function() self:transferPoll() end)
    end
end

-- ── ReadingVault menu ─────────────────────────────────────────────────────────

function InkFire:buildReadingVaultMenu()
    return {
        text = _("ReadingVault"),
        sub_item_table = {
            {
                text_func = function()
                    ReadingVault = ReadingVault or loadModule("readingvault")
                    local goal = ReadingVault and ReadingVault.getDailyGoalMinutes() or 30
                    return T(_("Daily goal: %1 min"), goal)
                end,
                callback       = function() self:editDailyGoal() end,
                keep_menu_open = true,
            },
            {
                text_func = function()
                    ReadingVault = ReadingVault or loadModule("readingvault")
                    local goal = ReadingVault and ReadingVault.getYearlyGoal() or 50
                    return T(_("Yearly goal: %1 books"), goal)
                end,
                callback       = function() self:editYearlyGoal() end,
                keep_menu_open = true,
            },
            {
                text = _("Today's Stats"),
                callback = function()
                    ReadingVault = ReadingVault or loadModule("readingvault")
                    if not ReadingVault then return end
                    local stats = ReadingVault.getTodayStats()
                    UIManager:show(InfoMessage:new{
                        text = T(_("Today: %1 min (%2%% of goal)\nStreak: %3 days"),
                            stats.minutes, stats.pct, stats.streak),
                    })
                end,
            },
        },
    }
end

-- ── PowerGuard menu ───────────────────────────────────────────────────────────

function InkFire:buildPowerGuardMenu()
    return {
        text = _("PowerGuard"),
        sub_item_table = {
            {
                text = _("Sleep Profiles"),
                sub_item_table = {
                    self:buildProfileItem("reading", _("Reading (5 min)")),
                    self:buildProfileItem("manga",   _("Manga (10 min)")),
                    self:buildProfileItem("night",   _("Night (2 min)")),
                    self:buildProfileItem("off",     _("Never sleep")),
                },
            },
            {
                text_func = function()
                    PowerGuard = PowerGuard or loadModule("powerguard")
                    local on = PowerGuard and State and State.get("powerguard.schedule_on")
                    return on and _("Brightness Schedule: ON  ✓") or _("Brightness Schedule: off")
                end,
                callback = function()
                    PowerGuard = PowerGuard or loadModule("powerguard")
                    if not PowerGuard then return end
                    local on = PowerGuard.toggleSchedule()
                    UIManager:show(InfoMessage:new{
                        text    = on and _("Brightness schedule enabled.")
                                     or  _("Brightness schedule disabled."),
                        timeout = 2,
                    })
                end,
                keep_menu_open = true,
            },
            {
                text = _("Battery Status"),
                callback = function()
                    PowerGuard = PowerGuard or loadModule("powerguard")
                    if not PowerGuard then return end
                    local info = PowerGuard.getBatteryInfo()
                    UIManager:show(InfoMessage:new{
                        text = T(_("Battery: %1%%\nLow battery mode: %2"),
                            info.pct, info.low_mode and _("ON") or _("off")),
                    })
                end,
            },
            {
                text_func = function()
                    PowerGuard = PowerGuard or loadModule("powerguard")
                    if not PowerGuard then return "Device: unknown" end
                    local info = PowerGuard.getDeviceInfo()
                    return info.is_clara_bw
                        and _("Device: Clara BW ✓")
                        or  ("Device: " .. info.model)
                end,
                enabled_func = function() return false end,
            },
        },
    }
end

function InkFire:buildProfileItem(key, label)
    return {
        text_func = function()
            PowerGuard = PowerGuard or loadModule("powerguard")
            local active = PowerGuard and PowerGuard.getActiveProfile() or "reading"
            return (active == key and "✓ " or "  ") .. label
        end,
        callback = function()
            PowerGuard = PowerGuard or loadModule("powerguard")
            if not PowerGuard then return end
            local result = PowerGuard.applyProfile(key)
            if result then
                UIManager:show(InfoMessage:new{
                    text    = T(_("PowerGuard: %1 profile active"), result.name),
                    timeout = 2,
                })
            end
        end,
        keep_menu_open = true,
    }
end

-- ── ClipSync menu ─────────────────────────────────────────────────────────────

function InkFire:buildClipSyncMenu()
    return {
        text = _("ClipSync"),
        sub_item_table = {
            {
                text_func = function()
                    ClipSync = ClipSync or loadModule("clipsync")
                    local n = ClipSync and ClipSync.getHighlightCount() or 0
                    return T(_("Search Highlights (%1)"), n)
                end,
                callback = function() self:openClipSearch() end,
            },
            {
                text = _("Sync from Device"),
                callback = function()
                    ClipSync = ClipSync or loadModule("clipsync")
                    if not ClipSync then return end
                    local result = ClipSync.syncFromSidecars()
                    if not result.has_library then
                        UIManager:show(InfoMessage:new{
                            text    = _("ClipSync: /mnt/onboard not found. Run on device."),
                            timeout = 3,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text    = T(_("ClipSync: imported %1 new highlights."), result.count),
                            timeout = 3,
                        })
                    end
                end,
            },
            {
                text = _("Export"),
                sub_item_table = {
                    {
                        text = _("Obsidian Markdown"),
                        callback = function()
                            ClipSync = ClipSync or loadModule("clipsync")
                            if not ClipSync then return end
                            local result = ClipSync.exportToObsidian()
                            if result.error then
                                UIManager:show(InfoMessage:new{
                                    text = T(_("Export failed: %1"), result.error),
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text    = T(_("Exported to:\n%1"), result.path),
                                    timeout = 4,
                                })
                            end
                        end,
                    },
                    {
                        text = _("Readwise CSV"),
                        callback = function()
                            ClipSync = ClipSync or loadModule("clipsync")
                            if not ClipSync then return end
                            local result = ClipSync.exportToReadwise()
                            if result.error then
                                UIManager:show(InfoMessage:new{
                                    text = T(_("Export failed: %1"), result.error),
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text    = T(_("Readwise CSV exported to:\n%1"), result.path),
                                    timeout = 4,
                                })
                            end
                        end,
                    },
                },
            },
            {
                text = _("Daily Memory"),
                callback = function()
                    ClipSync = ClipSync or loadModule("clipsync")
                    if not ClipSync then return end
                    local h = ClipSync.getRandomHighlight()
                    if h then
                        UIManager:show(InfoMessage:new{
                            text = T(_("💭 Memory\n\n\"%1\"\n\n— %2"), h.text, h.book_title),
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text    = _("No highlights yet. Sync first."),
                            timeout = 2,
                        })
                    end
                end,
            },
        },
    }
end

return InkFire
