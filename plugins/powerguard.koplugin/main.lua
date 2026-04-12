--[[
PowerGuard — smart sleep profiles, brightness schedule, Clara BW battery tuning
Device codename: spaBWTPV
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local Device          = require("device")
local Screen          = require("device/screen")
local logger          = require("logger")
local _               = require("gettext")
local T               = require("ffi/util").template

-- ── Constants ─────────────────────────────────────────────────────────────────

local CODENAME = "Kobo_spaBW"  -- Kobo Clara BW (primary model string)

-- Sleep timeout presets (minutes → seconds)
local PROFILES = {
    reading = { name = "Reading",  timeout = 5  * 60 },
    manga   = { name = "Manga",    timeout = 10 * 60 },
    night   = { name = "Night",    timeout = 2  * 60 },
    off     = { name = "Never",    timeout = 0        },
}

-- Brightness schedule (hour → brightness 0–100)
local DEFAULT_SCHEDULE = {
    { hour = 6,  brightness = 60 },
    { hour = 9,  brightness = 80 },
    { hour = 20, brightness = 50 },
    { hour = 22, brightness = 30 },
}

-- ── Plugin class ──────────────────────────────────────────────────────────────

local PowerGuard = WidgetContainer:extend{
    name           = "powerguard",
    active_profile = "reading",
    schedule_on    = false,
    low_battery_mode = false,
}

function PowerGuard:init()
    self.is_clara_bw = Device.model == "Kobo_spaBW"
        or Device.model == "Kobo_spaBWTPV"
        or Device.model == "spaBWTPV"
        or (Device.model and Device.model:find("Clara") ~= nil)
    self.ui.menu:registerToMainMenu(self)

    -- Start brightness schedule check
    UIManager:scheduleIn(60, function() self:checkBrightnessSchedule() end)

    -- Apply saved profile immediately
    self:applyProfile(self.active_profile, true)
end

-- ── Device power API ──────────────────────────────────────────────────────────

function PowerGuard:setSleepTimeout(seconds)
    -- Persist in KOReader's global settings
    G_reader_settings:saveSetting("auto_standby_timeout", seconds)

    -- Also set via Device power management if available
    if Device.setAutoStandby then
        pcall(function() Device:setAutoStandby(seconds) end)
    elseif Device.powerd and Device.powerd.setAutoPowerOff then
        pcall(function() Device.powerd:setAutoPowerOff(seconds) end)
    end
end

function PowerGuard:setBrightness(pct)
    if not Device:hasLightLevels() then return end
    local powerd = Device.powerd
    if not powerd then return end
    pcall(function()
        powerd:setIntensity(pct)
    end)
end

function PowerGuard:setWarmth(pct)
    -- Clara BW does not have warmth LED — guard against crash
    if not Device:hasNaturalLight() then return end
    local powerd = Device.powerd
    if not powerd then return end
    pcall(function()
        powerd:setNaturalBrightness(pct)
    end)
end

function PowerGuard:getBatteryPct()
    if not Device.powerd then return 100 end
    local ok, pct = pcall(function() return Device.powerd:getCapacity() end)
    return ok and pct or 100
end

-- ── Profiles ──────────────────────────────────────────────────────────────────

function PowerGuard:applyProfile(profile_key, silent)
    local p = PROFILES[profile_key]
    if not p then return end

    self.active_profile = profile_key

    self:setSleepTimeout(p.timeout)

    -- Manga profile: disable warmth, boost contrast
    if profile_key == "manga" then
        self:setWarmth(0)
    end

    if not silent then
        UIManager:show(InfoMessage:new{
            text    = T(_("PowerGuard: %1 profile active"), p.name),
            timeout = 2,
        })
    end
    logger.dbg("PowerGuard: applied profile", profile_key, "timeout=", p.timeout)
end

-- Low battery mode (auto-enabled at 15%)
function PowerGuard:checkBattery()
    local pct = self:getBatteryPct()
    if pct <= 15 and not self.low_battery_mode then
        self.low_battery_mode = true
        -- Dim screen, shorten sleep timeout
        self:setBrightness(20)
        self:setSleepTimeout(60)  -- 1 minute
        UIManager:show(InfoMessage:new{
            text    = T(_("Battery at %1%%. Low battery mode enabled."), pct),
            timeout = 4,
        })
    elseif pct > 20 and self.low_battery_mode then
        self.low_battery_mode = false
        self:applyProfile(self.active_profile, true)
    end
end

-- ── Brightness schedule ───────────────────────────────────────────────────────

function PowerGuard:checkBrightnessSchedule()
    if not self.schedule_on then
        UIManager:scheduleIn(60, function() self:checkBrightnessSchedule() end)
        return
    end

    local hour = tonumber(os.date("%H"))
    local target = nil
    for i = #DEFAULT_SCHEDULE, 1, -1 do
        if hour >= DEFAULT_SCHEDULE[i].hour then
            target = DEFAULT_SCHEDULE[i].brightness
            break
        end
    end
    if target then self:setBrightness(target) end

    self:checkBattery()
    UIManager:scheduleIn(60, function() self:checkBrightnessSchedule() end)
end

-- ── Menu ──────────────────────────────────────────────────────────────────────

function PowerGuard:addToMainMenu(menu_items)
    menu_items.powerguard = {
        text = _("PowerGuard"),
        sub_item_table = {
            {
                text = _("Sleep Profiles"),
                sub_item_table = {
                    {
                        text_func = function()
                            return (self.active_profile == "reading" and "✓ " or "  ") .. _("Reading (5 min)")
                        end,
                        callback  = function() self:applyProfile("reading") end,
                        keep_menu_open = true,
                    },
                    {
                        text_func = function()
                            return (self.active_profile == "manga" and "✓ " or "  ") .. _("Manga (10 min)")
                        end,
                        callback  = function() self:applyProfile("manga") end,
                        keep_menu_open = true,
                    },
                    {
                        text_func = function()
                            return (self.active_profile == "night" and "✓ " or "  ") .. _("Night (2 min)")
                        end,
                        callback  = function() self:applyProfile("night") end,
                        keep_menu_open = true,
                    },
                    {
                        text_func = function()
                            return (self.active_profile == "off" and "✓ " or "  ") .. _("Never sleep")
                        end,
                        callback  = function() self:applyProfile("off") end,
                        keep_menu_open = true,
                    },
                },
            },
            {
                text_func = function()
                    return self.schedule_on
                        and _("Brightness Schedule: ON  ✓")
                        or  _("Brightness Schedule: off")
                end,
                callback = function()
                    self.schedule_on = not self.schedule_on
                    UIManager:show(InfoMessage:new{
                        text = self.schedule_on
                            and _("Brightness schedule enabled.")
                            or  _("Brightness schedule disabled."),
                        timeout = 2,
                    })
                end,
                keep_menu_open = true,
            },
            {
                text = _("Battery Status"),
                callback = function()
                    local pct = self:getBatteryPct()
                    UIManager:show(InfoMessage:new{
                        text = T(_("Battery: %1%%\nLow battery mode: %2"),
                            pct, self.low_battery_mode and _("ON") or _("off")),
                    })
                end,
            },
            {
                text_func = function()
                    return self.is_clara_bw
                        and _("Device: Clara BW ✓")
                        or  ("Device: " .. (Device.model or "unknown"))
                end,
                enabled_func = function() return false end,
            },
        },
    }
end

return PowerGuard
