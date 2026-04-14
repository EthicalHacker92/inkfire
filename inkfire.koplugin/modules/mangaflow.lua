--[[
InkFire — MangaFlow Module
Pure logic layer: RTL detection, per-series settings, spread detection.
NO KOReader UI imports.

State keys published:
  - mangaflow.is_manga    boolean
  - mangaflow.series_name string or nil
  - mangaflow.spread_mode boolean
--]]

local SQ3         = require("lua-ljsqlite3/init")
local DataStorage = require("datastorage")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")

local State = require("plugins/inkfire.koplugin/modules/state")

local DATA_DIR   = DataStorage:getDataDir()
local DB_PATH    = DATA_DIR .. "/inkfire_mangaflow.sqlite3"
local BOOKINFO_DB = DATA_DIR .. "/bookinfo_cache.sqlite3"

-- Patterns in filenames that hint "this is manga"
local MANGA_FILENAME_HINTS = {
    "%[manga%]", "%(manga%)", "manga_", "_manga",
    "%[JP%]", "%[ja%]",
}

local DEFAULTS = {
    rtl      = 1,
    contrast = 50,
    precache = 3,
    autocrop = 0,
    spread   = 0,
}

-- ── Database ──────────────────────────────────────────────────────────────────

local function openDB()
    local ok, db = pcall(SQ3.open, DB_PATH)
    if not ok then
        logger.warn("MangaFlow: could not open DB:", db)
        return nil
    end
    db:exec([[
        CREATE TABLE IF NOT EXISTS series_settings (
            series_name  TEXT PRIMARY KEY,
            rtl          INTEGER NOT NULL DEFAULT 1,
            contrast     INTEGER NOT NULL DEFAULT 50,
            precache     INTEGER NOT NULL DEFAULT 3,
            autocrop     INTEGER NOT NULL DEFAULT 0,
            spread       INTEGER NOT NULL DEFAULT 0,
            updated_at   INTEGER NOT NULL DEFAULT 0
        );
    ]])
    return db
end

-- ── Per-series settings ───────────────────────────────────────────────────────

local SeriesSettings = {}

function SeriesSettings.get(series_name)
    if not series_name or series_name == "" then return DEFAULTS end
    local db = openDB()
    if not db then return DEFAULTS end

    local ok, row = pcall(function()
        return db:rowexec(
            "SELECT rtl, contrast, precache, autocrop, spread FROM series_settings WHERE series_name = ?;",
            series_name
        )
    end)
    db:close()

    if not ok or not row then return DEFAULTS end
    return {
        rtl      = row[1] or DEFAULTS.rtl,
        contrast = row[2] or DEFAULTS.contrast,
        precache = row[3] or DEFAULTS.precache,
        autocrop = row[4] or DEFAULTS.autocrop,
        spread   = row[5] or DEFAULTS.spread,
    }
end

function SeriesSettings.set(series_name, settings)
    if not series_name or series_name == "" then return false end
    local current = SeriesSettings.get(series_name)
    local merged  = {
        rtl      = settings.rtl      ~= nil and settings.rtl      or current.rtl,
        contrast = settings.contrast ~= nil and settings.contrast or current.contrast,
        precache = settings.precache ~= nil and settings.precache or current.precache,
        autocrop = settings.autocrop ~= nil and settings.autocrop or current.autocrop,
        spread   = settings.spread   ~= nil and settings.spread   or current.spread,
    }

    local db = openDB()
    if not db then return false end

    local ok, err = pcall(function()
        local stmt = db:prepare(
            "INSERT OR REPLACE INTO series_settings VALUES (?, ?, ?, ?, ?, ?, strftime('%s','now'));"
        )
        stmt:bind(1, series_name)
        stmt:bind(2, merged.rtl)
        stmt:bind(3, merged.contrast)
        stmt:bind(4, merged.precache)
        stmt:bind(5, merged.autocrop)
        stmt:bind(6, merged.spread)
        stmt:step()
        stmt:close()
    end)
    db:close()
    if not ok then logger.warn("MangaFlow: settings write error:", err) end
    return ok
