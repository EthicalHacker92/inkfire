--[[
ClipSync — unified highlight database, cross-library search, export to Notion/Obsidian/Readwise
Aggregates highlights from all .sdr sidecar files into a searchable SQLite database.
Surfaces a random past highlight on device wake (daily memory feature).
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local InputDialog     = require("ui/widget/inputdialog")
local Menu            = require("ui/widget/menu")
local SQ3             = require("lua-ljsqlite3/init")
local DataStorage     = require("datastorage")
local lfs             = require("libs/libkoreader-lfs")
local logger          = require("logger")
local socket_url      = require("socket.url")
local _               = require("gettext")
local T               = require("ffi/util").template

-- ── Constants ─────────────────────────────────────────────────────────────────

local DATA_DIR   = DataStorage:getDataDir()
local CLIP_DB    = DATA_DIR .. "/clipsync.sqlite3"
-- Kobo's library root — sidecar dirs live alongside books
local LIBRARY_ROOT = "/mnt/onboard"

-- ── Plugin class ──────────────────────────────────────────────────────────────

local ClipSync = WidgetContainer:extend{
    name          = "clipsync",
    last_sync_at  = 0,
    highlight_count = 0,
}

function ClipSync:init()
    self:initDB()
    self.ui.menu:registerToMainMenu(self)
    -- Show daily memory on first init (device wake)
    UIManager:scheduleIn(3, function() self:maybeShowDailyMemory() end)
end

-- ── Database ──────────────────────────────────────────────────────────────────

function ClipSync:initDB()
    local ok, db = pcall(SQ3.open, CLIP_DB)
    if not ok then return end
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
end

function ClipSync:getHighlightCount()
    local ok, db = pcall(SQ3.open, CLIP_DB, SQ3.OPEN_READONLY)
    if not ok then return 0 end
    local row
    pcall(function()
        row = db:rowexec("SELECT COUNT(*) FROM highlights;")
    end)
    db:close()
    return (row and tonumber(row[1])) or 0
end

-- ── Sidecar sync ──────────────────────────────────────────────────────────────

--- Scan LIBRARY_ROOT for .sdr directories and import new highlights.
function ClipSync:syncFromSidecars()
    if not lfs.attributes(LIBRARY_ROOT, "mode") then
        -- Emulator fallback
        UIManager:show(InfoMessage:new{
            text    = _("ClipSync: /mnt/onboard not found. Run on device."),
            timeout = 3,
        })
        return 0
    end

    local ok, db = pcall(SQ3.open, CLIP_DB)
    if not ok then return 0 end

    local imported = 0
    self:walkSdrDirs(LIBRARY_ROOT, function(book_path, metadata_path)
        local count = self:importSidecar(db, book_path, metadata_path)
        imported = imported + count
    end)

    db:close()
    self.last_sync_at = os.time()

    UIManager:show(InfoMessage:new{
        text    = T(_("ClipSync: imported %1 new highlights."), imported),
        timeout = 3,
    })
    return imported
end

function ClipSync:walkSdrDirs(root, callback)
    for entry in lfs.dir(root) do
        if entry ~= "." and entry ~= ".." then
            local full = root .. "/" .. entry
            local mode = lfs.attributes(full, "mode")
            if mode == "directory" then
                if entry:match("%.sdr$") then
                    -- This is a sidecar dir — find metadata.*.lua inside
                    for sub in lfs.dir(full) do
                        if sub:match("^metadata%.") and sub:match("%.lua$") then
                            local book_name = entry:gsub("%.sdr$", "")
                            local book_path = root .. "/" .. book_name
                            callback(book_path, full .. "/" .. sub)
                        end
                    end
                else
                    -- Recurse into subdirectory
                    pcall(function() self:walkSdrDirs(full, callback) end)
                end
            end
        end
    end
end

function ClipSync:importSidecar(db, book_path, metadata_path)
    local f = io.open(metadata_path, "r")
    if not f then return 0 end
    local src = f:read("*a")
    f:close()

    local book_title = book_path:match("([^/]+)$") or book_path
    -- Strip extension for cleaner title
    book_title = book_title:gsub("%.[^%.]+$", ""):gsub("[_%-]", " ")

    local highlights = self:parseSidecarHighlights(src)
    local imported   = 0

    for _, h in ipairs(highlights) do
        -- Skip if we already have this exact text from this book
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
                db:exec([[
                    INSERT INTO highlights (book_path, book_title, chapter, page, text, note, datetime)
                    VALUES (?, ?, ?, ?, ?, ?, ?);
                ]], book_path, book_title, h.chapter, h.page, h.text, h.note, h.datetime)
            end)
            imported = imported + 1
        end
    end
    return imported
end

--- Minimal KOReader sidecar parser — extracts highlight entries.
function ClipSync:parseSidecarHighlights(src)
    local highlights = {}
    -- KOReader highlight format:
    -- ["highlight"] = { [n] = { ["text"]="...", ["note"]="...", ["datetime"]="...", ["pageno"]=N } }
    local in_block = false
    local depth    = 0
    local current  = {}

    -- Simple line-by-line extractor for key=value pairs inside entries
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

-- ── Search ────────────────────────────────────────────────────────────────────

function ClipSync:searchHighlights(query)
    local ok, db = pcall(SQ3.open, CLIP_DB, SQ3.OPEN_READONLY)
    if not ok then return {} end

    local results = {}
    pcall(function()
        local stmt = db:prepare(
            "SELECT id, book_title, chapter, page, text, note, datetime " ..
            "FROM highlights WHERE text LIKE ? ORDER BY datetime DESC LIMIT 50;"
        )
        -- Bind needs to be called with statement
        local pat = "%" .. query .. "%"
        for row in stmt:rows() do
            if row[5] and row[5]:lower():find(query:lower(), 1, true) then
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
        end
        stmt:close()
    end)
    db:close()
    return results
end

-- ── Daily memory ──────────────────────────────────────────────────────────────

function ClipSync:maybeShowDailyMemory()
    -- Only show once per day
    local ok_s, db = pcall(SQ3.open, CLIP_DB)
    if not ok_s then return end

    local today = os.date("%Y-%m-%d")
    local row
    pcall(function()
        row = db:rowexec("SELECT value FROM sync_state WHERE key = 'last_memory_date';")
    end)
    local last = row and row[1] or ""

    if last == today then db:close(); return end

    -- Pick a random highlight
    local h_row
    pcall(function()
        h_row = db:rowexec(
            "SELECT text, book_title FROM highlights ORDER BY RANDOM() LIMIT 1;"
        )
    end)

    if h_row and h_row[1] then
        UIManager:show(InfoMessage:new{
            text    = T(_("💭 Memory\n\n\"%1\"\n\n— %2"), h_row[1], h_row[2] or ""),
            timeout = 8,
        })
        pcall(function()
            db:exec("INSERT OR REPLACE INTO sync_state VALUES ('last_memory_date', ?);", today)
        end)
    end
    db:close()
end

-- ── Export ────────────────────────────────────────────────────────────────────

--- Export all highlights as Obsidian-style markdown to a file.
function ClipSync:exportToObsidian()
    local ok, db = pcall(SQ3.open, CLIP_DB, SQ3.OPEN_READONLY)
    if not ok then return end

    local out_path = LIBRARY_ROOT .. "/highlights_export.md"
    local f, err   = io.open(out_path, "w")
    if not f then
        db:close()
        UIManager:show(InfoMessage:new{ text = T(_("Export failed: %1"), tostring(err)) })
        return
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

    UIManager:show(InfoMessage:new{
        text    = T(_("Exported to:\n%1"), out_path),
        timeout = 4,
    })
end

--- Export as Readwise CSV format
function ClipSync:exportToReadwise()
    local ok, db = pcall(SQ3.open, CLIP_DB, SQ3.OPEN_READONLY)
    if not ok then return end

    local out_path = LIBRARY_ROOT .. "/readwise_export.csv"
    local f, err = io.open(out_path, "w")
    if not f then
        db:close()
        UIManager:show(InfoMessage:new{ text = T(_("Export failed: %1"), tostring(err)) })
        return
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

    UIManager:show(InfoMessage:new{
        text    = T(_("Readwise CSV exported to:\n%1"), out_path),
        timeout = 4,
    })
end

-- ── Menu ──────────────────────────────────────────────────────────────────────

function ClipSync:addToMainMenu(menu_items)
    menu_items.clipsync = {
        text = _("ClipSync"),
        sub_item_table = {
            {
                text_func = function()
                    local n = self:getHighlightCount()
                    return T(_("Search Highlights (%1)"), n)
                end,
                callback = function() self:openSearchUI() end,
            },
            {
                text     = _("Sync from Device"),
                callback = function() self:syncFromSidecars() end,
            },
            {
                text = _("Export"),
                sub_item_table = {
                    {
                        text     = _("Obsidian Markdown"),
                        callback = function() self:exportToObsidian() end,
                    },
                    {
                        text     = _("Readwise CSV"),
                        callback = function() self:exportToReadwise() end,
                    },
                },
            },
            {
                text     = _("Daily Memory"),
                callback = function()
                    -- Force show regardless of date
                    local ok, db = pcall(SQ3.open, CLIP_DB, SQ3.OPEN_READONLY)
                    if not ok then return end
                    local row
                    pcall(function()
                        row = db:rowexec(
                            "SELECT text, book_title FROM highlights ORDER BY RANDOM() LIMIT 1;"
                        )
                    end)
                    db:close()
                    if row and row[1] then
                        UIManager:show(InfoMessage:new{
                            text = T(_("💭 Memory\n\n\"%1\"\n\n— %2"), row[1], row[2] or ""),
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

function ClipSync:openSearchUI()
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
                text     = _("Search"),
                is_enter_default = true,
                callback = function()
                    local q = dialog:getInputText()
                    UIManager:close(dialog)
                    if q and q ~= "" then
                        self:showSearchResults(q)
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

function ClipSync:showSearchResults(query)
    local results = self:searchHighlights(query)
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
        table.insert(items, {
            text      = preview,
            mandatory = h.book_title,
            callback  = function()
                UIManager:show(InfoMessage:new{
                    text = ('"' .. h.text .. '"\n\n— ' .. (h.book_title or "")),
                })
            end,
        })
    end

    local menu = Menu:new{
        title         = T(_("Results: %1 (%2)"), query, #results),
        item_table    = items,
        is_borderless  = true,
        width          = require("device/screen"):getWidth(),
        height         = require("device/screen"):getHeight(),
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

return ClipSync
