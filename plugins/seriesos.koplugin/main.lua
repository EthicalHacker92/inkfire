--[[
SeriesOS — series library browser for KOReader
Groups your flat file library into series shelves pulled from
bookinfo_cache.sqlite3. Throttled cover loading, reading-status tabs,
duplicate detection, and auto-rename.
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local ConfirmBox      = require("ui/widget/confirmbox")
local Menu            = require("ui/widget/menu")
local InputDialog     = require("ui/widget/inputdialog")
local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
local lfs             = require("libs/libkoreader-lfs")
local logger          = require("logger")
local _               = require("gettext")
local T               = require("ffi/util").template

local SeriesDB        = require("series_db")

-- ── Constants ─────────────────────────────────────────────────────────────────

local COVERS_PER_TICK = 5     -- max covers loaded per 200ms tick
local COVER_TICK_MS   = 0.2   -- seconds between cover batches

-- Status filter keys (must match SeriesDB.STATUS values)
local FILTER_ALL     = "all"
local FILTER_UNREAD  = "unread"
local FILTER_READING = "in_progress"
local FILTER_DONE    = "complete"

-- ── Plugin class ──────────────────────────────────────────────────────────────

local SeriesOS = WidgetContainer:extend{
    name           = "seriesos",
    groups         = nil,    -- cached series groups from SeriesDB
    cover_queue    = nil,    -- pending cover-load items
    cover_loading  = false,  -- throttle guard
    active_filter  = FILTER_ALL,
}

function SeriesOS:init()
    self.cover_queue = {}
    self.ui.menu:registerToMainMenu(self)
end

-- ── Main menu entry ───────────────────────────────────────────────────────────

function SeriesOS:addToMainMenu(menu_items)
    menu_items.seriesos = {
        text = _("SeriesOS"),
        sub_item_table = {
            {
                text     = _("Browse by Series"),
                callback = function() self:openSeriesBrowser(FILTER_ALL) end,
            },
            {
                text     = _("▸ Unread"),
                callback = function() self:openSeriesBrowser(FILTER_UNREAD) end,
            },
            {
                text     = _("▸ In Progress"),
                callback = function() self:openSeriesBrowser(FILTER_READING) end,
            },
            {
                text     = _("▸ Complete"),
                callback = function() self:openSeriesBrowser(FILTER_DONE) end,
            },
            { text = "---" },   -- separator
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
                    self.groups = nil
                    UIManager:show(InfoMessage:new{
                        text    = _("Library cache cleared. Re-open browser to reload."),
                        timeout = 2,
                    })
                end,
            },
        },
    }
end

-- ── Series browser ────────────────────────────────────────────────────────────

function SeriesOS:openSeriesBrowser(filter)
    self.active_filter = filter or FILTER_ALL

    -- Load groups if not cached
    if not self.groups then
        UIManager:show(InfoMessage:new{
            text    = _("Loading library…"),
            timeout = 0.5,
        })
        self.groups = SeriesDB.getGrouped()
    end

    local items = self:buildSeriesMenuItems(self.groups, self.active_filter)

    if #items == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No series found.\nMake sure KOReader has scanned your library."),
        })
        return
    end

    local filter_label = ({
        [FILTER_ALL]     = _("All Series"),
        [FILTER_UNREAD]  = _("Unread"),
        [FILTER_READING] = _("In Progress"),
        [FILTER_DONE]    = _("Complete"),
    })[self.active_filter] or _("Series")

    local browser = Menu:new{
        title        = "SeriesOS — " .. filter_label,
        item_table   = items,
        is_borderless = true,
        is_popout     = false,
        width         = require("device/screen"):getWidth(),
        height        = require("device/screen"):getHeight(),
        close_callback = function() UIManager:close(browser) end,
    }
    UIManager:show(browser)
end

function SeriesOS:buildSeriesMenuItems(groups, filter)
    local items = {}

    for _, group in ipairs(groups) do
        -- Apply reading status filter
        local visible_vols = self:filterVolumes(group.volumes, filter)
        if #visible_vols == 0 then goto continue end

        -- Build subtitle: "Vol 1–47 · 12 unread · 3 reading"
        local parts = {}
        if group.vol_range ~= "" then table.insert(parts, group.vol_range) end
        if group.unread      > 0  then table.insert(parts, group.unread .. " unread")   end
        if group.in_progress > 0  then table.insert(parts, group.in_progress .. " reading") end
        if group.complete    > 0  then table.insert(parts, group.complete .. " done")   end
        if group.total_time  > 0  then
            local hrs = math.floor(group.total_time / 3600)
            if hrs > 0 then table.insert(parts, hrs .. "h read") end
        end

        local subtitle = table.concat(parts, " · ")

        local g_ref = group  -- capture for closure
        table.insert(items, {
            text      = group.name,
            mandatory = subtitle,
            callback  = function()
                self:openVolumeList(g_ref, visible_vols)
            end,
        })

        ::continue::
    end

    return items
