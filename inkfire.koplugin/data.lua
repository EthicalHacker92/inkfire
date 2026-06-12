--[[
InkFire — data.lua
Every read the UI needs, behind one façade. No UIManager, no widgets.

Sources (all read-only, all pcall-guarded):
  • ReadHistory + DocSettings sidecars → what you were reading, how far
  • bookinfo_cache.sqlite3 (coverbrowser schema) → metadata + cover thumbnails
    (covers are zstd-compressed raw BlitBuffers: decode with zstd_uncompress_ctx
     + Blitbuffer.new + setAllocated(1) — the exact coverbrowser code path)
  • statistics.sqlite3 → reading speed, minutes today, streaks
  • G_reader_settings (inkfire_* keys) → goals & toggles
--]]

local Blitbuffer  = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local ReadHistory = require("readhistory")
local SQ3         = require("lua-ljsqlite3/init")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")
local zstd        = require("ffi/zstd")

local Data = {}

local SETTINGS_DIR = DataStorage:getSettingsDir()
local DATA_DIR     = DataStorage:getDataDir()
local BOOKINFO_DB  = SETTINGS_DIR .. "/bookinfo_cache.sqlite3"
local STATS_DB     = DATA_DIR .. "/statistics.sqlite3"

local MANGA_EXTS = { cbz = true, cbr = true, cb7 = true }

-- ══ Small utilities ═══════════════════════════════════════════════════════════

local function fileExists(path)
    return path and lfs.attributes(path, "mode") == "file"
end

local function splitPath(path)
    local dir, name = path:match("^(.*/)([^/]+)$")
    return dir or "./", name or path
end

local function ext(path)
    return (path:match("%.([^%.]+)$") or ""):lower()
end

function Data.isManga(path)
    return MANGA_EXTS[ext(path)] == true
end

-- ══ Title cleaning ════════════════════════════════════════════════════════════
-- Library files often carry Anna's-Archive-style names:
--   "Chainsaw Man, Vol 18- All Pets -- Tatsuki Fujimoto -- Chainsaw Man, 18,
--    2024 -- VIZ Media LLC -- 9781974754939 -- 9d4bb... -- Anna's Archive.epub"
-- We show humans the human part.

function Data.cleanTitle(raw)
    if not raw or raw == "" then return "Untitled" end
    local t = raw
    t = t:gsub("%.[A-Za-z0-9]+$", "")          -- extension
    t = t:gsub("%s*%-%-.*$", "")               -- everything after first " -- "
    t = t:gsub("[_]+", " ")                    -- underscores → spaces
    t = t:gsub("%[[^%]]*%]", "")               -- [bracketed tags]
    t = t:gsub("%((19|20)%d%d%)", "")          -- (year)
    t = t:gsub("%s+", " ")
    t = t:gsub("^%s+", ""):gsub("%s+$", "")
    if t == "" then return raw end
    return t
end

--- "Chainsaw Man, Vol. 13: Spoiler" → "Chainsaw Man", 13
function Data.seriesFromTitle(title)
    local name, num = title:match("^(.-),?%s+[Vv]ol%.?%s*(%d+)")
    if name then return (name:gsub("[,%s]+$", "")), tonumber(num) end
    name, num = title:match("^(.-)%s+[Vv](%d+)$")
    if name then return name, tonumber(num) end
    return nil, nil
end

-- ══ bookinfo_cache access ═════════════════════════════════════════════════════

local function bookinfoRow(filepath)
    if not fileExists(BOOKINFO_DB) then return nil end
    local dir, name = splitPath(filepath)
    local ok, db = pcall(SQ3.open, BOOKINFO_DB, SQ3.OPEN_READONLY)
    if not ok then return nil end
    local row
    pcall(function()
        local stmt = db:prepare([[
            SELECT title, authors, series, series_index, pages, has_cover
            FROM bookinfo WHERE directory = ? AND filename = ? LIMIT 1;
        ]])
        stmt:bind(1, dir)
        stmt:bind(2, name)
        local r = stmt:step()
        if r then
            row = {
                title        = r[1], authors = r[2],
                series       = r[3], series_index = tonumber(r[4]),
                pages        = tonumber(r[5]),
                has_cover    = (r[6] == "Y" or r[6] == 1),
            }
        end
        stmt:close()
    end)
    db:close()
    return row
end

