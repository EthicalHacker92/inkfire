--[[
SeriesOS — database layer
Reads bookinfo_cache.sqlite3 (KOReader's book metadata cache) and
statistics.sqlite3 (reading progress) to build a grouped series model.

bookinfo_cache schema (relevant columns):
  directory TEXT, filename TEXT, title TEXT, authors TEXT,
  series TEXT, series_index TEXT, language TEXT, pages INTEGER,
  has_cover INTEGER, cover_fetched TEXT

statistics.sqlite3 schema:
  book(id, title, md5, total_read_pages, total_read_time, pages, series)
  page_stat_data(id_book, page, start_time, duration, total_pages)
--]]

local SQ3         = require("lua-ljsqlite3/init")
local DataStorage = require("datastorage")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")

local DATA_DIR    = DataStorage:getDataDir()
local BOOKINFO_DB = DATA_DIR .. "/bookinfo_cache.sqlite3"
local STATS_DB    = DATA_DIR .. "/statistics.sqlite3"

-- Reading status constants
local STATUS = {
    UNREAD      = "unread",
    IN_PROGRESS = "in_progress",
    COMPLETE    = "complete",
}

local SeriesDB = { STATUS = STATUS }

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function openReadOnly(path)
    if not lfs.attributes(path, "mode") then return nil end
    local ok, db = pcall(SQ3.open, path, SQ3.OPEN_READONLY)
    if not ok then
        logger.warn("SeriesOS: cannot open DB:", path, db)
        return nil
    end
    return db
end

-- Parse a series_index value ("1", "1.5", "Vol.3", etc.) into a sortable number
local function parseIndex(s)
    if not s then return 9999 end
    local n = tonumber(s)
    if n then return n end
    -- Extract leading number from strings like "Vol.03" or "Ch 12"
    n = tonumber(s:match("(%d+%.?%d*)"))
    return n or 9999
end

-- Derive a reading status from stats
local function computeStatus(total_read_pages, total_pages)
    if not total_read_pages or total_read_pages == 0 then
        return STATUS.UNREAD
    end
    total_pages = total_pages or 0
    if total_pages > 0 and total_read_pages >= (total_pages * 0.9) then
        return STATUS.COMPLETE
    end
    return STATUS.IN_PROGRESS
end

-- ── Reading progress lookup ───────────────────────────────────────────────────

-- Returns { [md5] = { total_read_pages, total_read_time } }
local function loadStatsIndex()
    local idx = {}
    local db = openReadOnly(STATS_DB)
    if not db then return idx end
    pcall(function()
        local stmt = db:prepare(
            "SELECT md5, total_read_pages, total_read_time FROM book WHERE md5 IS NOT NULL;"
        )
        for row in stmt:rows() do
            idx[row[1]] = { read_pages = row[2] or 0, read_time = row[3] or 0 }
        end
        stmt:close()
    end)
    db:close()
    return idx
end

-- ── Main query ────────────────────────────────────────────────────────────────

--[[
Returns a table of series, sorted alphabetically, each with:
  {
    name     = "One Piece",
    volumes  = {
      { path, filename, title, series_index, sort_index, pages,
        read_pages, read_time, status, has_cover }
      ...
    },
    total        = 47,
    unread       = 12,
    in_progress  = 3,
    complete     = 32,
    total_time   = 86400,   -- seconds across all volumes
  }
Also returns an "ungrouped" entry for books with no series metadata.
--]]
function SeriesDB.getGrouped()
    local db = openReadOnly(BOOKINFO_DB)
    if not db then
        logger.warn("SeriesOS: bookinfo_cache not found or unreadable")
        return {}
    end

    -- Load stats index for progress data
    local stats = loadStatsIndex()

    -- Fetch all books with at least a title
    local rows = {}
    local ok, err = pcall(function()
        local stmt = db:prepare([[
            SELECT
                directory, filename, title, authors,
                series, series_index, language, pages,
                has_cover, md5
            FROM bookinfo
            WHERE title IS NOT NULL AND title != ''
            ORDER BY series, series_index;
        ]])
        for row in stmt:rows() do
            table.insert(rows, {
                directory    = row[1] or "",
                filename     = row[2] or "",
                title        = row[3] or "",
                authors      = row[4] or "",
                series       = row[5] or "",
                series_index = row[6] or "",
                language     = row[7] or "",
                pages        = tonumber(row[8]) or 0,
                has_cover    = (row[9] == 1 or row[9] == "1"),
                md5          = row[10] or "",
            })
        end
        stmt:close()
    end)
    db:close()

    if not ok then
        logger.warn("SeriesOS query error:", err)
        return {}
    end

    -- Group by series name
    local groups  = {}   -- { [series_name] = { volumes = {...} } }
    local order   = {}   -- preserves insertion order

    for _, row in ipairs(rows) do
        local series_key = (row.series ~= "") and row.series or "__UNGROUPED__"

        if not groups[series_key] then
            groups[series_key] = { name = row.series, volumes = {} }
            table.insert(order, series_key)
        end

        -- Merge with stats
        local st = stats[row.md5] or { read_pages = 0, read_time = 0 }
        local status = computeStatus(st.read_pages, row.pages)

        table.insert(groups[series_key].volumes, {
            path         = row.directory .. row.filename,
            directory    = row.directory,
            filename     = row.filename,
            title        = row.title,
            authors      = row.authors,
            series_index = row.series_index,
            sort_index   = parseIndex(row.series_index),
            pages        = row.pages,
            read_pages   = st.read_pages,
            read_time    = st.read_time,
            status       = status,
            has_cover    = row.has_cover,
            md5          = row.md5,
        })
    end

    -- Sort volumes within each group, then build result list
    local result = {}
    for _, key in ipairs(order) do
        local g = groups[key]

        table.sort(g.volumes, function(a, b)
            return a.sort_index < b.sort_index
        end)

        -- Aggregate counts
        local counts = { unread = 0, in_progress = 0, complete = 0, total_time = 0 }
        for _, v in ipairs(g.volumes) do
            counts[v.status] = (counts[v.status] or 0) + 1
            counts.total_time = counts.total_time + v.read_time
        end

        -- Volume range string: "Vol 1–47"
        local first = g.volumes[1]
        local last  = g.volumes[#g.volumes]
        local vol_range = ""
        if first and first.series_index ~= "" then
            if first == last then
                vol_range = "Vol " .. first.series_index
            else
                vol_range = "Vol " .. first.series_index .. "–" .. last.series_index
            end
        end

        table.insert(result, {
            name        = (key == "__UNGROUPED__") and "Unsorted" or g.name,
            is_ungrouped = (key == "__UNGROUPED__"),
            volumes     = g.volumes,
            total       = #g.volumes,
            vol_range   = vol_range,
            unread      = counts.unread,
            in_progress = counts.in_progress,
            complete    = counts.complete,
            total_time  = counts.total_time,
        })
    end

    -- Sort series alphabetically (ungrouped last)
    table.sort(result, function(a, b)
        if a.is_ungrouped then return false end
        if b.is_ungrouped then return true end
        return a.name:lower() < b.name:lower()
    end)

    return result
end

-- ── Duplicate detection ───────────────────────────────────────────────────────

--[[
Returns pairs of volumes that appear to be duplicates:
  { { a = vol, b = vol, reason = "same_md5" | "same_title_size" }, ... }
--]]
function SeriesDB.findDuplicates(groups)
    local seen_md5   = {}
    local seen_title = {}
    local dupes      = {}

    for _, group in ipairs(groups) do
        for _, vol in ipairs(group.volumes) do
            -- MD5 match (definitive duplicate)
            if vol.md5 ~= "" then
                if seen_md5[vol.md5] then
                    table.insert(dupes, {
                        a = seen_md5[vol.md5], b = vol, reason = "same_md5"
                    })
                else
                    seen_md5[vol.md5] = vol
                end
            end

            -- Same title + same page count (probable duplicate)
            local tk = vol.title:lower() .. "|" .. tostring(vol.pages)
            if seen_title[tk] and vol.md5 == "" then
                table.insert(dupes, {
                    a = seen_title[tk], b = vol, reason = "same_title_size"
                })
            else
                seen_title[tk] = vol
            end
        end
    end

    return dupes
end

-- ── Auto-rename helper ────────────────────────────────────────────────────────

--[[
Returns the canonical filename for a volume:
  "One Piece_Vol01.cbz", "Attack on Titan_Vol003.cbz"
Pads volume index to 3 digits so files sort correctly.
--]]
function SeriesDB.canonicalFilename(vol)
    local series = vol.title:match("^(.-)%s*[Vv]ol") or vol.title
    series = series:gsub("[%/%\\%:%*%?%\"%<%>%|]", ""):match("^%s*(.-)%s*$")

    local idx = parseIndex(vol.series_index)
    local ext  = vol.filename:match("%.([^%.]+)$") or "cbz"

    if idx < 9999 then
        return ("%s_Vol%03d.%s"):format(series, idx, ext)
    else
        return series .. "." .. ext
    end
end

return SeriesDB
