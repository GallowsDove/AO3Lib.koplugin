-- Add AO3 details through runtime hooks; no Bookshelf files are modified.
local Metadata = require("fanfic_bookshelf")
local _ = require("gettext")
local Fields = require("fanfic_bookshelf_fields")
local M = {}
local function section(key)
    for __, item in ipairs(Fields.list()) do if item.key == key then return item end end
end
local label = Fields.label
local function metadata(fp)
    local ok, data = pcall(Metadata.get, fp, true)
    if ok and type(data) == "table" then return data end
end

local function matching(Repo, key, value, current, source, unknown)
    local candidates, seen = {}, {}
    if source == "ao3_downloaded" then
        local members=require("fanfic_bookshelf_sources").members(key,value,unknown)
        if members then return members end
        candidates = require("lib/bookshelf_sources").list(source) or {}
    else
    for __, fp in ipairs(Repo.getAllFilepaths()) do
        if not seen[fp] then
            seen[fp] = true
            candidates[#candidates+1] = {filepath=fp}
        end
    end
    if current and current.filepath and not seen[current.filepath] then
        candidates[#candidates+1] = {filepath=current.filepath}
    end
    end
    if source == "ao3_downloaded" and unknown then
        local out={}
        for __,book in ipairs(candidates) do
            local ok,data=pcall(Metadata.get,book.filepath,false)
            if ok and data and #(data[key] or {})==0 then out[#out+1]=book end
        end
        return out
    end
    -- Reuse the exact same field predicates as the AO3 shelf filters.
    return Repo.applyFilter(candidates, {[key]={[value]=true}})
end

local function payload(Repo, key, value, current, source, unknown)
    return {kind="tag", series_name=section(key).title .. ": " .. label(key, value),
        books=matching(Repo, key, value, current, source, unknown), latest=0,
        _fanfic_ao3={key=key, value=value, current=current and current.filepath,source=source,unknown=unknown}}
end

local function buildTab(bw, book, Repo, width, height, modal)
    local UI = require("ui/uimanager")
    local Space = require("lib/bookshelf_space")
    local Frame = require("ui/widget/container/framecontainer")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local Scroll = require("lib/bookshelf_snug_scroll")
    local Geom = require("ui/geometry")
    local data = metadata(book.filepath) or {}
    local inset = (modal and modal._side_pad) or Space.px(20)
    local bar = Scroll.widen(require("device").screen:scaleBySize(3))
    local size = (modal and modal.font_size) or 18
    local content, focus = VerticalGroup:new{align="left"}, {}
    for __, group in ipairs(Fields.list()) do
        local specs = {}
        for __, value in ipairs(data[group.key] or {}) do
            specs[#specs+1] = {label=label(group.key, value), on_tap=function()
                local results = payload(Repo, group.key, value, book)
                -- Use the modal's close lifecycle, including deferred saves.
                if modal and modal.onClose then modal:onClose()
                elseif modal then UI:close(modal) end
                bw:_expandTag(results, true)
            end}
        end
        if #specs > 0 then
            local heading = bw:_sectionHeadingBar(group.title, width, size, inset)
            -- Native headings reserve 22px above and 10px below each
            -- section. AO3 has many short fields, so use tighter local margins.
            heading.padding_top = Space.px(#content==0 and 0 or 8)
            heading.padding_bottom = Space.px(3)
            content[#content+1] = heading
            local pills, rows = bw:_buildPillGroup(specs, math.max(1, width-2*inset-bar),
                9999, size, "left", Space.px(4))
            content[#content+1] = Frame:new{bordersize=0, margin=0,
                padding_left=inset, padding_right=inset, padding_bottom=0, pills}
            if rows and #rows > 0 then
                focus[#focus+1] = {layout=rows,
                    disableFocusManagement=function(self, parent) self._parent=parent end}
            end
        end
    end
    local scroll = Scroll:new{dimen=Geom:new{w=width,h=height},
        scroll_bar_width=bar, show_parent=modal, content}
    scroll.focus_tables = focus
    return scroll
end

function M.install(Repo)
    local ok, Widget = pcall(require, "lib/bookshelf_widget")
    local ok_modal, Modal = pcall(require, "lib/bookshelf_reviews_modal")
    if not ok or not ok_modal then return false end
    if Widget._fanfic_details_installed then return true end
    for __, name in ipairs({"_showBookDetail", "_expandTag", "_buildPillGroup", "_sectionHeadingBar",
            "_serializeDrillPath", "_restoreDrillPath", "_fetchChipItems"}) do
        if type(Widget[name]) ~= "function" then return false end
    end
    if type(Modal.new) ~= "function" then return false end
    local original_show, original_new = Widget._showBookDetail, Modal.new
    local serialize, restore, fetch = Widget._serializeDrillPath, Widget._restoreDrillPath, Widget._fetchChipItems
    local context
    Widget._showBookDetail = function(self, book, opts, ...)
        local previous = context
        context = book and metadata(book.filepath) and {bw=self, book=book, opts=opts} or nil
        local result = {pcall(original_show, self, book, opts, ...)}
        context = previous
        if not result[1] then error(result[2], 0) end
        return unpack(result, 2)
    end
    Modal.new = function(class, args, ...)
        local ctx = context
        if ctx and args and args.bw == ctx.bw and type(args.tabs) == "table" then
            -- Consume this context before building anything: unrelated or
            -- nested modals must never inherit the current book's AO3 tab.
            context = nil
            args.tabs[#args.tabs+1] = {id="ao3", label=_("AO3"), widget_builder=function(w,h,parent)
                return buildTab(ctx.bw, ctx.book, Repo, w,h,parent)
            end}
            if ctx.opts and ctx.opts.active == "ao3" then args.active_tab = #args.tabs end
        end
        return original_new(class, args, ...)
    end
    Widget._serializeDrillPath = function(self, ...)
        local saved = serialize(self, ...)
        for __, entry in ipairs(saved or {}) do
            if entry.kind == "tag" or entry.kind == "author" or entry.kind == "genre" then
                for __, live in ipairs(self._drilldown_path or {}) do
                    local filter = live.payload and live.payload._fanfic_ao3
                    if filter and live.kind == entry.kind and live.label == entry.label then
                        entry._fanfic_ao3 = {key=filter.key, value=filter.value, current=filter.current,
                            source=filter.source,unknown=filter.unknown}
                        break
                    end
                end
            end
        end
        return saved
    end
    Widget._restoreDrillPath = function(self, saved, ...)
        if type(saved) ~= "table" then return restore(self, saved, ...) end
        for __, entry in ipairs(saved) do
            local filter = entry._fanfic_ao3
            if (entry.kind == "tag" or entry.kind == "author" or entry.kind == "genre")
                    and type(filter) == "table" and section(filter.key)
                    and type(filter.value) == "string" then
                local group = payload(Repo, filter.key, filter.value,
                    filter.current and {filepath=filter.current}, filter.source, filter.unknown)
                group.kind,group.series_name=entry.kind,entry.label or group.series_name
                self._drilldown_path[#self._drilldown_path+1] = {
                    kind=entry.kind, label=group.series_name, whole=entry.whole, payload=group}
            else restore(self, {entry}, ...) end
        end
    end
    Widget._fetchChipItems = function(self, ...)
        local path = self._drilldown_path or {}
        local group = path[#path] and path[#path].payload
        local filter = group and group._fanfic_ao3
        if filter then
            group.books = matching(Repo, filter.key, filter.value,
                filter.current and {filepath=filter.current}, filter.source, filter.unknown)
            group.books_meta = nil -- Membership and sort fields may have changed.
        end
        return fetch(self, ...)
    end
    if type(Widget._currentRegisteredSource)=="function" then
        local currentSource=Widget._currentRegisteredSource
        Widget._currentRegisteredSource=function(self,...)
            local path=self._drilldown_path or {}
            local filter=path[#path] and path[#path].payload and path[#path].payload._fanfic_ao3
            if filter and filter.source=="ao3_downloaded" then return {kind="ao3_downloaded"} end
            return currentSource(self,...)
        end
    end
    Widget._fanfic_details_installed = true
    return true
end

return M
