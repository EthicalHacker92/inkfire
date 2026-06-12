--[[
InkFire — library.lua
Full-screen paged cover grid with three lanes: All · Books · Manga.
Swipe west/east (or chevrons) to page; tap a cover to read.
Partial refresh per page turn — one flash only on entry.
--]]

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local IconButton      = require("ui/widget/iconbutton")
local IconWidget      = require("ui/widget/iconwidget")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local logger          = require("logger")
local _               = require("gettext")
local Screen          = Device.screen

local S    = require("plugins/inkfire.koplugin/style")
local Data = require("plugins/inkfire.koplugin/data")

local LANES = {
    { key = "all",   label = _("All")   },
    { key = "books", label = _("Books") },
    { key = "manga", label = _("Manga") },
}

local Library = InputContainer:extend{
    covers_fullscreen = true,
    on_open_file = nil,   -- function(filepath)
    lane  = "all",
    page  = 1,
}

function Library:init()
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    self._items = {}
    local ok, err = pcall(function()
        self._items = Data.library(self.lane)
        self:build()
    end)
    if not ok then
        logger.warn("InkFire Library build failed:", err)
    end
    self.ges_events = {
        SwipeNav = { GestureRange:new{ ges = "swipe", range = function() return self.dimen end } },
    }
end

function Library:perPage()
    return S.GRID_COLS * (self._rows or 2)
end