end

function SeriesSettings.delete(series_name)
    if not series_name or series_name == "" then return end
    local db = openDB()
    if not db then return end
    pcall(function()
        local stmt = db:prepare("DELETE FROM series_settings WHERE series_name = ?;")
        stmt:bind(1, series_name)
        stmt:step()
        stmt:close()
    end)
    db:close()
end

function SeriesSettings.exists(series_name)
    if not series_name or series_name == "" then return false end
    local db = openDB()
    if not db then return false end
    local row
    pcall(function()
        row = db:rowexec(
            "SELECT 1 FROM series_settings WHERE series_name = ?;",
            series_name
        )
    end)
    db:close()
    return row ~= nil
end

-- ── Bookinfo cache query ──────────────────────────────────────────────────────

local function queryBookinfoDB(filepath, column)
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

-- ── RTL detection ─────────────────────────────────────────────────────────────

local function readComicInfoRTL(cbz_path)
    local tmp = os.tmpname()
    pcall(os.execute, ("unzip -p %q ComicInfo.xml > %q 2>/dev/null"):format(cbz_path, tmp))
    local xml
    local f = io.open(tmp, "r")
    if f then xml = f:read("*a"); f:close() end
    pcall(os.remove, tmp)
    if not xml or #xml == 0 then return nil end

    local manga_val = xml:match("<Manga>%s*([^<]+)%s*</Manga>")
    if not manga_val then return nil end
    manga_val = manga_val:lower():gsub("%s+", "")
    if manga_val == "yesandrighttoleft" or manga_val == "yes" then
        return true
    elseif manga_val == "no" then
        return false
    end
    return nil
end

local function detectRTL(filepath, filename)
    if filepath:lower():match("%.cbz$") then
        local rtl = readComicInfoRTL(filepath)
        if rtl ~= nil then return rtl end
    end

    local lang = queryBookinfoDB(filepath, "language")
    if lang and (lang:lower() == "ja" or lang:lower() == "japanese") then
        return true
    end

    local lower_name = filename:lower()
    for _, pat in ipairs(MANGA_FILENAME_HINTS) do
        if lower_name:match(pat) then return true end
    end
    return false
end

