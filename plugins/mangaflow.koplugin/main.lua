--[[
MangaFlow — Auto RTL, per-series settings, double-page spreads, progress HUD
Hooks into ReaderUI to detect manga mode, apply per-series preferences,
and show a progress HUD in the reader footer.
--]]

local WidgetContainer  = require("ui/widget/container/widgetcontainer")
local UIManager        = require("ui/uimanager")
local InfoMessage      = require("ui/widget/infomessage")
local ConfirmBox       = require("ui/widget/confirmbox")
local TextWidget       = require("ui/widget/textwidget")
local FrameContainer   = require("ui/widget/container/framecontainer")
local Blitbuffer       = require("ffi/blitbuffer")
local Font             = require("ui/font")
local Screen           = require("device/screen")
local logger           = require("logger")
local lfs              = require("libs/libkoreader-lfs")
local SQ3              = require("lua-ljsqlite3/init")
local DataStorage      = require("datastorage")
local _                = require("gettext")
local T                = require("ffi/util").template

local SeriesSettings   = require("series_settings")

-- ── Constants ─────────────────────────────────────────────────────────────────

-- Patterns in filenames that hint "this is manga"
local MANGA_FILENAME_HINTS = {
    "%[manga%]", "%(manga%)", "manga_", "_manga",
    "%[JP%]", "%[ja%]",
}

