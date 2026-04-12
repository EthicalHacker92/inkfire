--[[
ReadingVault — daily goals, streaks, session summaries, stats JSON endpoint
Hooks into document close to show a session summary popup.
Persists goals in readingvault.sqlite3.
Exposes /api/stats JSON endpoint piggy-backed on TransferBridge's HTTP server.
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local InputDialog     = require("ui/widget/inputdialog")
local SQ3             = require("lua-ljsqlite3/init")
local DataStorage     = require("datastorage")
local lfs             = require("libs/libkoreader-lfs")
local logger          = require("logger")
local _               = require("gettext")
local T               = require("ffi/util").template

-- ── Constants ─────────────────────────────────────────────────────────────────

local DATA_DIR   = DataStorage:getDataDir()
local STATS_DB   = DATA_DIR .. "/statistics.sqlite3"
local VAULT_DB   = DATA_DIR .. "/readingvault.sqlite3"

local DEFAULT_DAILY_GOAL_SECS = 30 * 60   -- 30 minutes
local DEFAULT_YEARLY_GOAL     = 50

-- ── Plugin class ──────────────────────────────────────────────────────────────

local ReadingVault = WidgetContainer:extend{
    name           = "readingvault",
    session_start  = nil,   -- os.time() when current doc opened
    session_pages  = 0,
    session_book   = nil,
}

function ReadingVault:init()
    self:initDB()
    self.ui.menu:registerToMainMenu(self)
end

-- ── Database ──────────────────────────────────────────────────────────────────

function ReadingVault:initDB()
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

function ReadingVault:getSetting(key, default)
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

function ReadingVault:setSetting(key, value)
    local ok, db = pcall(SQ3.open, VAULT_DB)
    if not ok then return end
    pcall(function()
        db:exec("INSERT OR REPLACE INTO goals VALUES (?, ?);", key, tostring(value))
    end)
    db:close()
end

-- ── Hooks ─────────────────────────────────────────────────────────────────────

function ReadingVault:onReaderReady()
    self.session_start = os.time()
    self.session_pages = 0
    local doc = self.ui.document
    self.session_book = doc and (doc.file or "") or ""
end

function ReadingVault:onPageUpdate(pageno)
    self.session_pages = (self.session_pages or 0) + 1
end

function ReadingVault:onCloseDocument()
    if not self.session_start then return end

    local duration = os.time() - self.session_start
    if duration < 30 then
        self.session_start = nil
        return   -- ignore accidental opens < 30s
    end

    self:saveSession(duration)
    self:showSessionSummary(duration)
    self.session_start = nil
    self.session_pages = 0
end

-- ── Session tracking ──────────────────────────────────────────────────────────

function ReadingVault:saveSession(duration)
    local doc   = self.ui and self.ui.document
    local title = doc and doc:getProps and doc:getProps().title or ""
    local md5   = ""

    local ok, db = pcall(SQ3.open, VAULT_DB)
    if not ok then return end
    pcall(function()
        db:exec([[
            INSERT INTO sessions (book_title, book_md5, started_at, ended_at, duration, pages_read)
            VALUES (?, ?, ?, ?, ?, ?);
        ]], title, md5, self.session_start, os.time(), duration, self.session_pages or 0)
    end)
    db:close()
end

function ReadingVault:getTodaySeconds()
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

function ReadingVault:getStreak()
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
            -- Move expect back one day
            local t = os.time{ year=tonumber(day:sub(1,4)),
                                month=tonumber(day:sub(6,7)),
                                day=tonumber(day:sub(9,10)) }
            expect = os.date("%Y-%m-%d", t - 86400)
        else
            break
        end
    end
    return streak
end

-- ── Session summary popup ─────────────────────────────────────────────────────

function ReadingVault:showSessionSummary(duration)
    local goal_secs   = tonumber(self:getSetting("daily_goal", DEFAULT_DAILY_GOAL_SECS))
    local today_secs  = self:getTodaySeconds()
    local streak      = self:getStreak()

    local mins        = math.floor(duration / 60)
    local above       = math.floor((today_secs - goal_secs) / 60)
    local streak_str  = streak > 0 and (" · " .. streak .. " day streak 🔥") or ""

    local goal_str
    if today_secs >= goal_secs then
        goal_str = above > 0
            and T(_("%1 min above goal"), above)
            or  _("Goal hit!")
    else
        local remaining = math.ceil((goal_secs - today_secs) / 60)
        goal_str = T(_("%1 min to goal"), remaining)
    end

    UIManager:show(InfoMessage:new{
        text    = T(_("Session complete\n\n%1 min read · %2%3"), mins, goal_str, streak_str),
        timeout = 5,
    })
end

-- ── Menu ──────────────────────────────────────────────────────────────────────

function ReadingVault:addToMainMenu(menu_items)
    menu_items.readingvault = {
        text = _("ReadingVault"),
        sub_item_table = {
            {
                text_func = function()
                    local goal = tonumber(self:getSetting("daily_goal", DEFAULT_DAILY_GOAL_SECS))
                    return T(_("Daily goal: %1 min"), math.floor(goal / 60))
                end,
                callback  = function() self:editDailyGoal() end,
                keep_menu_open = true,
            },
            {
                text_func = function()
                    local g = tonumber(self:getSetting("yearly_goal", DEFAULT_YEARLY_GOAL))
                    return T(_("Yearly goal: %1 books"), g)
                end,
                callback  = function() self:editYearlyGoal() end,
                keep_menu_open = true,
            },
            {
                text = _("Today's Stats"),
                callback = function()
                    local today = self:getTodaySeconds()
                    local goal  = tonumber(self:getSetting("daily_goal", DEFAULT_DAILY_GOAL_SECS))
                    local streak = self:getStreak()
                    local pct   = goal > 0 and math.floor(today / goal * 100) or 0
                    UIManager:show(InfoMessage:new{
                        text = T(_("Today: %1 min (%2%% of goal)\nStreak: %3 days"),
                            math.floor(today / 60), pct, streak),
                    })
                end,
            },
        },
    }
end

function ReadingVault:editDailyGoal()
    local current = math.floor(
        tonumber(self:getSetting("daily_goal", DEFAULT_DAILY_GOAL_SECS)) / 60
    )
    local dialog
    dialog = InputDialog:new{
        title       = _("Daily reading goal (minutes)"),
        input       = tostring(current),
        input_type  = "number",
        buttons     = {{
            {
                text     = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text     = _("Save"),
                is_enter_default = true,
                callback = function()
                    local v = tonumber(dialog:getInputText())
                    if v and v > 0 then
                        self:setSetting("daily_goal", v * 60)
                        UIManager:show(InfoMessage:new{
                            text = T(_("Daily goal set to %1 min."), v),
                            timeout = 2,
                        })
                    end
                    UIManager:close(dialog)
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

function ReadingVault:editYearlyGoal()
    local current = tonumber(self:getSetting("yearly_goal", DEFAULT_YEARLY_GOAL))
    local dialog
    dialog = InputDialog:new{
        title       = _("Yearly book goal"),
        input       = tostring(current),
        input_type  = "number",
        buttons     = {{
            {
                text     = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text     = _("Save"),
                is_enter_default = true,
                callback = function()
                    local v = tonumber(dialog:getInputText())
                    if v and v > 0 then
                        self:setSetting("yearly_goal", v)
                        UIManager:show(InfoMessage:new{
                            text = T(_("Yearly goal set to %1 books."), v),
                            timeout = 2,
                        })
                    end
                    UIManager:close(dialog)
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

return ReadingVault
