--[[
InkFire — Shared State Manager
Lightweight pub/sub store for inter-module communication.
NO KOReader UI imports.

Usage:
  State.set("powerguard.profile", "manga")
  State.get("powerguard.profile")          -- returns "manga"
  State.subscribe("mangaflow.is_manga", function(val) ... end)
--]]

local logger = require("logger")

local State = {}

local _store       = {}   -- { [key] = value }
local _subscribers = {}   -- { [key] = { callback, ... } }

--- Set a value and notify all subscribers.
function State.set(key, value)
    _store[key] = value
    local subs = _subscribers[key]
    if subs then
        for _, cb in ipairs(subs) do
            local ok, err = pcall(cb, value)
            if not ok then
                logger.warn("State subscriber error for key", key, ":", err)
            end
        end
    end
end

--- Get the current value for a key (nil if unset).
function State.get(key)
    return _store[key]
end

--- Subscribe to changes for a key.
--- callback(new_value) is called immediately with the current value (if any),
--- then on every future State.set() for that key.
function State.subscribe(key, callback)
    if not _subscribers[key] then
        _subscribers[key] = {}
    end
    table.insert(_subscribers[key], callback)
    -- Fire immediately with current value if present
    if _store[key] ~= nil then
        local ok, err = pcall(callback, _store[key])
        if not ok then
            logger.warn("State subscribe immediate fire error for key", key, ":", err)
        end
    end
end

--- Remove all subscriptions for a key (useful on plugin teardown).
function State.unsubscribeAll(key)
    _subscribers[key] = nil
end

--- Reset all state (for testing).
function State.reset()
    _store       = {}
    _subscribers = {}
end

return State
