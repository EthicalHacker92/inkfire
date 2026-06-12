--[[
InkFire — style.lua
Design tokens for the Hearth UI. Pure data + tiny helpers; no UIManager.

Spacing uses an 8dp grid (scaled for DPI). Type ramp uses KOReader's
shipped Noto faces. Icons are KOReader's mdlight SVG set — never emoji
(emoji rasterize as mud on grayscale e-ink).
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Font       = require("ui/font")
local Screen     = require("device").screen

local S = {}

-- ── Spacing (8dp grid) ────────────────────────────────────────────────────────
local _scale = {}
function S.dp(n)
    if _scale[n] == nil then _scale[n] = Screen:scaleBySize(n) end
    return _scale[n]
end

S.SPACE_XS  = function() return S.dp(4)  end
S.SPACE_S   = function() return S.dp(8)  end
S.SPACE_M   = function() return S.dp(16) end
S.SPACE_L   = function() return S.dp(24) end
S.SPACE_XL  = function() return S.dp(32) end

-- Screen margins: generous gutters make e-ink pages feel like book pages.
S.GUTTER    = function() return S.dp(20) end

-- ── Shape ─────────────────────────────────────────────────────────────────────
S.RADIUS_CARD   = function() return S.dp(14) end
S.RADIUS_SMALL  = function() return S.dp(8)  end
S.BORDER_HAIR   = function() return S.dp(1)  end
S.BORDER_CARD   = function() return S.dp(2)  end
S.PROGRESS_H    = function() return S.dp(5)  end

-- ── Color (16-level gray on e-ink) ────────────────────────────────────────────
S.INK        = Blitbuffer.COLOR_BLACK
S.PAPER      = Blitbuffer.COLOR_WHITE
S.GRAY_MUTED = Blitbuffer.COLOR_GRAY_6   -- secondary text
S.GRAY_FAINT = Blitbuffer.COLOR_GRAY_B   -- hairlines, empty progress track
S.GRAY_CARD  = Blitbuffer.COLOR_GRAY_E   -- subtle card fill

-- ── Type ramp ─────────────────────────────────────────────────────────────────
-- name → face getter. Sizes tuned for 300dpi 6" screen.
function S.fontGreeting()  return Font:getFace("tfont", 26)          end -- "Good evening."
function S.fontTitle()     return Font:getFace("tfont", 20)          end -- book titles
function S.fontBody()      return Font:getFace("cfont", 15)          end -- authors, labels
function S.fontEyebrow()   return Font:getFace("smallinfofontbold", 12) end -- "CONTINUE"
function S.fontCaption()   return Font:getFace("cfont", 12)          end -- captions, footers
function S.fontStatBig()   return Font:getFace("tfont", 34)          end -- streak number
function S.fontButton()    return Font:getFace("cfont", 16)          end

-- ── Icons (mdlight set, shipped with KOReader) ────────────────────────────────
S.ICON_SETTINGS = "appbar.settings"
S.ICON_CLOSE    = "close"
S.ICON_HOME     = "home"
S.ICON_BOOK     = "book.opened"
S.ICON_WIFI     = "wifi"
S.ICON_STAR     = "star.full"
S.ICON_CHEV_L   = "chevron.left"
S.ICON_CHEV_R   = "chevron.right"
S.ICON_CHECK    = "check"
S.ICON_INFO     = "info"
S.ICON_SIZE     = function() return S.dp(28) end

-- ── Layout constants ──────────────────────────────────────────────────────────
S.HERO_COVER_W  = function() return S.dp(110) end
S.HERO_COVER_H  = function() return S.dp(160) end
S.NEXT_COVER_W  = function() return S.dp(88)  end
S.NEXT_COVER_H  = function() return S.dp(128) end
S.GRID_COLS     = 3
S.GRID_ROWS     = 3

-- ── Greeting ──────────────────────────────────────────────────────────────────
function S.greeting(hour)
    hour = hour or tonumber(os.date("%H"))
    if hour < 5  then return "Up late." end
    if hour < 12 then return "Good morning." end
    if hour < 18 then return "Good afternoon." end
    return "Good evening."
end

function S.dateline()
    return os.date("%A, %B %d")
end

return S
