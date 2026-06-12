--[[
InkFire — home.lua
The Hearth: a warm, quiet, full-screen home for your reading life.

One deliberate flash on entry, stillness after. Swipe down → stock
KOReader file manager. Swipe up → Library. Every card is one tap from
reading. Renders entirely from a Data.hearthSnapshot() taken at show().
--]]

local Blitbuffer      = require("ffi/blitbuffer")
local Button          = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local IconButton      = require("ui/widget/iconbutton")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local logger          = require("logger")
local _               = require("gettext")
local Screen          = Device.screen

local S    = require("style")
local Data = require("data")

-- ── Tiny builders ─────────────────────────────────────────────────────────────

local function eyebrow(text)
    return TextWidget:new{
        text = text:upper(),
        face = S.fontEyebrow(),
        fgcolor = S.GRAY_MUTED,
    }
end

--- A cover image, or a deliberate typographic placeholder (rounded dark
--- card with the title set small) — never a broken-image look.
local function coverWidget(book, w, h)
    local bb = book and Data.cover(book.file)
    if bb then
        return FrameContainer:new{
            bordersize = S.BORDER_HAIR(),
            color      = S.GRAY_FAINT,
            radius     = S.RADIUS_SMALL(),
            padding    = 0,
            ImageWidget:new{
                image = bb,
                image_disposable = false,   -- the Data cover cache owns it
                width = w, height = h,
                scale_factor = 0,           -- best-fit, keep aspect
            },
        }
    end
    return FrameContainer:new{
        background = S.INK,
        radius     = S.RADIUS_SMALL(),
        bordersize = 0,
        padding    = S.SPACE_S(),
        width      = w,
        height     = h,
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2 * S.SPACE_S(), h = h - 2 * S.SPACE_S() },
            TextBoxWidget:new{
                text      = book and book.title or "",
                face      = S.fontCaption(),
                fgcolor   = S.PAPER,
                bgcolor   = S.INK,
                width     = w - 2 * S.SPACE_S(),
                alignment = "center",
            },
        },
    }
end

--- Thin rounded progress bar.
local function progressBar(pct, width)
    local h = S.PROGRESS_H()
    local fill_w = math.max(0, math.min(width, math.floor(width * (pct or 0))))
    local track = FrameContainer:new{
        background = S.GRAY_FAINT,
        radius     = math.floor(h / 2),
        bordersize = 0, padding = 0, margin = 0,
        width      = width, height = h,
        HorizontalGroup:new{
            FrameContainer:new{
                background = S.INK,
                radius     = math.floor(h / 2),
                bordersize = 0, padding = 0, margin = 0,
                width      = fill_w, height = h,
                HorizontalSpan:new{ width = fill_w },
            },
        },
    }
    return track
end

--- A tappable region wrapping any widget.
local function tappable(widget, w, h, on_tap)
    local t = InputContainer:new{ dimen = Geom:new{ w = w, h = h } }
    t[1] = widget
    t.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = function() return t.dimen end } },
    }
    t.onTap = function()
        if on_tap then on_tap() end
        return true
    end
    return t
end

-- ── The Hearth ────────────────────────────────────────────────────────────────

local Hearth = InputContainer:extend{
    covers_fullscreen = true,
    -- callbacks injected by main.lua:
    on_open_file    = nil,  -- function(filepath)
    on_open_library = nil,  -- function()
    on_open_transfer= nil,  -- function()
    on_open_settings= nil,  -- function()
    on_set_goal     = nil,  -- function()  (shows goal input dialog)
}

function Hearth:init()
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }

    local ok, err = pcall(function() self:build() end)
    if not ok then
        logger.warn("InkFire Hearth build failed:", err)
        self[1] = FrameContainer:new{
            background = S.PAPER, bordersize = 0,
            width = self.dimen.w, height = self.dimen.h,
            CenterContainer:new{
                dimen = self.dimen:copy(),
                TextWidget:new{ text = _("InkFire could not load. Swipe down."),
                                face = S.fontBody() },
            },
        }
    end

    self.ges_events = {
        SwipeNav = { GestureRange:new{ ges = "swipe", range = function() return self.dimen end } },
    }