end

function SeriesOS:filterVolumes(volumes, filter)
    if filter == FILTER_ALL then return volumes end
    local out = {}
    for _, v in ipairs(volumes) do
        if v.status == filter then table.insert(out, v) end
    end
    return out
end

-- ── Volume list ───────────────────────────────────────────────────────────────

function SeriesOS:openVolumeList(group, volumes)
    local items = {}

    for _, vol in ipairs(volumes) do
        -- Status indicator prefix
        local prefix = ({
            unread      = "○ ",
            in_progress = "◐ ",
            complete    = "● ",
        })[vol.status] or "  "

        -- Progress string
        local progress = ""
        if vol.pages and vol.pages > 0 then
            local pct = math.floor((vol.read_pages / vol.pages) * 100)
            progress = pct .. "%"
        end

        -- Time invested
        if vol.read_time > 60 then
            local mins = math.floor(vol.read_time / 60)
            if mins >= 60 then
                progress = progress .. ("  %dh%dm"):format(
                    math.floor(mins / 60), mins % 60)
            else
                progress = progress .. "  " .. mins .. "m"
            end
        end

        local vol_ref = vol
        table.insert(items, {
            text      = prefix .. (vol.title ~= "" and vol.title or vol.filename),
            mandatory = progress,
            callback  = function()
                self:openVolume(vol_ref)
            end,
            hold_callback = function()
                self:showVolumeOptions(vol_ref)
            end,
        })
    end

    local vol_menu = Menu:new{
        title         = group.name .. " — " .. #volumes .. " volumes",
        item_table    = items,
        is_borderless  = true,
        is_popout      = false,
        width          = require("device/screen"):getWidth(),
        height         = require("device/screen"):getHeight(),
        close_callback = function() UIManager:close(vol_menu) end,
    }
    UIManager:show(vol_menu)
end

-- ── Open a volume in the reader ───────────────────────────────────────────────

function SeriesOS:openVolume(vol)
    if not lfs.attributes(vol.path, "mode") then
        UIManager:show(InfoMessage:new{
            text = T(_("File not found:\n%1"), vol.path),
        })
        return
    end

    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok and ReaderUI then
        ReaderUI:showReader(vol.path)
    else
        -- Fallback: open via FileManager
        local ok2, FM = pcall(require, "apps/filemanager/filemanager")
        if ok2 and FM and FM.instance then
            FM.instance:onFileOpen(vol.path)
        end
    end
end

-- ── Per-volume options (hold-tap) ─────────────────────────────────────────────

function SeriesOS:showVolumeOptions(vol)
    local canonical = SeriesDB.canonicalFilename(vol)
    local rename_label = (vol.filename ~= canonical)
        and T(_("Rename → %1"), canonical)
        or  _("Already canonical name")

    UIManager:show(ButtonDialogTitle:new{
        title = vol.title ~= "" and vol.title or vol.filename,
        buttons = {
            {
                {
                    text     = rename_label,
                    enabled  = (vol.filename ~= canonical),
                    callback = function()
                        UIManager:close(self._vol_options)
                        self:renameVolume(vol, canonical)
                    end,
                },
            },
            {
                {
                    text     = _("Mark Complete"),
                    callback = function()
                        UIManager:close(self._vol_options)
                        -- Write a full-read entry so status becomes complete
                        self:markComplete(vol)
                    end,
                },
                {
                    text     = _("Open"),
                    callback = function()
                        UIManager:close(self._vol_options)
                        self:openVolume(vol)
                    end,
                },
            },
            {
                {
                    text     = _("Close"),
                    callback = function() UIManager:close(self._vol_options) end,
                },
            },
        },
    })
end

-- ── Rename ────────────────────────────────────────────────────────────────────

function SeriesOS:renameVolume(vol, new_name)
    local new_path = vol.directory .. new_name

    if lfs.attributes(new_path, "mode") then
        UIManager:show(InfoMessage:new{
            text = T(_("Cannot rename: %1 already exists."), new_name),
        })
        return
    end

    local ok, err = os.rename(vol.path, new_path)
    if ok then
        vol.path     = new_path
        vol.filename = new_name
        self.groups  = nil   -- invalidate cache so next open re-reads
        UIManager:show(InfoMessage:new{
            text    = T(_("Renamed to:\n%1"), new_name),
            timeout = 2,
        })
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Rename failed: %1"), tostring(err)),
        })
    end
end

