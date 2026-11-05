local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local Menu = require("ui/widget/menu")
local Screen = require("device").screen
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Font = require("ui/font")
local UIManager = require("ui/uimanager")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local source = debug.getinfo(1, "S").source
if source:sub(1, 1) == "@" then source = source:sub(2) end
local plugin_dir = source:match("^(.*[/])") or ""
local PLACEHOLDER = plugin_dir .. "icons/podcast_placeholder.svg"

local COLUMN_COUNT = 4
local TITLE_FONT_SIZE = 14
local TITLE_HEIGHT = Screen:scaleBySize(42)
local ITEM_SPACING = Screen:scaleBySize(10)
local TITLE_SPACING = Screen:scaleBySize(5)

local GridMenuItem = InputContainer:extend{
    entry = nil,
    menu = nil,
    width = nil,
    height = nil,
    cover_size = nil,
    dimen = nil,
}

function GridMenuItem:init()
    self.ges_events = {
        TapSelect = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
        HoldSelect = {
            GestureRange:new{ ges = "hold", range = self.dimen },
        },
    }

    local border = Size.border.thin
    local cover
    if self.entry.artwork_path then
        cover = ImageWidget:new{
            file = self.entry.artwork_path,
            width = self.cover_size,
            height = self.cover_size,
            scale_factor = 0,
            crop_to_fit = true,
            -- Podcast artwork is transient and can be numerous. Avoid filling
            -- KOReader's small shared image cache with these thumbnails.
            file_do_cache = false,
        }
    else
        cover = IconWidget:new{
            file = PLACEHOLDER,
            width = self.cover_size,
            height = self.cover_size,
        }
    end

    local cover_frame = FrameContainer:new{
        width = self.cover_size + 2 * border,
        height = self.cover_size + 2 * border,
        bordersize = border,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        cover,
    }
    local title = TextBoxWidget:new{
        text = self.entry.text,
        face = Font:getFace("smallinfofont", TITLE_FONT_SIZE),
        width = self.width,
        height = TITLE_HEIGHT,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "center",
    }
    self.cover_frame = cover_frame
    self.title_widget = title
end

function GridMenuItem:getSize()
    return self.dimen
end

function GridMenuItem:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    local cover_size = self.cover_frame:getSize()
    local cover_x = x + math.floor((self.dimen.w - cover_size.w) / 2)
    self.cover_frame:paintTo(bb, cover_x, y)
    self.title_widget:paintTo(bb, x, y + cover_size.h + TITLE_SPACING)
end

function GridMenuItem:free(full)
    if self.cover_frame then
        self.cover_frame:free(full)
        self.cover_frame = nil
    end
    if self.title_widget then
        self.title_widget:free(full)
        self.title_widget = nil
    end
end

function GridMenuItem:onCloseWidget()
    self:free()
end

function GridMenuItem:onTapSelect()
    self.menu:onMenuSelect(self.entry)
    return true
end

function GridMenuItem:onHoldSelect(_, ges_ev)
    self.menu:onMenuHold(self.entry, ges_ev and ges_ev.pos)
    return true
end

local PodcastGridMenu = Menu:extend{
    name = "podcast_grid_menu",
}

function PodcastGridMenu:_recalculateDimen(no_recalculate_dimen)
    Menu._recalculateDimen(self, no_recalculate_dimen)
    if no_recalculate_dimen then return end

    self.nb_cols = COLUMN_COUNT
    self.item_margin = ITEM_SPACING
    self.item_width = math.floor(
        (self.inner_dimen.w - (COLUMN_COUNT + 1) * self.item_margin) / COLUMN_COUNT)

    local border = Size.border.thin
    local max_cover_size = self.item_width - 2 * border
    local cover_space = self.available_height - TITLE_HEIGHT - TITLE_SPACING
        - 2 * self.item_margin - 2 * border
    self.cover_size = math.max(1, math.min(max_cover_size, cover_space))
    self.item_height = self.cover_size + 2 * border + TITLE_SPACING + TITLE_HEIGHT

    self.nb_rows = math.max(1, math.floor(
        (self.available_height - self.item_margin) / (self.item_height + self.item_margin)))
    self.perpage = self.nb_cols * self.nb_rows
    self.page_num = math.max(1, math.ceil(#self.item_table / self.perpage))
    if self.page > self.page_num then self.page = self.page_num end
    self.item_dimen = Geom:new{ x = 0, y = 0, w = self.item_width, h = self.item_height }
end

function PodcastGridMenu:updateItems(select_number, no_recalculate_dimen)
    local old_dimen = self.dimen and self.dimen:copy()
    self.layout = {}
    self.item_group:clear()
    self.page_info:resetLayout()
    self.return_button:resetLayout()
    self.content_group:resetLayout()

    if not no_recalculate_dimen then
        self:_recalculateDimen()
    end

    if #self.item_table == 0 then
        local empty_message = TextBoxWidget:new{
            text = _("Nenhum podcast inscrito. Use Adicionar para começar."),
            face = Font:getFace("smallinfofont", 18),
            width = self.inner_dimen.w - 2 * self.item_margin,
            height = self.available_height,
            height_adjust = true,
            alignment = "center",
        }
        table.insert(self.item_group, CenterContainer:new{
            dimen = Geom:new{
                x = 0, y = 0, w = self.inner_dimen.w, h = self.available_height,
            },
            empty_message,
        })
    else
        local idx_offset = (self.page - 1) * self.perpage
        for row_idx = 1, self.nb_rows do
            local row = HorizontalGroup:new{}
            local line_layout = {}
            local row_item_count = math.min(
                self.nb_cols, #self.item_table - idx_offset - (row_idx - 1) * self.nb_cols)
            if row_item_count <= 0 then break end

            for col = 1, row_item_count do
                local local_index = (row_idx - 1) * self.nb_cols + col
                local index = idx_offset + local_index
                local item = self.item_table[index]
                item.idx = index

                local grid_item = GridMenuItem:new{
                    entry = item,
                    menu = self,
                    text = item.text,
                    width = self.item_width,
                    height = self.item_height,
                    cover_size = self.cover_size,
                    dimen = self.item_dimen:copy(),
                }
                table.insert(row, grid_item)
                table.insert(line_layout, grid_item)
                if col < row_item_count then
                    table.insert(row, HorizontalSpan:new{
                        width = self.item_margin,
                    })
                end
                if index == self.itemnumber then select_number = local_index end
            end

            table.insert(self.item_group, VerticalSpan:new{ width = self.item_margin })
            table.insert(self.item_group, CenterContainer:new{
                dimen = Geom:new{ x = 0, y = 0, w = self.inner_dimen.w, h = self.item_height },
                row,
            })
            table.insert(self.layout, line_layout)
        end
        table.insert(self.item_group, VerticalSpan:new{ width = self.item_margin })
    end

    self:updatePageInfo(select_number)
    if #self.item_table == 0 then
        self.page_info_text:setText(_("Nenhum podcast inscrito"))
    end
    self:mergeTitleBarIntoLayout()

    UIManager:setDirty(self.show_parent, function()
        local refresh_dimen = old_dimen and old_dimen:combine(self.dimen) or self.dimen
        return "ui", refresh_dimen
    end)
end

return PodcastGridMenu