function Library:pageCount()
    return math.max(1, math.ceil(#self._items / self:perPage()))
end

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

local function gridCover(item, w, h)
    local bb = Data.cover(item.file)
    local img
    if bb then
        img = FrameContainer:new{
            bordersize = S.BORDER_HAIR(), color = S.GRAY_FAINT,
            radius = S.RADIUS_SMALL(), padding = 0,
            ImageWidget:new{
                image = bb, image_disposable = false,
                width = w, height = h, scale_factor = 0,
            },
        }
    else
        img = FrameContainer:new{
            background = S.INK, radius = S.RADIUS_SMALL(),
            bordersize = 0, padding = S.SPACE_S(),
            width = w, height = h,
            CenterContainer:new{
                dimen = Geom:new{ w = w - 2 * S.SPACE_S(), h = h - 2 * S.SPACE_S() },
                TextBoxWidget:new{
                    text = item.title, face = S.fontCaption(),
                    fgcolor = S.PAPER, bgcolor = S.INK,
                    width = w - 2 * S.SPACE_S(), alignment = "center",
                },
            },
        }
    end
    -- Finished badge
    if item.status == "complete" then
        img = OverlapGroup:new{
            dimen = Geom:new{ w = w, h = h },
            img,
            FrameContainer:new{
                bordersize = 0, padding = S.SPACE_XS(), margin = 0,
                overlap_align = "right",
                IconWidget:new{ icon = S.ICON_CHECK,
                    width = S.dp(20), height = S.dp(20) },
            },
        }
    end
    return img
end

function Library:build()
    local gut   = S.GUTTER()
    local w     = self.dimen.w
    local inner = w - 2 * gut

    local root = VerticalGroup:new{ align = "left" }
    local function add(x) root[#root + 1] = x end
    local function gap(px) add(VerticalSpan:new{ width = px }) end

    -- ── Header: title + lane tabs + close ──
    local tabs = HorizontalGroup:new{}
    for i, lane in ipairs(LANES) do
        local active = lane.key == self.lane
        local label = TextWidget:new{
            text = lane.label,
            face = S.fontBody(),
            bold = active,
            fgcolor = active and S.INK or S.GRAY_MUTED,
        }
        local cell = VerticalGroup:new{
            align = "left",
            label,
            VerticalSpan:new{ width = S.SPACE_XS() },
            FrameContainer:new{
                background = active and S.INK or S.PAPER,
                bordersize = 0, padding = 0, margin = 0,
                width = label:getSize().w, height = S.dp(3),
                HorizontalSpan:new{ width = label:getSize().w },
            },
        }
        local lane_key = lane.key
        tabs[#tabs + 1] = tappable(cell, label:getSize().w + S.SPACE_S(), cell:getSize().h,
            function() self:setLane(lane_key) end)
        if i < #LANES then tabs[#tabs + 1] = HorizontalSpan:new{ width = S.SPACE_L() } end
    end

    local close_btn = IconButton:new{
        icon = S.ICON_CLOSE, width = S.ICON_SIZE(), height = S.ICON_SIZE(),
        padding = S.SPACE_S(),
        callback = function() self:close() end,
    }
    add(OverlapGroup:new{
        dimen = Geom:new{ w = inner, h = math.max(tabs:getSize().h, close_btn:getSize().h) },
        LeftContainer:new{
            dimen = Geom:new{ w = inner, h = tabs:getSize().h },
            tabs,
        },
        FrameContainer:new{
            bordersize = 0, padding = 0, margin = 0,
            overlap_align = "right",
            close_btn,
        },
    })
    gap(S.SPACE_L())

    -- ── Grid (row count adapts to what actually fits the screen) ──
    local cols   = S.GRID_COLS
    local gap_x  = S.SPACE_M()
    local cell_w = math.floor((inner - gap_x * (cols - 1)) / cols)
    local cov_h  = math.floor(cell_w * 1.45)
    local label_h = S.dp(36)
    local cell_h = cov_h + S.SPACE_XS() + label_h

    -- Header ≈ already measured in root; reserve footer + breathing room.
    local chrome_h = root:getSize().h + S.dp(70) + 2 * gut
    local rows = math.max(1, math.floor(
        (self.dimen.h - chrome_h) / (cell_h + S.SPACE_M())))
    self._rows = rows
    if self.page > self:pageCount() then self.page = self:pageCount() end

    local start = (self.page - 1) * self:perPage()
    local grid = VerticalGroup:new{ align = "left" }
    local empty_lane = #self._items == 0

    if empty_lane then
        local msg = self.lane == "manga"
            and _("No manga yet. Drop .cbz files via Transfer and they land here.")
            or  _("Nothing here yet. Send books over with Transfer.")
        grid[1] = FrameContainer:new{
            background = S.GRAY_CARD, radius = S.RADIUS_CARD(),
            bordersize = 0, padding = S.SPACE_L(), width = inner,
            TextBoxWidget:new{ text = msg, face = S.fontBody(),
                width = inner - 2 * S.SPACE_L() },
        }
    else
        for r = 1, rows do
            local rowg = HorizontalGroup:new{ align = "top" }
            for c = 1, cols do
                local idx = start + (r - 1) * cols + c
                local item = self._items[idx]
                if item then
                    local label = TextBoxWidget:new{
                        text = item.title, face = S.fontCaption(),
                        fgcolor = S.GRAY_MUTED, width = cell_w,
                        height_max = label_h, height_overflow_show_ellipsis = true,
                    }
                    local cell = VerticalGroup:new{
                        align = "left",
                        gridCover(item, cell_w, cov_h),
                        VerticalSpan:new{ width = S.SPACE_XS() },
                        label,
                    }
                    local item_ref = item
                    rowg[#rowg + 1] = tappable(cell, cell_w, cell_h, function()
                        if self.on_open_file then self.on_open_file(item_ref.file) end
                    end)
                else
                    rowg[#rowg + 1] = HorizontalSpan:new{ width = cell_w }
                end
                if c < cols then rowg[#rowg + 1] = HorizontalSpan:new{ width = gap_x } end
            end
            grid[#grid + 1] = rowg
            if r < rows then grid[#grid + 1] = VerticalSpan:new{ width = S.SPACE_M() } end
        end
    end
    add(grid)

    -- ── Footer: pager ──
    local footer = HorizontalGroup:new{
        IconButton:new{
            icon = S.ICON_CHEV_L, width = S.ICON_SIZE(), height = S.ICON_SIZE(),
            padding = S.SPACE_M(), enabled = self.page > 1,
            callback = function() self:turnPage(-1) end,
        },
        HorizontalSpan:new{ width = S.SPACE_M() },
        TextWidget:new{
            text = empty_lane and "" or
                ("%d / %d"):format(self.page, self:pageCount()),
            face = S.fontCaption(), fgcolor = S.GRAY_MUTED,
        },
        HorizontalSpan:new{ width = S.SPACE_M() },
        IconButton:new{
            icon = S.ICON_CHEV_R, width = S.ICON_SIZE(), height = S.ICON_SIZE(),
            padding = S.SPACE_M(), enabled = self.page < self:pageCount(),
            callback = function() self:turnPage(1) end,
        },
    }
    local used = root:getSize().h
    local remaining = self.dimen.h - used - footer:getSize().h - 2 * gut
    gap(math.max(S.SPACE_S(), remaining))
    add(CenterContainer:new{
        dimen = Geom:new{ w = inner, h = footer:getSize().h },
        footer,
    })

    self[1] = FrameContainer:new{
        background = S.PAPER,
        bordersize = 0, margin = 0, padding = gut,
        width = self.dimen.w, height = self.dimen.h,
        root,
    }
end

function Library:rebuild(refreshtype)
    local ok, err = pcall(function() self:build() end)
    if not ok then logger.warn("InkFire Library rebuild failed:", err); return end
    UIManager:setDirty(self, refreshtype or "partial")
end

function Library:setLane(lane)
    if lane == self.lane then return end
    self.lane = lane
    self.page = 1
    local ok, items = pcall(Data.library, lane)
    self._items = ok and items or {}
    self:rebuild("partial")
end

function Library:turnPage(dir)
    local target = self.page + dir
    if target < 1 or target > self:pageCount() then return end
    self.page = target
    self:rebuild("partial")
end

function Library:onSwipeNav(_, ges)
    if ges.direction == "west" then
        self:turnPage(1)
    elseif ges.direction == "east" then
        self:turnPage(-1)
    elseif ges.direction == "south" then
        self:close()
    end
    return true
end

function Library:onShow()
    UIManager:setDirty(self, function() return "flashui", self.dimen end)
    return true
end

function Library:close()
    UIManager:close(self, "flashpartial")
end

return Library