--- Every row in bookinfo cache (for the Library grid). Lightweight columns only.
local function bookinfoAll()
    if not fileExists(BOOKINFO_DB) then return {} end
    local ok, db = pcall(SQ3.open, BOOKINFO_DB, SQ3.OPEN_READONLY)
    if not ok then return {} end
    local rows = {}
    pcall(function()
        local stmt = db:prepare([[
            SELECT directory, filename, title, authors, series, series_index, pages
            FROM bookinfo
            WHERE unsupported IS NULL
            ORDER BY directory, filename;
        ]])
        for r in stmt:rows() do
            rows[#rows + 1] = {
                directory = r[1], filename = r[2],
                title = r[3], authors = r[4],
                series = r[5], series_index = tonumber(r[6]),
                pages = tonumber(r[7]),
            }
        end
        stmt:close()
    end)
    db:close()
    return rows
end

-- ══ Cover thumbnails (zstd → BlitBuffer), LRU-cached ══════════════════════════

local _covers   = {}   -- key → { bb = BlitBuffer }
local _order    = {}   -- keys, oldest first
local MAX_COVERS = 24

-- Eviction drops references only — live ImageWidgets may still be painting
-- an evicted bb (e.g., Hearth beneath the Library). BlitBuffers allocated
-- with setAllocated(1) carry a GC finalizer, so LuaJIT reclaims them once
-- the last widget reference is gone. Never call :free() here.
local function evictCovers()
    while #_order > MAX_COVERS do
        local key = table.remove(_order, 1)
        _covers[key] = nil
    end
end

