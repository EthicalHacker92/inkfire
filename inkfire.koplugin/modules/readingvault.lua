--[[
InkFire — ReadingVault Module
Pure logic layer: session tracking, daily/yearly goals, streaks.
NO KOReader UI imports.

State keys published:
  - readingvault.session_active  boolean
  - readingvault.session_start   integer (unix timestamp) or nil
--]]

local SQ3         = require("lua-ljsqlite3/init")
local DataStorage = require("datastorage")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")

local State = require("plugins/inkfire.koplugin/modules/state")

local DATA_DIR  = DataStorage:getDataDir()
local STATS_DB  = DATA_DIR .. "/statistics.sqlite3"
local VAULT_DB  = DATA_DIR .. "/inkfire_vault.sqlite3"

local DEFAULT_DAILY_GOAL_SECS = 30 * 60   -- 30 minutes
local DEFAULT_YEARLY_GOAL     = 50

-- ── Database ──────────────────────────────────────────────────────────────────

local function initDB()
    local ok, db = pcall(SQ3.open, VAULT_DB)
    if not ok then return end
    db:exec([[
        CREATE TABLE IF NOT EXISTS goals (
            key   TEXT PRIMARY KEY,
            value TEXT
        );
        CREATE TABLE IF NOT EXISTS sessions (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            book_title TEXT,
            book_md5   TEXT,
            started_at INTEGER,
            ended_at   INTEGER,
            duration   INTEGER,
            pages_read INTEGER
        );
    ]])
    db:close()
end

local function getSetting(key, default)
    local ok, db = pcall(SQ3.open, VAULT_DB, SQ3.OPEN_READONLY)
    if not ok then return default end
    local row
    pcall(function()
        row = db:rowexec("SELECT value FROM goals WHERE key = ?;", key)
    end)
    db:close()
    if row and row[1] then return row[1] end
    return default
end

local function setSetting(key, value)
    local ok, db = pcall(SQ3.open, VAULT_DB)
    if not ok then return end
    pcall(function()
        local stmt = db:prepare("INSERT OR REPLACE INTO goals VALUES (?, ?);")
        stmt:bind(1, key)
        stmt:bind(2, tostring(value))
        stmt:step()
        stmt:close()
    end)
    db:close()
end

-- ── Internal session state ────────────────────────────────────────────────────

local _session_start = nil
local _session_pages = 0
local _session_book  = ""

-- ── Public API ────────────────────────────────────────────────────────────────

local ReadingVault = {}

--- Initialize DB tables (call once on plugin load).
function ReadingVault.init()
    initDB()
end

--- Called when a document opens. Records session start.
function ReadingVault.onDocumentOpen(filepath, doc_props)
    _session_start = os.time()
    _session_pages = 0
    _session_book  = filepath or ""
    State.set("readingvault.session_active", true)
    State.set("readingvault.session_start",  _session_start)
    logger.dbg("ReadingVault: session started for", _session_book)
end

--- Called on page turn. Increments page counter.
function ReadingVault.onPageUpdate()
    _session_pages = _session_pages + 1
end

--[[
Called when a document closes.
Returns session summary data (or nil if session was too short):
  { duration, minutes, today_secs, goal_secs, goal_pct, streak, above_goal }
--]]
function ReadingVault.onDocumentClose(doc_title)
    if not _session_start then return nil end

    local duration = os.time() - _session_start
    _session_start = nil

    State.set("readingvault.session_active", false)
    State.set("readingvault.session_start",  nil)

    if duration < 30 then
        logger.dbg("ReadingVault: session too short (<30s), skipping")
        return nil
    end

    -- Save to DB
    local ok, db = pcall(SQ3.open, VAULT_DB)
    if ok then
        pcall(function()
            local stmt = db:prepare([[
                INSERT INTO sessions (book_title, book_md5, started_at, ended_at, duration, pages_read)
                VALUES (?, ?, ?, ?, ?, ?);
            ]])
            stmt:bind(1, doc_title or "")
            stmt:bind(2, "")
            stmt:bind(3, os.time() - duration)
            stmt:bind(4, os.time())
            stmt:bind(5, duration)
            stmt:bind(6, _session_pages)
            stmt:step()
            stmt:close()
        end)
        db:close()
    end
    _session_pages = 0

    -- Build summary
    local goal_secs  = tonumber(getSetting("daily_goal", DEFAULT_DAILY_GOAL_SECS))
    local today_secs = ReadingVault.getTodaySeconds()
    local streak     = ReadingVault.getStreak()
    local above      = math.floor((today_secs - goal_secs) / 60)

    return {
        duration   = duration,
        minutes    = math.floor(duration / 60),
        today_secs = today_secs,
        goal_secs  = goal_secs,
        goal_pct   = goal_secs > 0 and math.floor(today_secs / goal_secs * 100) or 0,
        streak     = streak,
        above_goal = above,
        hit_goal   = today_secs >= goal_secs,
    }