function SeriesOS:showRenamePreview()
    local groups = self.groups or SeriesDB.getGrouped()
    local pending = {}

    for _, group in ipairs(groups) do
        for _, vol in ipairs(group.volumes) do
            local canonical = SeriesDB.canonicalFilename(vol)
            if vol.filename ~= canonical then
                table.insert(pending, { vol = vol, new_name = canonical })
            end
        end
    end

    if #pending == 0 then
        UIManager:show(InfoMessage:new{
            text = _("All files already use canonical names."),
        })
        return
    end

    -- Show a sample of what will change
    local preview_lines = {}
    for i = 1, math.min(5, #pending) do
        local p = pending[i]
        table.insert(preview_lines,
            p.vol.filename .. "\n  → " .. p.new_name)
    end
    local extra = (#pending > 5) and ("\n…and " .. (#pending - 5) .. " more") or ""

    UIManager:show(ConfirmBox:new{
        text = T(_("Rename %1 files?\n\n%2%3"),
            #pending,
            table.concat(preview_lines, "\n"),
            extra),
        ok_text = _("Rename All"),
        ok_callback = function()
            local done, failed = 0, 0
            for _, p in ipairs(pending) do
                local new_path = p.vol.directory .. p.new_name
                if not lfs.attributes(new_path, "mode") then
                    local ok = os.rename(p.vol.path, new_path)
                    if ok then done = done + 1 else failed = failed + 1 end
                else
                    failed = failed + 1
                end
            end
            self.groups = nil  -- invalidate cache
            UIManager:show(InfoMessage:new{
                text = T(_("Renamed %1 files. %2 skipped."), done, failed),
            })
        end,
    })
end

-- ── Mark complete ─────────────────────────────────────────────────────────────

function SeriesOS:markComplete(vol)
    -- Write a statistics entry marking this book as fully read
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok then return end

    local stats_path = require("datastorage"):getDataDir() .. "/statistics.sqlite3"
    local db_ok, db = pcall(SQ3.open, stats_path)
    if not db_ok then return end

    pcall(function()
        -- Update existing entry or create one
        db:exec(
            "UPDATE book SET total_read_pages = pages WHERE md5 = ?;",
            vol.md5
        )
    end)
    db:close()

    vol.status     = SeriesDB.STATUS.COMPLETE
    vol.read_pages = vol.pages
    UIManager:show(InfoMessage:new{
        text = T(_("Marked complete: %1"), vol.title),
        timeout = 2,
    })
end

-- ── Duplicate detector ────────────────────────────────────────────────────────

function SeriesOS:showDuplicates()
    local groups = self.groups or SeriesDB.getGrouped()
    local dupes  = SeriesDB.findDuplicates(groups)

    if #dupes == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No duplicates found."),
        })
        return
    end

    local items = {}
    for _, d in ipairs(dupes) do
        local reason = d.reason == "same_md5"
            and _("identical file")
            or  _("same title + size")
        table.insert(items, {
            text = d.a.filename .. "\n= " .. d.b.filename,
            mandatory = reason,
            callback  = function()
                self:showDupeOptions(d)
            end,
        })
    end

    local dupe_menu = Menu:new{
        title         = T(_("Duplicates (%1)"), #dupes),
        item_table    = items,
        is_borderless  = true,
        width          = require("device/screen"):getWidth(),
        height         = require("device/screen"):getHeight(),
        close_callback = function() UIManager:close(dupe_menu) end,
    }
    UIManager:show(dupe_menu)
end

function SeriesOS:showDupeOptions(dupe)
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete duplicate?\n\n%1\n\n(keeps: %2)"),
            dupe.b.path, dupe.a.path),
        ok_text = _("Delete"),
        ok_callback = function()
            local ok, err = os.remove(dupe.b.path)
            if ok then
                self.groups = nil
                UIManager:show(InfoMessage:new{
                    text    = T(_("Deleted: %1"), dupe.b.filename),
                    timeout = 2,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = T(_("Delete failed: %1"), tostring(err)),
                })
            end
        end,
    })
end

-- ── Throttled cover cache ─────────────────────────────────────────────────────
-- KOReader's bookinfo_cache stores cover images. Reading them all at once
-- freezes the UI. We process COVERS_PER_TICK per scheduler tick.

function SeriesOS:queueCoverLoad(items)
    for _, item in ipairs(items) do
        table.insert(self.cover_queue, item)
    end
    if not self.cover_loading then
        self.cover_loading = true
        UIManager:scheduleIn(COVER_TICK_MS, function() self:processCoverBatch() end)
    end
end

function SeriesOS:processCoverBatch()
    local batch_count = 0

    while #self.cover_queue > 0 and batch_count < COVERS_PER_TICK do
        local item = table.remove(self.cover_queue, 1)
        self:loadOneCover(item)
        batch_count = batch_count + 1
    end

    if #self.cover_queue > 0 then
        -- More to load — schedule next batch
        UIManager:scheduleIn(COVER_TICK_MS, function() self:processCoverBatch() end)
    else
        self.cover_loading = false
    end
end

function SeriesOS:loadOneCover(item)
    -- KOReader's BookInfoManager provides cover blitbuffers
    local ok, BIM = pcall(require, "ui/widget/bookinfowidget")
    if not ok then return end
    -- Cover loading is handled by KOReader's existing cover cache;
    -- we call it here so it runs throttled rather than all at once.
    pcall(function()
        BIM:getCoverImage(item.path)
    end)
end

return SeriesOS