--- Decoded cover BlitBuffer for a file, or nil. Caller must NOT free it
--- (cache owns it): use ImageWidget{ image = bb, image_disposable = false }.
function Data.cover(filepath)
    local key = filepath
    local hit = _covers[key]
    if hit then return hit.bb end
    if not fileExists(BOOKINFO_DB) then return nil end

    local dir, name = splitPath(filepath)
    local ok, db = pcall(SQ3.open, BOOKINFO_DB, SQ3.OPEN_READONLY)
    if not ok then return nil end

    local bb
    pcall(function()
        local stmt = db:prepare([[
            SELECT cover_w, cover_h, cover_bb_type, cover_bb_stride, cover_bb_data
            FROM bookinfo
            WHERE directory = ? AND filename = ? AND cover_bb_data IS NOT NULL
            LIMIT 1;
        ]])
        stmt:bind(1, dir)
        stmt:bind(2, name)
        local r = stmt:step()
        if r then
            local w, h        = tonumber(r[1]), tonumber(r[2])
            local bbtype      = tonumber(r[3])
            local stride      = tonumber(r[4])
            local blob        = r[5]
            if w and h and blob then
                local data, size = zstd.zstd_uncompress_ctx(blob[1], blob[2])
                if data and size and size > 0 then
                    bb = Blitbuffer.new(w, h, bbtype, data, stride, w)
                    bb:setAllocated(1)  -- bb owns the malloc'd buffer
                end
            end
        end
        stmt:close()
    end)
    db:close()

    if bb then
        _covers[key] = { bb = bb }
        _order[#_order + 1] = key
        evictCovers()
    end
    return bb
end

function Data.dropCoverCache()
    -- References only; GC finalizers reclaim the buffers (see evictCovers).
    _covers, _order = {}, {}
end

-- ══ Progress (DocSettings sidecars) ═══════════════════════════════════════════

local function progressOf(filepath)
    local pct, status = 0, "new"
    pcall(function()
        local ds = DocSettings:open(filepath)
        pct = tonumber(ds:readSetting("percent_finished")) or 0
        local summary = ds:readSetting("summary")
        if summary and summary.status then status = summary.status end
        -- No ds:close(): close() flushes, which would create .sdr sidecar
        -- dirs for books the user never opened. Read-only access only.
    end)
    if status == "complete" then pct = 1 end
    return pct, status
end

-- ══ Reading speed / time-left (statistics.sqlite3) ════════════════════════════

local function statsByTitle(title)
    if not fileExists(STATS_DB) then return nil end
    local ok, db = pcall(SQ3.open, STATS_DB, SQ3.OPEN_READONLY)
    if not ok then return nil end
    local out
    pcall(function()
        local stmt = db:prepare([[
            SELECT pages, total_read_time, total_read_pages
            FROM book WHERE title = ? ORDER BY last_open DESC LIMIT 1;
        ]])
        stmt:bind(1, title)
        local r = stmt:step()
        if r then
            out = {
                pages      = tonumber(r[1]) or 0,
                read_time  = tonumber(r[2]) or 0,
                read_pages = tonumber(r[3]) or 0,
            }
        end
        stmt:close()
    end)
    db:close()
    return out
end

--- "about 2h 14m left" or nil when we can't estimate honestly.
function Data.timeLeft(title, pct)
    local st = statsByTitle(title)
    if not st or st.read_pages < 5 or st.pages == 0 then return nil end
    local per_page  = st.read_time / st.read_pages
    local remaining = math.floor(st.pages * (1 - (pct or 0)) * per_page)
    if remaining <= 0 then return nil end
    local m = math.floor(remaining / 60)
    if m < 1 then return nil end
    if m < 60 then return ("about %dm left"):format(m) end
    return ("about %dh %dm left"):format(math.floor(m / 60), m % 60)
end

-- ══ The Hearth model ══════════════════════════════════════════════════════════

local function describe(filepath)
    local info  = bookinfoRow(filepath) or {}
    local _, fname = splitPath(filepath)
    local title = info.title and info.title ~= "" and Data.cleanTitle(info.title)
                  or Data.cleanTitle(fname)
    local pct, status = progressOf(filepath)
    local series, idx = info.series, info.series_index
    if (not series or series == "") then
        series, idx = Data.seriesFromTitle(title)
    end
    return {
        file     = filepath,
        title    = title,
        authors  = info.authors or "",
        series   = series, series_index = idx,
        pages    = info.pages,
        pct      = pct,
        status   = status,
        is_manga = Data.isManga(filepath),
    }
end

--- Most recent unfinished book from reading history (skips missing files).
function Data.continueBook()
    local hist = ReadHistory and ReadHistory.hist or {}
    for i = 1, math.min(#hist, 12) do
        local item = hist[i]
        local f = item and (item.file or (item.text and nil))
        if f and fileExists(f) then
            local b = describe(f)
            if b.status ~= "complete" then
                b.time_left = Data.timeLeft(b.title, b.pct)
                return b
            end
        end
    end
    return nil
end

--- Next unread volume in the same series as `book` (manga flow), or nil.
function Data.nextInSeries(book, all_rows)
    if not book or not book.series then return nil end
    local rows = all_rows or bookinfoAll()
    local best
    for _, r in ipairs(rows) do
        local f = r.directory .. r.filename
        local title = Data.cleanTitle(r.title or r.filename)
        local series, idx = r.series, r.series_index
        if not series or series == "" then series, idx = Data.seriesFromTitle(title) end
        if series == book.series and f ~= book.file and idx then
            local cur = book.series_index or -1
            if idx > cur and (not best or idx < best.series_index) then
                local pct, status = progressOf(f)
                if status ~= "complete" and pct < 0.02 then
                    best = { file = f, title = title, series_index = idx,
                             pct = pct, status = status, is_manga = Data.isManga(f) }
                end
            end
        end
    end
    return best
end

--- Up Next rail: next series volume first, then recent unfinished, then fresh.
function Data.upNext(continue_book, limit)
    limit = limit or 3
    local out, seen = {}, {}
    if continue_book then seen[continue_book.file] = true end

    local rows = bookinfoAll()

    local nxt = Data.nextInSeries(continue_book, rows)
    if nxt and not seen[nxt.file] then
        out[#out + 1] = nxt; seen[nxt.file] = true
    end

    -- Recent unfinished from history
    local hist = ReadHistory and ReadHistory.hist or {}
    for i = 1, math.min(#hist, 20) do
        if #out >= limit then break end
        local f = hist[i] and hist[i].file
        if f and not seen[f] and fileExists(f) then
            local b = describe(f)
            if b.status ~= "complete" and b.pct > 0 then
                out[#out + 1] = b; seen[f] = true
            end
        end
    end

    -- Fresh: never-opened books from the cache
    for _, r in ipairs(rows) do
        if #out >= limit then break end
        local f = r.directory .. r.filename
        if not seen[f] and fileExists(f) then
            local pct = progressOf(f)
            if pct == 0 then
                out[#out + 1] = {
                    file = f, title = Data.cleanTitle(r.title or r.filename),
                    authors = r.authors or "", pct = 0, status = "new",
                    is_manga = Data.isManga(f),
                }
                seen[f] = true
            end
        end
    end
    return out
end

--- Library grid model. lane: "all" | "books" | "manga"
function Data.library(lane)
    lane = lane or "all"
    local rows = bookinfoAll()
    local out = {}
    for _, r in ipairs(rows) do
        local f = r.directory .. r.filename
        if fileExists(f) then
            local is_manga = Data.isManga(f)
            if lane == "all" or (lane == "manga") == is_manga then
                local pct, status = progressOf(f)
                out[#out + 1] = {
                    file = f,
                    title = Data.cleanTitle(r.title or r.filename),
                    authors = r.authors or "",
                    pct = pct, status = status, is_manga = is_manga,
                    series = r.series, series_index = r.series_index,
                }
            end
        end
    end
    -- In-progress first, then new, then finished; alphabetical within groups.
    table.sort(out, function(a, b)
        local ra = (a.status == "complete") and 3 or (a.pct > 0 and 1 or 2)
        local rb = (b.status == "complete") and 3 or (b.pct > 0 and 1 or 2)
        if ra ~= rb then return ra < rb end
        return a.title:lower() < b.title:lower()
    end)
    return out
end

-- ══ Stats (quiet habit layer) ═════════════════════════════════════════════════

function Data.minutesToday()
    if not fileExists(STATS_DB) then return 0 end
    local ok, db = pcall(SQ3.open, STATS_DB, SQ3.OPEN_READONLY)
    if not ok then return 0 end
    local secs = 0
    pcall(function()
        local stmt = db:prepare([[
            SELECT COALESCE(SUM(duration), 0) FROM page_stat_data
            WHERE date(start_time, 'unixepoch', 'localtime')
                = date('now', 'localtime');
        ]])
        local r = stmt:step()
        if r then secs = tonumber(r[1]) or 0 end
        stmt:close()
    end)
    db:close()
    return math.floor(secs / 60)
end

function Data.minutesThisWeek()
    if not fileExists(STATS_DB) then return 0 end
    local ok, db = pcall(SQ3.open, STATS_DB, SQ3.OPEN_READONLY)
    if not ok then return 0 end
    local secs = 0
    pcall(function()
        local stmt = db:prepare([[
            SELECT COALESCE(SUM(duration), 0) FROM page_stat_data
            WHERE start_time > strftime('%s', 'now', '-6 days', 'start of day');
        ]])
        local r = stmt:step()
        if r then secs = tonumber(r[1]) or 0 end
        stmt:close()
    end)
    db:close()
    return math.floor(secs / 60)
end

--- Consecutive days (ending today or yesterday) with ≥ 1 read minute.
function Data.streak()
    if not fileExists(STATS_DB) then return 0 end
    local ok, db = pcall(SQ3.open, STATS_DB, SQ3.OPEN_READONLY)
    if not ok then return 0 end
    local days = {}
    pcall(function()
        local stmt = db:prepare([[
            SELECT date(start_time, 'unixepoch', 'localtime') AS day
            FROM page_stat_data
            WHERE start_time > strftime('%s', 'now', '-400 days')
            GROUP BY day HAVING SUM(duration) >= 60
            ORDER BY day DESC;
        ]])
        for r in stmt:rows() do
            days[#days + 1] = r[1]
        end
        stmt:close()
    end)
    db:close()
    if #days == 0 then return 0 end

    -- Streak survives if the last read day is today OR yesterday.
    local function dayTime(s)
        return os.time{ year = tonumber(s:sub(1, 4)),
                        month = tonumber(s:sub(6, 7)),
                        day = tonumber(s:sub(9, 10)), hour = 12 }
    end
    local today     = os.date("%Y-%m-%d")
    local yesterday = os.date("%Y-%m-%d", os.time() - 86400)
    if days[1] ~= today and days[1] ~= yesterday then return 0 end

    local streak, expect = 0, days[1]
    for _, day in ipairs(days) do
        if day == expect then
            streak = streak + 1
            expect = os.date("%Y-%m-%d", dayTime(day) - 86400)
        else
            break
        end
    end
    return streak
end

function Data.booksFinished()
    if not fileExists(STATS_DB) then return 0 end
    local ok, db = pcall(SQ3.open, STATS_DB, SQ3.OPEN_READONLY)
    if not ok then return 0 end
    local n = 0
    pcall(function()
        local stmt = db:prepare([[
            SELECT COUNT(*) FROM book
            WHERE pages > 0 AND total_read_pages >= pages * 0.95;
        ]])
        local r = stmt:step()
        if r then n = tonumber(r[1]) or 0 end
        stmt:close()
    end)
    db:close()
    return n
end

-- ── Goal setting (G_reader_settings) ──────────────────────────────────────────

function Data.dailyGoalMinutes()
    return G_reader_settings:readSetting("inkfire_daily_goal_min") or 30
end

function Data.setDailyGoalMinutes(min)
    G_reader_settings:saveSetting("inkfire_daily_goal_min", min)
end

--- One snapshot for the whole Hearth screen.
function Data.hearthSnapshot()
    local continue_book = Data.continueBook()
    return {
        continue_book = continue_book,
        up_next       = Data.upNext(continue_book, 3),
        streak        = Data.streak(),
        minutes_today = Data.minutesToday(),
        goal_minutes  = Data.dailyGoalMinutes(),
    }
end

function Data.statsSnapshot()
    return {
        streak         = Data.streak(),
        minutes_today  = Data.minutesToday(),
        minutes_week   = Data.minutesThisWeek(),
        goal_minutes   = Data.dailyGoalMinutes(),
        books_finished = Data.booksFinished(),
    }
end

return Data