local function resolveSeriesName(filepath, filename, doc)
    local series = queryBookinfoDB(filepath, "series")
    if series and series ~= "" then return series end

    if doc and doc.getProps then
        local ok, props = pcall(function() return doc:getProps() end)
        if ok and props and props.series and props.series ~= "" then
            return props.series
        end
    end

    local base = filename:gsub("%.[^%.]+$", "")
    base = base:gsub("[_%-]?[Vv]ol%.?%s*%d+.*$", "")
    base = base:gsub("[_%-]?[Cc]h%.?%s*%d+.*$", "")
    base = base:gsub("[_%-]?%d+$", "")
    base = base:gsub("[_%-]+$", "")
    base = base:gsub("[_]", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
    return (base ~= "" and base) or filename
end

-- ── Public API ────────────────────────────────────────────────────────────────

local MangaFlow = {}

--[[
Called when a document opens.
Returns: { is_manga, series_name, settings, needs_prompt }
  needs_prompt = true when first encounter (no saved settings yet)
--]]
function MangaFlow.onDocumentOpen(filepath, doc)
    local filename = filepath:match("[^/\\]+$") or ""
    local ext      = (filename:match("%.([^%.]+)$") or ""):lower()

    if ext ~= "cbz" and ext ~= "cbr" and ext ~= "zip" then
        State.set("mangaflow.is_manga",    false)
        State.set("mangaflow.series_name", nil)
        State.set("mangaflow.spread_mode", false)
        return { is_manga = false }
    end

    local series_name = resolveSeriesName(filepath, filename, doc)
    local is_manga    = detectRTL(filepath, filename)
    local settings    = SeriesSettings.get(series_name)
    local needs_prompt = is_manga and not SeriesSettings.exists(series_name)

    State.set("mangaflow.is_manga",    is_manga)
    State.set("mangaflow.series_name", series_name)
    State.set("mangaflow.spread_mode", false)

    return {
        is_manga     = is_manga,
        series_name  = series_name,
        settings     = settings,
        needs_prompt = needs_prompt,
    }
end

--- Toggle manga mode for the current series. Returns new is_manga value.
function MangaFlow.toggleMangaMode(series_name, enable)
    if enable and series_name then
        SeriesSettings.set(series_name, { rtl = 1 })
    end
    State.set("mangaflow.is_manga", enable)
    return enable
end

--- Toggle spread mode for the current series. Returns new spread value.
function MangaFlow.toggleSpread(series_name, settings)
    if not series_name then return 0 end
    local new_val = (settings and settings.spread == 1) and 0 or 1
    SeriesSettings.set(series_name, { spread = new_val })
    return new_val
end

--- Reset settings for a series.
function MangaFlow.resetSettings(series_name)
    if series_name then
        SeriesSettings.delete(series_name)
    end
end

--- Get settings for a series (used by main.lua).
function MangaFlow.getSettings(series_name)
    return SeriesSettings.get(series_name)
end

--- Save settings after user prompt confirmation.
function MangaFlow.confirmMangaMode(series_name)
    SeriesSettings.set(series_name, { rtl = 1, contrast = 80, precache = 3 })
    return SeriesSettings.get(series_name)
end

--- Build HUD text line.
function MangaFlow.buildHUDText(series_name, current_page, total_pages)
    local series = series_name or ""
    if #series > 22 then series = series:sub(1, 20) .. "…" end
    if series ~= "" then
        return ("%s  ·  %d / %d"):format(series, current_page or 0, total_pages or 0)
    else
        return ("Page %d / %d"):format(current_page or 0, total_pages or 0)
    end
end

--- Check if a page is a double-page spread (aspect > 1.4).
--- doc: KOReader document object (passed from main.lua).
function MangaFlow.isSpreadPage(doc, pageno)
    if not doc then return false end
    local ok, dims = pcall(function() return doc:getPageDimensions(pageno, 1, 0) end)
    if not ok or not dims then return false end
    return (dims.w / dims.h) > 1.4
end

--- Sample spread pages (returns { spreads, total }).
function MangaFlow.sampleSpreads(doc, total_pages)
    if not doc or not total_pages or total_pages == 0 then
        return { spreads = 0, total = 0 }
    end
    local sample_n = math.min(10, total_pages)
    local step     = math.max(1, math.floor(total_pages / sample_n))
    local spreads  = 0
    for i = 1, total_pages, step do
        if MangaFlow.isSpreadPage(doc, i) then spreads = spreads + 1 end
        if i > sample_n * step then break end
    end
    logger.dbg("MangaFlow: spread sample", spreads, "/", sample_n)
    return { spreads = spreads, total = sample_n }
end

--- Update spread state — returns true if spread mode should change.
function MangaFlow.updateSpreadState(doc, pageno, settings, current_spread_mode)
    if not settings or settings.spread ~= 1 then return nil end
    local is_spread = MangaFlow.isSpreadPage(doc, pageno)
    if is_spread and not current_spread_mode then
        State.set("mangaflow.spread_mode", true)
        return "enter"
    elseif not is_spread and current_spread_mode then
        State.set("mangaflow.spread_mode", false)
        return "exit"
    end
    return nil
end

--- Called on document close — resets state.
function MangaFlow.onDocumentClose()
    State.set("mangaflow.is_manga",    false)
    State.set("mangaflow.series_name", nil)
    State.set("mangaflow.spread_mode", false)
end

MangaFlow.DEFAULTS     = DEFAULTS
MangaFlow.SeriesSettings = SeriesSettings

return MangaFlow
