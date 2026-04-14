--[[
InkFire — ClipSync Module
Pure logic layer: highlight aggregation, sidecar parsing, search, export.
NO KOReader UI imports.

State keys published: (none — ClipSync is stateless across documents)
--]]

local SQ3         = require("lua-ljsqlite3/init")
local DataStorage = require("datastorage")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")

local DATA_DIR     = DataStorage:getDataDir()
local CLIP_DB      = DATA_DIR .. "/inkfire_clipsync.sqlite3"
local LIBRARY_ROOT = "/mnt/onboard"

-- ── Database ──────────────────────────────────────────────────────────────────

local function initDB()
    local ok, db = pcall(SQ3.open, CLIP_DB)
    if not ok then return false end
    db:exec([[
        CREATE TABLE IF NOT EXISTS highlights (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            book_path   TEXT,
            book_title  TEXT,
            chapter     TEXT,
            page        INTEGER,
            text        TEXT NOT NULL,
            note        TEXT,
            datetime    TEXT,
            synced_at   INTEGER DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_text ON highlights(text);
        CREATE TABLE IF NOT EXISTS sync_state (
            key   TEXT PRIMARY KEY,
            value TEXT
        );
    ]])
    db:close()
    return true
end

-- ── Sidecar parsing ───────────────────────────────────────────────────────────

local function parseSidecarHighlights(src)
    local highlights = {}
    local in_block = false
    local depth    = 0
    local current  = {}

    for line in src:gmatch("[^\n]+") do
        if line:find('%["highlight"%]') then in_block = true end
        if in_block then
            if line:find("{") then depth = depth + 1 end
            if line:find("}") then
                depth = depth - 1
                if depth == 1 and current.text then
                    table.insert(highlights, current)
                    current = {}
                end
            end
            local k, v = line:match('%["([^"]+)"%]%s*=%s*"(.*)"')
            if k == "text"     then current.text     = v:gsub('\\"', '"') end
            if k == "note"     then current.note     = v:gsub('\\"', '"') end
            if k == "chapter"  then current.chapter  = v end
            if k == "datetime" then current.datetime = v end
            local pg = line:match('%["pageno"%]%s*=%s*(%d+)')
            if pg then current.page = tonumber(pg) end
        end
    end
    return highlights
end

local function importSidecar(db, book_path, metadata_path)
    local f = io.open(metadata_path, "r")
    if not f then return 0 end
    local src = f:read("*a")
    f:close()

    local book_title = book_path:match("([^/]+)$") or book_path
    book_title = book_title:gsub("%.[^%.]+$", ""):gsub("[_%-]", " ")

    local highlights = parseSidecarHighlights(src)
    local imported   = 0

    for _, h in ipairs(highlights) do
        local exists
        pcall(function()
            local row = db:rowexec(
                "SELECT 1 FROM highlights WHERE book_path = ? AND text = ?;",
                book_path, h.text
            )
            exists = row ~= nil
        end)
        if not exists and h.text and h.text ~= "" then
            pcall(function()
                local stmt = db:prepare([[
                    INSERT INTO highlights (book_path, book_title, chapter, page, text, note, datetime)
                    VALUES (?, ?, ?, ?, ?, ?, ?);
                ]])
                stmt:bind(1, book_path)
                stmt:bind(2, book_title)
                stmt:bind(3, h.chapter)
                stmt:bind(4, h.page)
                stmt:bind(5, h.text)
                stmt:bind(6, h.note)
                stmt:bind(7, h.datetime)
                stmt:step()
                stmt:close()
            end)
            imported = imported + 1
        end
    end
    return imported
end

local function walkSdrDirs(root, callback, depth, seen)
    depth = depth or 0
    seen  = seen  or {}
    if depth > 10 then return end

    local ok_real, real = pcall(function() return lfs.realpath and lfs.realpath(root) or root end)
    real = ok_real and real or root
    if seen[real] then return end
    seen[real] = true

    local ok_dir, iter = pcall(lfs.dir, root)
    if not ok_dir then return end

    for entry in iter do
        if entry ~= "." and entry ~= ".." then
            local full = root .. "/" .. entry
            local mode = lfs.attributes(full, "mode")
            if mode == "directory" then
                if entry:match("%.sdr$") then
                    for sub in lfs.dir(full) do
                        if sub:match("^metadata%.") and sub:match("%.lua$") then
                            local book_name = entry:gsub("%.sdr$", "")
                            callback(root .. "/" .. book_name, full .. "/" .. sub)
                        end
                    end
                else
                    pcall(function() walkSdrDirs(full, callback, depth + 1, seen) end)
                end
            end
        end
    end
end

-- ── Public API ────────────────────────────────────────────────────────────────

local ClipSync = {}

--- Initialize the highlight database.
function ClipSync.initDB()
    return initDB()
end

--- Return total highlight count.
function ClipSync.getHighlightCount()
    local ok, db = pcall(SQ3.open, CLIP_DB, SQ3.OPEN_READONLY)
    if not ok then return 0 end
    local row
    pcall(function()
        row = db:rowexec("SELECT COUNT(*) FROM highlights;")
    end)
    db:close()
    return (row and tonumber(row[1])) or 0
end

--- Sync highlights from all sidecar files.
--- Returns { count, has_library } where has_library=false on non-device.
function ClipSync.syncFromSidecars()
    local has_library = lfs.attributes(LIBRARY_ROOT, "mode") ~= nil
    if not has_library then
        return { count = 0, has_library = false }
    end

    local ok, db = pcall(SQ3.open, CLIP_DB)
    if not ok then return { count = 0, has_library = true } end

    local imported = 0
    walkSdrDirs(LIBRARY_ROOT, function(book_path, metadata_path)
        local n = importSidecar(db, book_path, metadata_path)
        imported = imported + n
    end)
    db:close()

    return { count = imported, has_library = true }
end

--- Search highlights. Returns array of result rows.
function ClipSync.searchHighlights(query)
    local ok, db = pcall(SQ3.open, CLIP_DB, SQ3.OPEN_READONLY)
    if not ok then return {} end

    local results = {}
    pcall(function()
        local stmt = db:prepare(
            "SELECT id, book_title, chapter, page, text, note, datetime " ..
            "FROM highlights WHERE text LIKE ? ORDER BY datetime DESC LIMIT 50;"
        )
        stmt:bind(1, "%" .. query .. "%")
        for row in stmt:rows() do
            table.insert(results, {
                id         = row[1],
                book_title = row[2],
                chapter    = row[3],
                page       = row[4],
                text       = row[5],
                note       = row[6],
                datetime   = row[7],
            })
        end
        stmt:close()
    end)
    db:close()
    return results
end

--- Export all highlights to Obsidian markdown.
--- Returns { path, error } — error is nil on success.
function ClipSync.exportToObsidian()
    local ok, db = pcall(SQ3.open, CLIP_DB, SQ3.OPEN_READONLY)
    if not ok then return { error = "Cannot open DB" } end

    local out_path = LIBRARY_ROOT .. "/highlights_export.md"
    local f, err   = io.open(out_path, "w")
    if not f then
        db:close()
        return { error = tostring(err) }
    end

    f:write("# KOReader Highlights\n\n")
    f:write(("_Exported: %s_\n\n"):format(os.date("%Y-%m-%d %H:%M")))

    local current_book = nil
    pcall(function()
        local stmt = db:prepare(
            "SELECT book_title, chapter, page, text, note, datetime " ..
            "FROM highlights ORDER BY book_title, datetime ASC;"
        )
        for row in stmt:rows() do
            local title = row[1] or "Unknown"
            if title ~= current_book then
                f:write(("## %s\n\n"):format(title))
                current_book = title
            end
            f:write(('> "%s"\n'):format(row[4]))
            if row[5] and row[5] ~= "" then f:write(("  — %s\n"):format(row[5])) end
            if row[3] then f:write(("  p.%d\n"):format(row[3])) end
            f:write("\n")
        end
        stmt:close()
    end)
    f:close()
    db:close()
    return { path = out_path }
end

--- Export all highlights to Readwise CSV.
--- Returns { path, error }.
function ClipSync.exportToReadwise()
    local ok, db = pcall(SQ3.open, CLIP_DB, SQ3.OPEN_READONLY)
    if not ok then return { error = "Cannot open DB" } end

    local out_path = LIBRARY_ROOT .. "/readwise_export.csv"
    local f, err   = io.open(out_path, "w")
    if not f then
        db:close()
        return { error = tostring(err) }
    end

    f:write("Highlight,Title,Author,URL,Note,Location,Date\n")
    pcall(function()
        local stmt = db:prepare(
            "SELECT text, book_title, note, page, datetime FROM highlights ORDER BY datetime DESC;"
        )
        for row in stmt:rows() do
            local function csv(s)
                s = tostring(s or "")
                if s:find('[,"\n]') then s = '"' .. s:gsub('"', '""') .. '"' end
                return s
            end
            f:write(table.concat({
                csv(row[1]), csv(row[2]), "", "", csv(row[3]),
                csv(row[4] and "Page " .. row[4] or ""),
                csv(row[5]),
            }, ",") .. "\n")
        end
        stmt:close()
    end)
    f:close()
    db:close()
    return { path = out_path }
end

--- Pick a random highlight for daily memory.
--- Returns { text, book_title } or nil.
function ClipSync.getRandomHighlight()
    local ok, db = pcall(SQ3.open, CLIP_DB, SQ3.OPEN_READONLY)
    if not ok then return nil end
    local row
    pcall(function()
        row = db:rowexec(
            "SELECT text, book_title FROM highlights ORDER BY RANDOM() LIMIT 1;"
        )
    end)
    db:close()
    if row and row[1] then
        return { text = row[1], book_title = row[2] or "" }
    end
    return nil
end

--- Check if daily memory should show (once per day).
--- Returns highlight row, or nil if already shown today or no highlights.
function ClipSync.getDailyMemory()
    local ok, db = pcall(SQ3.open, CLIP_DB)
    if not ok then return nil end

    local today = os.date("%Y-%m-%d")
    local last_row
    pcall(function()
        last_row = db:rowexec("SELECT value FROM sync_state WHERE key = 'last_memory_date';")
    end)
    local last = last_row and last_row[1] or ""

    if last == today then db:close(); return nil end

    local h_row
    pcall(function()
        h_row = db:rowexec(
            "SELECT text, book_title FROM highlights ORDER BY RANDOM() LIMIT 1;"
        )
    end)

    if h_row and h_row[1] then
        pcall(function()
            local stmt = db:prepare(
                "INSERT OR REPLACE INTO sync_state VALUES ('last_memory_date', ?);"
            )
            stmt:bind(1, today)
            stmt:step()
            stmt:close()
        end)
        db:close()
        return { text = h_row[1], book_title = h_row[2] or "" }
    end

    db:close()
    return nil
end

return ClipSync
