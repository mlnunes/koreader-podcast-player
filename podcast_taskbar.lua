local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local IconWidget = require("ui/widget/iconwidget")
local Screen = require("device").screen
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Font = require("ui/font")
local _ = require("gettext")

local source = debug.getinfo(1, "S").source
if source:sub(1, 1) == "@" then
    source = source:sub(2)
end
local plugin_dir = source:match("^(.*[/])") or ""

local BAR_HEIGHT = Screen:scaleBySize(92)
local ICON_SIZE = Screen:scaleBySize(34)
-- Font sizes are KOReader logical sizes; unlike icon dimensions, don't scale
-- them again with Screen:scaleBySize().
local LABEL_FONT_SIZE = 14
local CELL_BORDER = math.max(1, Size.border.button)

local Taskbar = InputContainer:extend{
    name = "podcast_taskbar",
    callbacks = nil,
}

local action_definitions = {
    { label = _("Add"), icon = "add_feed.svg" },
    { label = _("Refresh"), icon = "refresh_feeds.svg" },
    { label = _("Playback"), icon = "playback.svg" },
    { label = _("Diagnostics"), icon = "diagnostics.svg" },
}

function Taskbar:init()
    InputContainer._init(self)
    -- This is a touch-only control strip, not a separate Home-key target.
    self.key_events = {}

    local screen_width = Screen:getWidth()
    local inner_width = screen_width - 2 * CELL_BORDER * #action_definitions
    local cell_width = math.floor(inner_width / #action_definitions) + 2 * CELL_BORDER
    local inner_height = BAR_HEIGHT - 2 * CELL_BORDER
    local icon_size = math.min(ICON_SIZE, inner_height - Screen:scaleBySize(30))
    local row = HorizontalGroup:new{ align = "center" }

    for index, definition in ipairs(action_definitions) do
        local width = cell_width
        if index == #action_definitions then
            width = screen_width - (cell_width * (#action_definitions - 1))
        end
        local content_width = width - 2 * CELL_BORDER
        local content_height = inner_height
        local icon = IconWidget:new{
            file = plugin_dir .. "icons/" .. definition.icon,
            width = icon_size,
            height = icon_size,
        }
        local label = TextWidget:new{
            text = definition.label,
            face = Font:getFace("smallinfofont", LABEL_FONT_SIZE),
            bold = false,
            max_width = content_width - Screen:scaleBySize(8),
        }
        local content = VerticalGroup:new{
            align = "center",
            icon,
            VerticalSpan:new{},
            label,
        }
        local centered_content = CenterContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = content_width, h = content_height },
            content,
        }
        table.insert(row, FrameContainer:new{
            width = width,
            height = BAR_HEIGHT,
            bordersize = CELL_BORDER,
            padding = 0,
            margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            centered_content,
        })
    end

    self.dimen = Geom:new{ x = 0, y = 0, w = screen_width, h = BAR_HEIGHT }
    self[1] = row
    self.ges_events.TapTaskbar = {
        GestureRange:new{
            ges = "tap",
            range = function() return self.dimen end,
        },
    }
end

function Taskbar:getSize()
    return self.dimen
end

function Taskbar:onTapTaskbar(_, ges_ev)
    if not ges_ev or not ges_ev.pos or not self.callbacks then
        return true
    end

    local relative_x = ges_ev.pos.x - self.dimen.x
    local index = math.floor(relative_x * #action_definitions / self.dimen.w) + 1
    index = math.max(1, math.min(#action_definitions, index))
    local callback = self.callbacks[index]
    if callback then callback() end
    return true
end

return Taskbar
