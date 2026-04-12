--[[
MangaFlow — per-series settings storage
SQLite table: series_settings
  series_name  TEXT PRIMARY KEY
  rtl          INTEGER  (1 = right-to-left, 0 = left-to-right)
  contrast     INTEGER  (0–100, default 50)
  precache     INTEGER  (pages to pre-cache ahead, default 3)
  autocrop     INTEGER  (1 = crop white borders, default 0)
  spread       INTEGER  (1 = auto-stitch double-page spreads, default 0)
  updated_at   INTEGER  (unix timestamp)
--]]

local SQ3          = require("lua-ljsqlite3/init")
local DataStorage  = require("datastorage")
local logger       = require("logger")

local DB_PATH = DataStorage:getDataDir() .. "/mangaflow.sqlite3"

local DEFAULTS = {
    rtl      = 1,
    contrast = 50,
    precache = 3,
    autocrop = 0,
    spread   = 0,
}

local SeriesSettings = {}
SeriesSettings.__index = SeriesSettings

-- ── Internal helpers ──────────────────────────────────────────────────────────

local function openDB()
    local ok, db = pcall(SQ3.open, DB_PATH)
    if not ok then
        logger.warn("MangaFlow: could not open settings DB:", db)
        return nil
    end
    -- Create table if needed
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

-- ── Public API ────────────────────────────────────────────────────────────────

--- Returns settings table for series_name, or DEFAULTS if not found.
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

--- Saves (upsert) settings for series_name.
--- settings is a partial table — unspecified keys keep their current value.
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

    if not ok then
        logger.warn("MangaFlow: settings write error:", err)
        return false
    end
    return true
end

--- Deletes settings for series_name (resets to defaults).
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

--- Returns all stored series (for the settings UI).
function SeriesSettings.getAll()
    local db = openDB()
    if not db then return {} end

    local rows = {}
    local ok, err = pcall(function()
        local stmt = db:prepare("SELECT series_name, rtl, contrast, precache, autocrop, spread FROM series_settings ORDER BY series_name;")
        for row in stmt:rows() do
            table.insert(rows, {
                series_name = row[1],
                rtl         = row[2],
                contrast    = row[3],
                precache    = row[4],
                autocrop    = row[5],
                spread      = row[6],
            })
        end
        stmt:close()
    end)
    db:close()
    if not ok then logger.warn("MangaFlow getAll:", err) end
    return rows
end

--- Returns true if a saved row exists for series_name (distinct from just DEFAULTS).
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

SeriesSettings.DEFAULTS = DEFAULTS

return SeriesSettings