-- Kobo Clara BW bookinfo cache (populated by KOReader's scanner)
local BOOKINFO_DB = DataStorage:getDataDir() .. "/bookinfo_cache.sqlite3"

-- ── Plugin class ──────────────────────────────────────────────────────────────

local MangaFlow = WidgetContainer:extend{
    name          = "mangaflow",
    is_manga      = false,
    series_name   = nil,
    current_page  = 0,
    total_pages   = 0,
    settings      = nil,   -- SeriesSettings table for current book
    hud_widget    = nil,
    -- Spread tracking
    spread_mode   = false,   -- true while two-page spread is active
    spread_counts = nil,     -- { spreads=N, total=N } sampled at open
}

function MangaFlow:init()
    self.ui.menu:registerToMainMenu(self)
end

-- ── KOReader event hooks ──────────────────────────────────────────────────────

--- Called when the reader finishes opening a document.
function MangaFlow:onReaderReady()
    self:detectAndApply()
end

--- Called on every page turn — update HUD and handle spreads.
function MangaFlow:onPageUpdate(pageno)
    self.current_page = pageno
    self:updateHUD()
    if self.is_manga then
        self:handleSpread(pageno)
    end
end

--- Called when the document closes — clean up HUD and reset spread state.
function MangaFlow:onCloseDocument()
    self:removeHUD()
    self:exitSpreadMode()
    self.is_manga     = false
    self.series_name  = nil
    self.settings     = nil
    self.spread_counts = nil
end

-- ── Detection & application ───────────────────────────────────────────────────

function MangaFlow:detectAndApply()
    local doc = self.ui.document
    if not doc then return end

    -- Total pages
    self.total_pages = doc:getPageCount() or 0

    -- Identify the file on disk
    local filepath = doc.file or ""
    local filename = filepath:match("[^/\\]+$") or ""
    local ext      = (filename:match("%.([^%.]+)$") or ""):lower()

    -- Only activate for comic formats
    if ext ~= "cbz" and ext ~= "cbr" and ext ~= "zip" then return end

    -- Resolve series name (bookinfo DB → filename → bare name)
    self.series_name = self:resolveSeriesName(filepath, filename)

    -- Load (or create) per-series settings
    self.settings = SeriesSettings.get(self.series_name)

    -- Determine RTL
    self.is_manga = self:detectRTL(filepath, filename)

    -- Ask user on first encounter (no saved row yet)
    if self.is_manga and not SeriesSettings.exists(self.series_name) then
        self:promptMangaMode()
    else
        self:applySettings()
    end
end

--- Returns true if this book should be read RTL.
function MangaFlow:detectRTL(filepath, filename)
    -- 1. Check ComicInfo.xml inside the CBZ
    if filepath:lower():match("%.cbz$") then
        local rtl = self:readComicInfoRTL(filepath)
        if rtl ~= nil then return rtl end
    end

    -- 2. Check bookinfo_cache.sqlite3 for language/series metadata
    local lang = self:queryBookinfoDB(filepath, "language")
    if lang and (lang:lower() == "ja" or lang:lower() == "japanese") then
        return true
    end

    -- 3. Filename heuristics
    local lower_name = filename:lower()
    for _, pat in ipairs(MANGA_FILENAME_HINTS) do
        if lower_name:match(pat) then return true end
    end

    return false
end

--- Reads ComicInfo.xml from a CBZ and checks the Manga field.
--- Returns true (RTL), false (LTR), or nil (not found / not determinable).
function MangaFlow:readComicInfoRTL(cbz_path)
    -- Use shell unzip to extract ComicInfo.xml without loading the whole archive
    local cmd = ("unzip -p %q ComicInfo.xml 2>/dev/null"):format(cbz_path)
    local handle = io.popen(cmd)
    if not handle then return nil end
    local xml = handle:read("*a")
    handle:close()
    if not xml or #xml == 0 then return nil end

    -- Parse the <Manga> field — values: Yes, YesAndRightToLeft, No
    local manga_val = xml:match("<Manga>%s*([^<]+)%s*</Manga>")
    if not manga_val then return nil end
    manga_val = manga_val:lower():gsub("%s+", "")
    if manga_val == "yesandrightttoleft" or manga_val == "yesandrightoleft"
    or manga_val == "yesandrighttoleft" then
        return true
    elseif manga_val == "yes" then
        return true   -- assume RTL if just "Yes"
    elseif manga_val == "no" then
        return false
    end
    return nil
end

--- Query bookinfo_cache.sqlite3 for a single column value.
function MangaFlow:queryBookinfoDB(filepath, column)
    if not lfs.attributes(BOOKINFO_DB, "mode") then return nil end
    local ok, db = pcall(SQ3.open, BOOKINFO_DB, SQ3.OPEN_READONLY)
    if not ok then return nil end

    local dir   = filepath:match("^(.+)/[^/]+$") or "."
    local fname = filepath:match("[^/]+$") or filepath

    local val
    pcall(function()
        local row = db:rowexec(
            ("SELECT %s FROM bookinfo WHERE directory = ? AND filename = ?;"):format(column),
            dir .. "/", fname
        )
        if row then val = row[1] end
    end)
    db:close()
    return val
end

--- Resolve a clean series name for this book.
function MangaFlow:resolveSeriesName(filepath, filename)
    -- 1. Try bookinfo_cache series column
    local series = self:queryBookinfoDB(filepath, "series")
    if series and series ~= "" then return series end

    -- 2. Try document metadata
    local doc = self.ui.document
    if doc and doc:getProps then
        local props = doc:getProps()
        if props and props.series and props.series ~= "" then
            return props.series
        end
    end

    -- 3. Strip volume/chapter suffix from filename
    --    e.g. "One_Piece_Vol01.cbz" → "One_Piece"
    local base = filename:gsub("%.[^%.]+$", "")             -- remove extension
    base = base:gsub("[_%-]?[Vv]ol%.?%s*%d+.*$", "")        -- remove Vol##
    base = base:gsub("[_%-]?[Cc]h%.?%s*%d+.*$", "")         -- remove Ch##
    base = base:gsub("[_%-]?%d+$", "")                       -- remove trailing number
    base = base:gsub("[_%-]+$", "")                          -- clean trailing separators
    base = base:gsub("[_]", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")  -- normalise

    return (base ~= "" and base) or filename
end

-- ── Apply settings to the reader ──────────────────────────────────────────────

function MangaFlow:applySettings()
    if not self.is_manga then return end

    local doc    = self.ui.document
    local paging = self.ui.paging
    local s      = self.settings or SeriesSettings.DEFAULTS

    -- Set RTL page-turn direction
    if paging then
        if s.rtl == 1 then
            paging:setPageFlipMode("rtl")   -- right-to-left
        else
            paging:setPageFlipMode("ltr")
        end
    end

    -- Apply contrast / gamma via document draw context
    if doc and doc.setContrast then
        -- KOReader contrast is 0.0–2.0; map our 0–100 → 0.5–2.0
        local gamma = 0.5 + (s.contrast / 100) * 1.5
        doc:setContrast(gamma)
    end

    -- Pre-cache: set lookahead via reader's paging/panning settings
    if self.ui.readerrolling and self.ui.readerrolling.setPreCache then
        self.ui.readerrolling:setPreCache(s.precache)
    end

    -- Sample pages to check if this book has spreads (scan up to 10 pages)
    if self.settings and self.settings.spread == 1 then
        self:sampleSpreadCount()
    end

    -- Show HUD
    self:showHUD()
end

function MangaFlow:promptMangaMode()
    UIManager:show(ConfirmBox:new{
        text    = T(_("MangaFlow detected manga:\n%1\n\nEnable Manga Mode? (RTL, max contrast, pre-cache)"), self.series_name or ""),
        ok_text = _("Enable"),
        ok_callback = function()
            SeriesSettings.set(self.series_name, { rtl = 1, contrast = 80, precache = 3 })
            self.settings = SeriesSettings.get(self.series_name)
            self:applySettings()
        end,
        cancel_text = _("Skip"),
    })
end

-- ── Progress HUD ──────────────────────────────────────────────────────────────

function MangaFlow:buildHUDText()
    local page = self.current_page or 0
    local total = self.total_pages or 0
    local series = self.series_name or ""

    -- Truncate long series names
    if #series > 22 then series = series:sub(1, 20) .. "…" end

    if series ~= "" then
        return ("%s  ·  %d / %d"):format(series, page, total)
    else
        return ("Page %d / %d"):format(page, total)
    end
end

function MangaFlow:showHUD()
    self:removeHUD()

    local text = self:buildHUDText()
    local face = Font:getFace("infofont", 14)

    self.hud_widget = FrameContainer:new{
        background = Blitbuffer.COLOR_BLACK,
        bordersize = 0,
        padding    = 4,
        TextWidget:new{
            text    = text,
            face    = face,
            fgcolor = Blitbuffer.COLOR_WHITE,
        },
    }

    -- Anchor to bottom-centre of screen
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self.hud_widget.overlap_offset = {
        math.floor((sw - 200) / 2),
        sh - 32,
    }

    UIManager:show(self.hud_widget)
end

function MangaFlow:updateHUD()
    if not self.is_manga or not self.hud_widget then return end
    -- Rebuild HUD text — cheapest approach on e-ink is close+reshow
    self:showHUD()
end

function MangaFlow:removeHUD()
    if self.hud_widget then
        UIManager:close(self.hud_widget)
        self.hud_widget = nil
    end
end

-- ── Double-page spread handling ───────────────────────────────────────────────

--- Returns true if pageno has a landscape / double-page aspect ratio.
function MangaFlow:isSpreadPage(pageno)
    local doc = self.ui.document
    if not doc then return false end
    local ok, dims = pcall(function() return doc:getPageDimensions(pageno, 1, 0) end)
    if not ok or not dims then return false end
    -- Spreads are typically ≥1.4:1 width-to-height
    return (dims.w / dims.h) > 1.4
end

--- Sample up to 10 pages to decide if this book routinely has spreads.
--- Stores result in self.spread_counts.
function MangaFlow:sampleSpreadCount()
    local total    = self.total_pages or 0
    if total == 0 then return end

    local sample_n = math.min(10, total)
    local step     = math.max(1, math.floor(total / sample_n))
    local spreads  = 0

    for i = 1, total, step do
        if self:isSpreadPage(i) then spreads = spreads + 1 end
        if i > sample_n * step then break end
    end

    self.spread_counts = { spreads = spreads, total = sample_n }
    logger.dbg("MangaFlow: spread sample", spreads, "/", sample_n)
end

--- Called on every page update — enters/exits spread mode automatically.
function MangaFlow:handleSpread(pageno)
    local s = self.settings or SeriesSettings.DEFAULTS
    if s.spread ~= 1 then return end

    local is_spread = self:isSpreadPage(pageno)

    if is_spread and not self.spread_mode then
        self:enterSpreadMode()
    elseif not is_spread and self.spread_mode then
        self:exitSpreadMode()
    end
end

--- Switch reader to "fit width" zoom — shows the full spread width on screen.
function MangaFlow:enterSpreadMode()
    self.spread_mode = true
    local zoom = self.ui.readerzooming
    if zoom then
        -- Save current mode so we can restore it
        self._prev_zoom_mode = zoom.zoom_mode
        -- "width" mode fits the full page/spread width to the screen
        pcall(function() zoom:setZoomMode("width") end)
    end
    logger.dbg("MangaFlow: entered spread mode")
end

--- Restore zoom mode after a spread page.
function MangaFlow:exitSpreadMode()
    if not self.spread_mode then return end
    self.spread_mode = false
    local zoom = self.ui.readerzooming
    if zoom and self._prev_zoom_mode then
        pcall(function() zoom:setZoomMode(self._prev_zoom_mode) end)
        self._prev_zoom_mode = nil
    end
    logger.dbg("MangaFlow: exited spread mode")
end

-- ── Menu ──────────────────────────────────────────────────────────────────────

function MangaFlow:addToMainMenu(menu_items)
    menu_items.mangaflow = {
        text = _("MangaFlow"),
        sub_item_table = {
            {
                text_func = function()
                    return self.is_manga
                        and _("Manga Mode: ON  ✓")
                        or  _("Manga Mode: off")
                end,
                callback = function()
                    self.is_manga = not self.is_manga
                    if self.is_manga then
                        if self.series_name then
                            SeriesSettings.set(self.series_name, { rtl = 1 })
                            self.settings = SeriesSettings.get(self.series_name)
                        end
                        self:applySettings()
                    else
                        self:removeHUD()
                        if self.ui.paging then
                            self.ui.paging:setPageFlipMode("ltr")
                        end
                    end
                end,
                keep_menu_open = true,
            },
            {
                text_func = function()
                    local s = self.settings or SeriesSettings.DEFAULTS
                    return s.spread == 1
                        and _("Auto Spread: ON  ✓")
                        or  _("Auto Spread: off")
                end,
                enabled_func = function() return self.is_manga end,
                callback = function()
                    if not self.series_name then return end
                    local s = self.settings or SeriesSettings.DEFAULTS
                    local new_val = (s.spread == 1) and 0 or 1
                    SeriesSettings.set(self.series_name, { spread = new_val })
                    self.settings = SeriesSettings.get(self.series_name)
                    if new_val == 1 then
                        self:sampleSpreadCount()
                    else
                        self:exitSpreadMode()
                    end
                end,
                keep_menu_open = true,
            },
            {
                text = _("Reset Series Settings"),
                enabled_func = function() return self.series_name ~= nil end,
                callback = function()
                    if self.series_name then
                        SeriesSettings.delete(self.series_name)
                        UIManager:show(InfoMessage:new{
                            text = T(_("Reset settings for: %1"), self.series_name),
                            timeout = 2,
                        })
                    end
                end,
            },
            {
                text_func = function()
                    return ("Series: %s"):format(self.series_name or "—")
                end,
                enabled_func = function() return false end,  -- display only
            },
        },
    }
end

return MangaFlow
