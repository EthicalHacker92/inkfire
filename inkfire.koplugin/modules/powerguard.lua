--[[
InkFire — PowerGuard Module
Pure logic layer: sleep profiles, brightness schedule, battery monitoring.
NO KOReader UI imports.

State keys published:
  - powerguard.profile         string (active profile key)
  - powerguard.schedule_on     boolean
  - powerguard.low_battery_mode boolean
--]]

local logger = require("logger")

local State = require("plugins/inkfire.koplugin/modules/state")

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

-- ── Internal state ────────────────────────────────────────────────────────────

local _active_profile    = "reading"
local _schedule_on       = false
local _low_battery_mode  = false
local _is_clara_bw       = nil   -- detected once on first call

-- ── Device detection ──────────────────────────────────────────────────────────

local function detectClaraBW()
    if _is_clara_bw ~= nil then return _is_clara_bw end
    local ok, Device = pcall(require, "device")
    if not ok or not Device then
        _is_clara_bw = false
        return false
    end
    local model = Device.model or ""
    _is_clara_bw = (model == "Kobo_spaBW")
        or (model == "Kobo_spaBWTPV")
        or (model == "spaBWTPV")
        or (model:find("Clara") ~= nil)
    return _is_clara_bw
end

-- ── Device power helpers (called with pcall from main.lua context) ────────────

local function setSleepTimeout(seconds)
    G_reader_settings:saveSetting("auto_standby_timeout", seconds)
    local ok, Device = pcall(require, "device")
    if not ok or not Device then return end
    if Device.setAutoStandby then
        pcall(function() Device:setAutoStandby(seconds) end)
    elseif Device.powerd and Device.powerd.setAutoPowerOff then
        pcall(function() Device.powerd:setAutoPowerOff(seconds) end)
    end
end

local function setBrightness(pct)
    local ok, Device = pcall(require, "device")
    if not ok or not Device then return end
    if not Device:hasLightLevels() then return end
    local powerd = Device.powerd
    if not powerd then return end
    pcall(function() powerd:setIntensity(pct) end)
end

local function getBatteryPct()
    local ok, Device = pcall(require, "device")
    if not ok or not Device or not Device.powerd then return 100 end
    local ok2, pct = pcall(function() return Device.powerd:getCapacity() end)
    return ok2 and pct or 100
end

-- ── Public API ────────────────────────────────────────────────────────────────

local PowerGuard = {}

--- Returns info about device compatibility.
function PowerGuard.getDeviceInfo()
    return {
        is_clara_bw = detectClaraBW(),
        model       = (function()
            local ok, Device = pcall(require, "device")
            return ok and Device and Device.model or "unknown"
        end)(),
    }
end

--- Apply a named profile. Returns { name, timeout } or nil on error.
function PowerGuard.applyProfile(profile_key)
    local p = PROFILES[profile_key]
    if not p then
        logger.warn("PowerGuard: unknown profile:", profile_key)
        return nil
    end
    _active_profile = profile_key
    State.set("powerguard.profile", profile_key)

    pcall(setSleepTimeout, p.timeout)

    if profile_key == "manga" then
        -- Disable warmth for manga (Clara BW doesn't have it, but guard anyway)
        local ok, Device = pcall(require, "device")
        if ok and Device and Device:hasNaturalLight() and Device.powerd then
            pcall(function() Device.powerd:setNaturalBrightness(0) end)
        end
    end

    logger.dbg("PowerGuard: applied profile", profile_key, "timeout=", p.timeout)
    return { name = p.name, timeout = p.timeout, key = profile_key }
end

--- Toggle brightness schedule. Returns new boolean state.
function PowerGuard.toggleSchedule()
    _schedule_on = not _schedule_on
    State.set("powerguard.schedule_on", _schedule_on)
    logger.dbg("PowerGuard: schedule", _schedule_on and "ON" or "OFF")
    return _schedule_on
end

--- Get battery info. Returns { pct, low_mode }.
function PowerGuard.getBatteryInfo()
    local pct = getBatteryPct()
    return { pct = pct, low_mode = _low_battery_mode }
end

--- Check battery and enter/exit low-battery mode.
--- Returns action taken: "enter_low", "exit_low", or nil.
function PowerGuard.checkBattery()
    local pct = getBatteryPct()
    if pct <= 15 and not _low_battery_mode then
        _low_battery_mode = true
        State.set("powerguard.low_battery_mode", true)
        pcall(setBrightness, 20)
        pcall(setSleepTimeout, 60)
        logger.dbg("PowerGuard: low battery mode ON at", pct .. "%")
        return "enter_low", pct
    elseif pct > 20 and _low_battery_mode then
        _low_battery_mode = false
        State.set("powerguard.low_battery_mode", false)
        PowerGuard.applyProfile(_active_profile)
        logger.dbg("PowerGuard: low battery mode OFF at", pct .. "%")
        return "exit_low", pct
    end
    return nil, pct
end

--- Check brightness schedule and apply if needed.
--- Returns target brightness (or nil if schedule off / no rule).
function PowerGuard.checkBrightnessSchedule()
    if not _schedule_on then return nil end

    local hour   = tonumber(os.date("%H"))
    local target = nil
    for i = #DEFAULT_SCHEDULE, 1, -1 do
        if hour >= DEFAULT_SCHEDULE[i].hour then
            target = DEFAULT_SCHEDULE[i].brightness
            break
        end
    end
    if target then
        pcall(setBrightness, target)
    end

    -- Also run battery check on every schedule tick
    PowerGuard.checkBattery()

    return target
end

--- Get active profile key.
function PowerGuard.getActiveProfile()
    return _active_profile
end

--- Returns PROFILES table (read-only reference).
function PowerGuard.getProfiles()
    return PROFILES
end

-- Subscribe to MangaFlow manga state to auto-switch profile
State.subscribe("mangaflow.is_manga", function(is_manga)
    if is_manga and _active_profile ~= "manga" then
        PowerGuard.applyProfile("manga")
        logger.dbg("PowerGuard: auto-switched to manga profile")
    elseif not is_manga and _active_profile == "manga" then
        PowerGuard.applyProfile("reading")
        logger.dbg("PowerGuard: auto-reverted to reading profile")
    end
end)

return PowerGuard
