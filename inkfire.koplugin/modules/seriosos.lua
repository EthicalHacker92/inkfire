--[[
InkFire — SeriesOS Module
Pure logic layer: series grouping, reading status, duplicate detection, auto-rename.
Reads bookinfo_cache.sqlite3 and statistics.sqlite3.
NO KOReader UI imports.

State keys published: (none — SeriesOS is on-demand query only)
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

local function parseIndex(s)
    if not s then return 9999 end
    local n = tonumber(s)
    if n then return n end
    n = tonumber(s:match("(%d+%.?%d*)"))
    return n or 9999
end

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

-- ── Canonical filename ────────────────────────────────────────────────────────

local function canonicalFilename(vol)
    local series = vol.title:match("^(.-)%s*[Vv]ol") or vol.title
    series = series:gsub("[%/%\\%:%*%?%\"%<%>%|]", ""):match("^%s*(.-)%s*$")

    local idx = parseIndex(vol.series_index)
    local ext = vol.filename:match("%.([^%.]+)$") or "cbz"

    if idx < 9999 then
        return ("%s_Vol%03d.%s"):format(series, idx, ext)
    else
        return series .. "." .. ext
    end
end

-- ── Public API ────────────────────────────────────────────────────────────────

local SeriesOS = {}
SeriesOS.STATUS = STATUS

--[[
Returns grouped series list sorted alphabetically. Each entry:
  { name, volumes, total, unread, in_progress, complete, total_time, vol_range, is_ungrouped }
--]]
function SeriesOS.getGrouped()
    local db = openReadOnly(BOOKINFO_DB)
    if not db then
        logger.warn("SeriesOS: bookinfo_cache not found or unreadable")
        return {}
    end

    local stats = loadStatsIndex()

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

    local groups = {}
    local order  = {}

    for _, row in ipairs(rows) do
        local series_key = (row.series ~= "") and row.series or "__UNGROUPED__"

        if not groups[series_key] then
            groups[series_key] = { name = row.series, volumes = {} }
            table.insert(order, series_key)
        end

        local st     = stats[row.md5] or { read_pages = 0, read_time = 0 }
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

    local result = {}
    for _, key in ipairs(order) do
        local g = groups[key]

        table.sort(g.volumes, function(a, b)
            return a.sort_index < b.sort_index
        end)

        local counts = { unread = 0, in_progress = 0, complete = 0, total_time = 0 }
        for _, v in ipairs(g.volumes) do
            counts[v.status] = (counts[v.status] or 0) + 1
            counts.total_time = counts.total_time + v.read_time
        end

        local first     = g.volumes[1]
        local last      = g.volumes[#g.volumes]
        local vol_range = ""
        if first and first.series_index ~= "" then
            if first == last then
                vol_range = "Vol " .. first.series_index
            else
                vol_range = "Vol " .. first.series_index .. "–" .. last.series_index
            end
        end

        table.insert(result, {
            name         = (key == "__UNGROUPED__") and "Unsorted" or g.name,
            is_ungrouped = (key == "__UNGROUPED__"),
            volumes      = g.volumes,
            total        = #g.volumes,
            vol_range    = vol_range,
            unread       = counts.unread,
            in_progress  = counts.in_progress,
            complete     = counts.complete,
            total_time   = counts.total_time,
        })
    end

    table.sort(result, function(a, b)
        if a.is_ungrouped then return false end
        if b.is_ungrouped then return true end
        return a.name:lower() < b.name:lower()
    end)

    return result
end

--- Filter volumes by status. filter = "all"|"unread"|"in_progress"|"complete".
function SeriesOS.filterVolumes(volumes, filter)
    if filter == "all" then return volumes end
    local out = {}
    for _, v in ipairs(volumes) do
        if v.status == filter then table.insert(out, v) end
    end
    return out
end

--- Find duplicate volumes across all groups.
--- Returns array of { a, b, reason }.
function SeriesOS.findDuplicates(groups)
    local seen_md5   = {}
    local seen_title = {}
    local dupes      = {}

    for _, group in ipairs(groups) do
        for _, vol in ipairs(group.volumes) do
            if vol.md5 ~= "" then
                if seen_md5[vol.md5] then
                    table.insert(dupes, { a = seen_md5[vol.md5], b = vol, reason = "same_md5" })
                else
                    seen_md5[vol.md5] = vol
                end
            end

            local tk = vol.title:lower() .. "|" .. tostring(vol.pages)
            if seen_title[tk] and vol.md5 == "" then
                table.insert(dupes, { a = seen_title[tk], b = vol, reason = "same_title_size" })
            else
                seen_title[tk] = vol
            end
        end
    end

    return dupes
end

--- Returns the canonical filename for a volume.
function SeriesOS.canonicalFilename(vol)
    return canonicalFilename(vol)
end

--- Mark a volume as complete in statistics.sqlite3.
--- Returns true on success.
function SeriesOS.markComplete(vol)
    local ok, SQ3_mod = pcall(require, "lua-ljsqlite3/init")
    if not ok then return false end

    local stats_path = DataStorage:getDataDir() .. "/statistics.sqlite3"
    local db_ok, db  = pcall(SQ3_mod.open, stats_path)
    if not db_ok then return false end

    local success = false
    pcall(function()
        local stmt = db:prepare("UPDATE book SET total_read_pages = pages WHERE md5 = ?;")
        stmt:bind(1, vol.md5)
        stmt:step()
        stmt:close()
        success = true
    end)
    db:close()

    return success
end

--- Rename a volume file on disk.
--- Returns { ok, error }.
function SeriesOS.renameVolume(vol, new_name)
    local new_path = vol.directory .. new_name
    if lfs.attributes(new_path, "mode") then
        return { ok = false, error = "target exists" }
    end
    local ok, err = os.rename(vol.path, new_path)
    if ok then
        return { ok = true, new_path = new_path, new_name = new_name }
    else
        return { ok = false, error = tostring(err) }
    end
end

--- Returns a list of volumes that need renaming.
function SeriesOS.getPendingRenames(groups)
    local pending = {}
    for _, group in ipairs(groups) do
        for _, vol in ipairs(group.volumes) do
            local canonical = canonicalFilename(vol)
            if vol.filename ~= canonical then
                table.insert(pending, { vol = vol, new_name = canonical })
            end
        end
    end
    return pending
end

return SeriesOS