end

function Hearth:build()
    local snap   = Data.hearthSnapshot()
    self._snap   = snap
    local gut    = S.GUTTER()
    local w      = self.dimen.w
    local inner  = w - 2 * gut

    local page = VerticalGroup:new{ align = "left" }
    local function add(widget) page[#page + 1] = widget end
    local function gap(px) add(VerticalSpan:new{ width = px }) end

    -- ── Header: greeting + icons ──
    local greeting = VerticalGroup:new{
        align = "left",
        TextWidget:new{ text = S.greeting(), face = S.fontGreeting() },
        VerticalSpan:new{ width = S.SPACE_XS() },
        TextWidget:new{ text = S.dateline(), face = S.fontCaption(), fgcolor = S.GRAY_MUTED },
    }
    local icons = HorizontalGroup:new{
        IconButton:new{
            icon = S.ICON_SETTINGS, width = S.ICON_SIZE(), height = S.ICON_SIZE(),
            padding = S.SPACE_S(),
            callback = function() if self.on_open_settings then self.on_open_settings() end end,
        },
        HorizontalSpan:new{ width = S.SPACE_S() },
        IconButton:new{
            icon = S.ICON_CLOSE, width = S.ICON_SIZE(), height = S.ICON_SIZE(),
            padding = S.SPACE_S(),
            callback = function() self:close() end,
        },
    }
    local icons_size = icons:getSize()
    add(OverlapGroup:new{
        dimen = Geom:new{ w = inner, h = math.max(greeting:getSize().h, icons_size.h) },
        LeftContainer:new{
            dimen = Geom:new{ w = inner, h = greeting:getSize().h },
            greeting,
        },
        FrameContainer:new{
            bordersize = 0, padding = 0, margin = 0,
            overlap_align = "right",
            icons,
        },
    })
    gap(S.SPACE_L())

    -- ── Continue card ──
    local cb = snap.continue_book
    add(eyebrow(cb and _("Continue") or _("Begin")))
    gap(S.SPACE_S())

    if cb then
        local cover_w, cover_h = S.HERO_COVER_W(), S.HERO_COVER_H()
        local pad    = S.SPACE_M()
        local text_w = inner - cover_w - pad * 3

        local title_w = TextBoxWidget:new{
            text = cb.title, face = S.fontTitle(),
            width = text_w, height_max = S.dp(58), height_overflow_show_ellipsis = true,
        }
        local right_col = VerticalGroup:new{
            align = "left",
            title_w,
            VerticalSpan:new{ width = S.SPACE_XS() },
            TextWidget:new{
                text = cb.authors ~= "" and cb.authors or (cb.is_manga and _("Manga") or ""),
                face = S.fontBody(), fgcolor = S.GRAY_MUTED,
                max_width = text_w,
            },
            VerticalSpan:new{ width = S.SPACE_M() },
            progressBar(cb.pct, text_w),
            VerticalSpan:new{ width = S.SPACE_S() },
            TextWidget:new{
                text = cb.time_left
                    and ("%d%%  ·  %s"):format(math.floor(cb.pct * 100), cb.time_left)
                    or  ("%d%%"):format(math.floor(cb.pct * 100)),
                face = S.fontCaption(), fgcolor = S.GRAY_MUTED,
            },
        }

        local hero_inner = HorizontalGroup:new{
            coverWidget(cb, cover_w, cover_h),
            HorizontalSpan:new{ width = pad },
            right_col,
        }
        local hero = FrameContainer:new{
            background = S.PAPER,
            bordersize = S.BORDER_CARD(),
            color      = S.INK,
            radius     = S.RADIUS_CARD(),
            padding    = pad,
            width      = inner,
            hero_inner,
        }
        add(tappable(hero, inner, hero:getSize().h, function()
            if self.on_open_file then self.on_open_file(cb.file) end
        end))
    else
        -- Empty state: no history yet. Keep it warm, point at the library.
        local empty = FrameContainer:new{
            background = S.GRAY_CARD,
            bordersize = 0,
            radius     = S.RADIUS_CARD(),
            padding    = S.SPACE_L(),
            width      = inner,
            TextBoxWidget:new{
                text  = _("Your next story is waiting.\nOpen the Library to pick your first book."),
                face  = S.fontBody(),
                width = inner - 2 * S.SPACE_L(),
            },
        }
        add(tappable(empty, inner, empty:getSize().h, function()
            if self.on_open_library then self.on_open_library() end
        end))
    end
    gap(S.SPACE_L())

    -- ── Up next rail ──
    if #snap.up_next > 0 then
        add(eyebrow(_("Up next")))
        gap(S.SPACE_S())
        local cw, ch = S.NEXT_COVER_W(), S.NEXT_COVER_H()
        local rail_gap = math.max(S.SPACE_M(),
            math.floor((inner - cw * #snap.up_next) / math.max(1, #snap.up_next)))
        local rail = HorizontalGroup:new{ align = "top" }
        for i, b in ipairs(snap.up_next) do
            local label = TextBoxWidget:new{
                text = b.title, face = S.fontCaption(), fgcolor = S.GRAY_MUTED,
                width = cw + S.SPACE_M(), alignment = "left",
                height_max = S.dp(34), height_overflow_show_ellipsis = true,
            }
            local cell = VerticalGroup:new{
                align = "left",
                coverWidget(b, cw, ch),
                VerticalSpan:new{ width = S.SPACE_XS() },
                label,
            }
            local b_ref = b
            rail[#rail + 1] = tappable(cell, cw + S.SPACE_M(), cell:getSize().h, function()
                if self.on_open_file then self.on_open_file(b_ref.file) end
            end)
            if i < #snap.up_next then
                rail[#rail + 1] = HorizontalSpan:new{ width = rail_gap - S.SPACE_M() }
            end
        end
        add(rail)
        gap(S.SPACE_L())
    end

    -- ── Quiet stats line ──
    local stat_text
    if snap.streak > 0 then
        stat_text = ("⚑ %d-day streak  ·  %d min today"):format(snap.streak, snap.minutes_today)
    elseif snap.minutes_today > 0 then
        stat_text = ("%d min today  ·  goal %d"):format(snap.minutes_today, snap.goal_minutes)
    else
        stat_text = ("A few pages tonight starts the streak.")
    end
    local stat_w = TextWidget:new{ text = stat_text, face = S.fontBody(), fgcolor = S.GRAY_MUTED }
    add(tappable(stat_w, inner, stat_w:getSize().h + S.SPACE_S(), function()
        self:showStatsCard()
    end))

    -- ── Bottom buttons, pinned via spacer math ──
    local btn_h = S.dp(52)
    local btn_w = math.floor((inner - S.SPACE_M()) / 2)
    local buttons = HorizontalGroup:new{
        Button:new{
            text = _("Library"),
            width = btn_w, height = btn_h,
            radius = S.RADIUS_CARD(),
            bordersize = S.BORDER_HAIR(),
            text_font_face = "cfont", text_font_size = 16, text_font_bold = false,
            callback = function() if self.on_open_library then self.on_open_library() end end,
        },
        HorizontalSpan:new{ width = S.SPACE_M() },
        Button:new{
            text = _("Transfer"),
            width = btn_w, height = btn_h,
            radius = S.RADIUS_CARD(),
            bordersize = S.BORDER_HAIR(),
            text_font_face = "cfont", text_font_size = 16, text_font_bold = false,
            callback = function() if self.on_open_transfer then self.on_open_transfer() end end,
        },
    }

    local used = page:getSize().h
    local remaining = self.dimen.h - used - btn_h - 2 * gut
    gap(math.max(S.SPACE_M(), remaining))
    add(buttons)

    self[1] = FrameContainer:new{
        background = S.PAPER,
        bordersize = 0, margin = 0,
        padding = gut,
        width  = self.dimen.w,
        height = self.dimen.h,
        page,
    }
end

-- ── Stats card overlay ────────────────────────────────────────────────────────

function Hearth:showStatsCard()
    local st = Data.statsSnapshot()
    local gut = S.GUTTER()
    local card_w = self.dimen.w - 4 * gut
    local inner_w = card_w - 2 * S.SPACE_L()

    local goal_pct = st.goal_minutes > 0
        and math.min(100, math.floor(st.minutes_today / st.goal_minutes * 100)) or 0

    local rows = VerticalGroup:new{
        align = "left",
        TextWidget:new{ text = tostring(st.streak), face = S.fontStatBig() },
        TextWidget:new{
            text = st.streak == 1 and _("day streak") or _("day streak"),
            face = S.fontCaption(), fgcolor = S.GRAY_MUTED },
        VerticalSpan:new{ width = S.SPACE_M() },
        TextWidget:new{
            text = ("%d of %d min today  (%d%%)"):format(
                st.minutes_today, st.goal_minutes, goal_pct),
            face = S.fontBody() },
        VerticalSpan:new{ width = S.SPACE_S() },
        progressBar(goal_pct / 100, inner_w),
        VerticalSpan:new{ width = S.SPACE_M() },
        TextWidget:new{
            text = ("%d min this week  ·  %d books finished"):format(
                st.minutes_week, st.books_finished),
            face = S.fontBody(), fgcolor = S.GRAY_MUTED },
        VerticalSpan:new{ width = S.SPACE_L() },
    }

    local card
    local buttons = HorizontalGroup:new{
        Button:new{
            text = _("Set daily goal"),
            radius = S.RADIUS_SMALL(), bordersize = S.BORDER_HAIR(),
            text_font_size = 14, text_font_bold = false,
            callback = function()
                UIManager:close(card)
                if self.on_set_goal then self.on_set_goal() end
            end,
        },
        HorizontalSpan:new{ width = S.SPACE_M() },
        Button:new{
            text = _("Close"),
            radius = S.RADIUS_SMALL(), bordersize = S.BORDER_HAIR(),
            text_font_size = 14, text_font_bold = false,
            callback = function() UIManager:close(card) end,
        },
    }
    rows[#rows + 1] = buttons

    card = FrameContainer:new{
        background = S.PAPER,
        bordersize = S.BORDER_CARD(),
        color      = S.INK,
        radius     = S.RADIUS_CARD(),
        padding    = S.SPACE_L(),
        width      = card_w,
        rows,
    }
    local centered = CenterContainer:new{
        dimen = self.dimen:copy(),
        card,
    }
    centered.covers_fullscreen = false
    UIManager:show(centered)
    UIManager:setDirty(centered, "ui")
end

-- ── Lifecycle / gestures ──────────────────────────────────────────────────────

function Hearth:onShow()
    UIManager:setDirty(self, function() return "flashui", self.dimen end)
    return true
end

function Hearth:refresh()
    -- Re-snapshot and rebuild in place (e.g., after closing a book).
    local ok = pcall(function() self:build() end)
    if ok then UIManager:setDirty(self, "partial") end
end

function Hearth:close()
    UIManager:close(self, "flashpartial")
end

function Hearth:onSwipeNav(_, ges)
    if ges.direction == "south" then
        self:close()                      -- reveal stock KOReader
    elseif ges.direction == "north" then
        if self.on_open_library then self.on_open_library() end
    end
    return true
end

function Hearth:onClose()
    return true
end

return Hearth