end

--- Returns today's total reading seconds from statistics.sqlite3.
function ReadingVault.getTodaySeconds()
    if not lfs.attributes(STATS_DB, "mode") then return 0 end
    local ok, db = pcall(SQ3.open, STATS_DB, SQ3.OPEN_READONLY)
    if not ok then return 0 end

    local today = os.date("%Y-%m-%d")
    local row
    pcall(function()
        row = db:rowexec(
            "SELECT COALESCE(SUM(duration),0) FROM page_stat_data " ..
            "WHERE date(start_time,'unixepoch','localtime') = ?;",
            today
        )
    end)
    db:close()
    return (row and tonumber(row[1])) or 0
end

--- Returns current reading streak in days.
function ReadingVault.getStreak()
    if not lfs.attributes(STATS_DB, "mode") then return 0 end
    local ok, db = pcall(SQ3.open, STATS_DB, SQ3.OPEN_READONLY)
    if not ok then return 0 end

    local rows = {}
    pcall(function()
        local stmt = db:prepare([[
            SELECT date(start_time,'unixepoch','localtime') AS day
            FROM page_stat_data
            WHERE start_time > strftime('%s','now','-365 days')
            GROUP BY day HAVING SUM(duration) >= 60
            ORDER BY day DESC;
        ]])
        for row in stmt:rows() do
            table.insert(rows, row[1])
        end
        stmt:close()
    end)
    db:close()

    if #rows == 0 then return 0 end

    local streak = 0
    local expect = os.date("%Y-%m-%d")
    for _, day in ipairs(rows) do
        if day == expect then
            streak = streak + 1
            local t = os.time{
                year  = tonumber(day:sub(1,4)),
                month = tonumber(day:sub(6,7)),
                day   = tonumber(day:sub(9,10)),
            }
            expect = os.date("%Y-%m-%d", t - 86400)
        else
            break
        end
    end
    return streak
end

--- Returns daily goal in minutes.
function ReadingVault.getDailyGoalMinutes()
    local secs = tonumber(getSetting("daily_goal", DEFAULT_DAILY_GOAL_SECS))
    return math.floor(secs / 60)
end

--- Sets daily goal in minutes.
function ReadingVault.setDailyGoal(minutes)
    setSetting("daily_goal", minutes * 60)
end

--- Returns yearly goal (number of books).
function ReadingVault.getYearlyGoal()
    return tonumber(getSetting("yearly_goal", DEFAULT_YEARLY_GOAL))
end

--- Sets yearly goal.
function ReadingVault.setYearlyGoal(books)
    setSetting("yearly_goal", books)
end

--- Returns today's full stats: { minutes, pct, streak }.
function ReadingVault.getTodayStats()
    local today_secs = ReadingVault.getTodaySeconds()
    local goal_secs  = tonumber(getSetting("daily_goal", DEFAULT_DAILY_GOAL_SECS))
    local streak     = ReadingVault.getStreak()
    return {
        minutes = math.floor(today_secs / 60),
        pct     = goal_secs > 0 and math.floor(today_secs / goal_secs * 100) or 0,
        streak  = streak,
    }
end

return ReadingVault
