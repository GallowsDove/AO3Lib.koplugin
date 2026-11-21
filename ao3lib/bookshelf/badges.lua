-- AO3's four-square work symbols, supplied through Bookshelf's missing-cover
-- API. Identity and metadata come from the EPUB, never download history.
local M = {}
local render_context
local source = debug.getinfo(1, "S").source
local asset_dir = source:sub(1, 1) == "@" and
    source:sub(2):match("^(.*[/\\])") or "./"
asset_dir = (asset_dir or "./") .. "../../assets/"

-- Use the same selection in Bookshelf's covers and the formatted work view.
local styles={original='ao3-icons/',eink='ao3-icons-eink/',
    zerafina='ao3-icons-zerafina/',zerafina_eink='ao3-icons-zerafina-eink/'}
function M.style()
    local Config=require('ao3lib.core.config')
    local style=Config:readSetting('ao3_symbol_style')
    if style=='zerafina_bw' then return 'zerafina_eink' end
    if styles[style] then return style end
    -- Keep the previous choice until a style is explicitly selected.
    return Config:readSetting('ao3_eink_symbols',false) and 'eink' or 'original'
end
function M.relativePath(icon)
    return styles[M.style()]..icon..'.png'
end

function M.assetPath(icon)
    return asset_dir .. M.relativePath(icon)
end

function M.refresh()
    -- Rebuild only the existing Bookshelf widget; no metadata rescan or
    -- changes to Bookshelf itself are needed to replace its cover widgets.
    local module = package.loaded["lib/bookshelf_widget"]
    local widget = module and module.live
    local UI = require("ui/uimanager")
    if widget and widget._rebuild and UI.isWidgetShown and UI:isWidgetShown(widget) then
        widget:_rebuild()
        UI:setDirty(widget, "ui")
    end
end

local ratings = {
    ["general audiences"] = "rating-general-audience",
    ["teen and up audiences"] = "rating-teen",
    mature = "rating-mature", explicit = "rating-explicit",
    ["not rated"] = "rating-notrated",
}
local categories = {
    ["f/m"] = "category-het", ["m/f"] = "category-het",
    ["m/m"] = "category-slash", ["f/f"] = "category-femslash",
    gen = "category-gen", multi = "category-multi", other = "category-other",
}
local function normalized(value)
    return type(value) == "string" and value:match("^%s*(.-)%s*$"):lower() or ""
end

-- In AO3 order: rating, category, archive warnings, completion. False means
-- unknown: leave that square empty rather than claiming there are no warnings
-- or that a work is complete. Explicit warnings take priority over opt-out.
function M.symbols(data)
    local rating = ratings[normalized((data.ao3_ratings or {})[1])] or "rating-notrated"
    local category, seen = nil, {}
    for _, value in ipairs(data.ao3_categories or {}) do
        local icon = categories[normalized(value)]
        if icon and not seen[icon] then
            if category then category = "category-multi" else category = icon end
            seen[icon] = true
        end
    end
    local warning, priority = false, 0
    for _, value in ipairs(data.ao3_warnings or {}) do
        local name = normalized(value)
        local icon, rank
        if name == "no archive warnings apply" then
            icon, rank = "warning-no", 1
        elseif name == "external work" then
            icon, rank = "warning-external-work", 2
        elseif name == "creator chose not to use archive warnings"
            or name == "choose not to use archive warnings" then
            icon, rank = "warning-choosenotto", 3
        elseif name ~= "" then
            icon, rank = "warning-yes", 4
        end
        if rank and rank > priority then warning, priority = icon, rank end
    end
    local status = (data.ao3_completion or {})[1]
    local completion = status == "complete" and "complete-yes"
        or status == "in_progress" and "complete-no" or false
    return {rating, category or "category-none", warning, completion}
end

