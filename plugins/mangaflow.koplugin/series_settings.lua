--[[
MangaFlow — per-series settings storage (SQLite)
Schema: series_settings(series_name TEXT PK, rtl INTEGER, contrast INTEGER,
        precache_pages INTEGER, autocrop INTEGER, updated_at INTEGER)
TODO (Session 2): implement CRUD helpers.
--]]

local SeriesSettings = {}
SeriesSettings.__index = SeriesSettings

return SeriesSettings