function M.provider(book, w, h, ctx)
    if render_context and render_context.spine then return nil end
    if type(book) ~= "table" or type(book.filepath) ~= "string"
        or not book.filepath:lower():match("%.epub$") then return nil end
    if type(w) ~= "number" or type(h) ~= "number" or w < 16 or h < 16 then return nil end
    local data = require("ao3lib.bookshelf.metadata").get(book.filepath, false)
    if not data then return nil end
    ctx = ctx or {}
    local Screen = require("device").screen
    local gap = math.max(1, Screen:scaleBySize(2))
    -- The hero is top-anchored; give only that view a little breathing room.
    local top = ctx.panel and math.min(Screen:scaleBySize(16), math.max(0, h - 16)) or 0
    local target = Screen:scaleBySize(ctx.panel and 40 or ctx.bare and 28 or 50)
    local side = math.floor(math.min(target, (math.min(w, h - top) - gap) / 2))
    if side < 7 then return nil end
    local ImageWidget = require("ui/widget/imagewidget")
    local Widget = require("ui/widget/widget")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalSpan = require("ui/widget/verticalspan")
    local cells = {}
    for i, icon in ipairs(M.symbols(data)) do
        if icon then
            -- ImageWidget's bounded shared file cache owns the decoded images;
            -- each row can be freed without invalidating another row's icons.
            cells[i] = ImageWidget:new{
                file = M.assetPath(icon), width = side, height = side,
            }
        else
            cells[i] = Widget:new{dimen = {w = side, h = side}}
        end
    end
    -- Fixed AO3 symbol positions must also stay fixed in an RTL interface.
    local grid = VerticalGroup:new{
        allow_mirroring = false, ao3_badges = true,
        HorizontalGroup:new{allow_mirroring = false,
            cells[1], HorizontalSpan:new{width = gap}, cells[2]},
        VerticalSpan:new{width = gap},
        HorizontalGroup:new{allow_mirroring = false,
            cells[3], HorizontalSpan:new{width = gap}, cells[4]},
    }
    if top > 0 then table.insert(grid, 1, VerticalSpan:new{width = top}) end
    -- Decode while still inside the registry's protected provider call, not
    -- later in the screen paint path. A damaged asset must not break browsing.
    local ok = pcall(grid.getSize, grid)
    if not ok then
        pcall(grid.free, grid)
        return nil
    end
    return grid, {frame = false}
end

function M.install()
    local ok, placeholders = pcall(require, "lib/bookshelf_placeholders")
    if not ok or placeholders.API ~= 1 or type(placeholders.register) ~= "function" then return false end
    -- The public placeholder context has no spine flag. Carry the renderer's
    -- explicit face-out flag through its synchronous fallback call instead;
    -- keep this bridge in AO3Lib rather than changing Bookshelf's source.
    local ok_spine, Spine = pcall(require, "lib/bookshelf_spine_widget")
    if ok_spine and type(Spine._renderFallback) == "function" then
        local context = Spine._ao3_badge_context
        if not context then
            context = {}
            Spine._ao3_badge_context = context
            local original = Spine._renderFallback
            Spine._renderFallback = function(self, ...)
                local previous = context.spine
                context.spine = previous or self.spine_face_out == true
                local success, widget = pcall(original, self, ...)
                context.spine = previous
                if not success then error(widget, 0) end
                return widget
            end
        end
        render_context = context
        -- Spines-view series slipcases draw a member's cover as a sticker.
        -- That inner SpineWidget has no face-out flag, so propagate the
        -- slipcase's scope through its nested fallback calls as well.
        local ok_box, Box = pcall(require, "lib/bookshelf_series_box_widget")
        if ok_box and type(Box._initSlipcase) == "function"
            and Box._ao3_badge_context ~= context then
            Box._ao3_badge_context = context
            local original = Box._initSlipcase
            Box._initSlipcase = function(self, ...)
                local previous = context.spine
                context.spine = true
                local success, result = pcall(original, self, ...)
                context.spine = previous
                if not success then error(result, 0) end
                return result
            end
        end
    end
    return placeholders.register("ao3-downloader", M.provider)
end

return M
