local Fields = require("ao3lib.library.fields")
local Network = require("ao3lib.ao3.network")
local ButtonDialog = require("ui/widget/buttondialog")
local KeyValuePage = require("ui/widget/keyvaluepage")
local UIManager = require("ui/uimanager")
local DownloadedFanfics = require("ao3lib.library.history")
local InfoMessage = require("ui/widget/infomessage")
local Config = require("ao3lib.core.config")
local _ = require("gettext")
local util = require("util")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template

local FanficBrowser = {
    ui = nil,
    browse_window = nil,
    updateFanficCallback = nil,
    downloadFanficCallback = nil,
    showAuthorInfoCallback = nil,
}


function FanficBrowser:generateTable(kv_pairs, ficResults, updateFanficCallback, downloadFanficCallback)
    -- Helper function to check if a fanfic is already downloaded
    local function isDownloaded(fanficId)
        return DownloadedFanfics.checkIfStored(fanficId)
    end

    -- Populate the initial list of fanfics
    for __, v in pairs(ficResults) do
        if __ == "total" then
            goto continue
        end

        if v.is_deleted or v.is_unavailable then
            table.insert(kv_pairs, { v.is_unavailable and _("Unavailable work") or "DELETED WORK", "", separator = true })
            for i = 1, 13 do
                table.insert(kv_pairs, { "", "" })
            end
            table.insert(kv_pairs, { "", "", separator = true })
            goto continue
        end
        Fields.normalize(v, {"relationships", "characters", "tags", "fandoms", "warnings"}, true)

        -- Check if the fanfic is already downloaded
        local downloadedFanfic = isDownloaded(v.id)
        local title = v.title

        -- Add a lock symbol if the work is restricted
        if v.is_restricted then
            title = "🔒 " .. title
        end

        if downloadedFanfic then
            title = "✓ " .. title -- Append the download symbol to the title
        end

        -- Add the fanfic to the list with appropriate callback

        local title_item
        title_item = {
            title,
            "",
            hold_callback = function()
                require("ao3lib.ui.work_account_actions").show(v,self.Fanfic)
            end,
            callback = function()
                local downloadedFanfic = isDownloaded(v.id)
                if downloadedFanfic then
                    require("ao3lib.ui.work_actions").show(self.Fanfic, downloadedFanfic, {
                        hide_details=true, -- The browser already displays this work's details.
                        refresh=function()
                            if self.browse_window and not self.browse_window._ao3_closed then
                                self.browse_window:reload()
                            end
                        end,
                    })
                else
                    if
                        Config:readSetting("show_adult_warning")
                        and (v.rating == "Explicit" or v.rating == "Mature" or v.rating == "Not Rated")
                    then
                        self:showAdultWarningDialog(v)
                    else
                        self:showDownloadDialog(v)
                    end
                end
            end,
        }

        table.insert(kv_pairs, title_item)
        -- Add additional details about the fanfic
        table.insert(kv_pairs, { "     " .. "Author:", (v.author or "Anonymous") .. (v.gifted_to and (" (Gifted to: " .. v.gifted_to .. ")") or "") ,
        callback = function()
            local authors={}
            for author in tostring(v.author or ""):gmatch("([^,]+)") do
                author=util.trim(author)
                if author~="" then authors[#authors+1]=author end
            end
            if #authors==1 then
                self.showAuthorInfoCallback(authors[1])
                return
            end

            local buttons = {}

            local dialog

            if v.author then
                for author in string.gmatch(v.author, '([^,]+)') do
                    table.insert(buttons, {{
                        text = util.trim(author),
                        callback = function()
                                UIManager:close(dialog)
                                self.showAuthorInfoCallback(util.trim(author))
                        end,
                    }})
                end
            end

            if v.gifted_to then
                for giftee in string.gmatch(v.gifted_to, '([^,]+)') do
                    table.insert(buttons, {{
                        text = util.trim(giftee) .. " (Giftee)",
                        callback = function()
                                UIManager:close(dialog)
                                self.showAuthorInfoCallback(util.trim(giftee))
                        end,
                    }})
                end
            end

            -- If no buttons were created, just return
            if #buttons == 0 then
                return
            end

            table.insert(buttons,{{
                text = _("Close"),
                callback = function()
                    UIManager:close(dialog)
                end,
            }})

            dialog = ButtonDialog:new({

                title = T("Work %1: %2", #authors>1 and "authors" or "author", v.author or _("Anonymous")),
                buttons = buttons,
            })
            UIManager:show(dialog)
        end,
        })
        -- Each work occupies exactly 15 rows. Extra membership rows would
        -- split this work and shift every following work across page boundaries.
        local memberships,labels={},{}
        for __,series in ipairs(type(v.series)=="table" and v.series or {}) do
            if type(series)=="table" and type(series.title)=="string" and series.title~="" then
                memberships[#memberships+1]=series
                labels[#labels+1]=series.position and T("#%1 %2",series.position,series.title) or series.title
            end
        end
        if #memberships>0 then
            local function openSeries(series)
                require("ao3lib.ui.subscriptions").series(self.Fanfic,series.id,series.title)
            end
            local row={"     " .. _("Series:"),table.concat(labels,"; ")}
            if #memberships==1 then
                if memberships[1].id then row.callback=Network.wrap(function() openSeries(memberships[1]) end) end
            else
                row.callback=function()
                    local dialog
                    local buttons={}
                    for i,series in ipairs(memberships) do
                        buttons[#buttons+1]={{text=labels[i],enabled=series.id~=nil,
                            callback=Network.wrap(function()
                                UIManager:close(dialog)
                                openSeries(series)
                            end)}}
                    end
                    buttons[#buttons+1]={{text=_("Close"),callback=function() UIManager:close(dialog) end}}
                    dialog=ButtonDialog:new{title=_("Series"),buttons=buttons}
                    UIManager:show(dialog)
                end
            end
            table.insert(kv_pairs,row)
        else
            table.insert(kv_pairs,{"     " .. _("Series:"),_("None")})
        end
        table.insert(kv_pairs, { "     " .. "Rating:", v.rating })
        table.insert(
            kv_pairs,
            { "     " .. "Fandom:", #v.fandoms > 0 and table.concat(v.fandoms, ", ") or "No fandoms available" }
        )
        table.insert(kv_pairs, { "     " .. "Date:", v.date or v.updated or v.published })
        local function tagRow(label,field,kind,empty)
            local hidden=v[field.."_hidden"]
            local row={"     "..label,hidden and (kind=="warnings" and _("Show warnings") or _("Show additional tags"))
                or (#v[field]>0 and table.concat(v[field],", ") or empty)}
            if hidden then
                row.callback=Network.wrap(function()
                    local window=self.browse_window
                    local result=require("ao3lib.ao3.client"):getHiddenTags(v.id,kind)
                    if not result.success then UIManager:show(InfoMessage:new{text=result.error});return end
                    v[field]=result.tags;v[field.."_hidden"]=false
                    if window and not window._ao3_closed and self.browse_window==window then window:reload() end
                end)
            end
            return row
        end
        table.insert(kv_pairs,tagRow("Warnings:","warnings","warnings","No warnings available"))

        table.insert(kv_pairs, {
            "     " .. "Relationships:",
            "("
                .. (v.category or _("Unknown"))
                .. ") "
                .. (#v.relationships > 0 and table.concat(v.relationships, ", ") or "No relationships available"),
        })
        table.insert(kv_pairs, {
            "     " .. "Characters:",
            #v.characters > 0 and table.concat(v.characters, ", ") or "No characters available",
        })
        table.insert(kv_pairs,tagRow("Other Tags:","tags","freeforms","No tags available"))

        table.insert(kv_pairs, { "     " .. "Summary:", v.summary })
        table.insert(kv_pairs, { "     " .. "Language:", v.language })
        table.insert(kv_pairs, { "     " .. "Words:", require("ao3lib.core.format").integer(v.words or v.wordcount) })
        table.insert(kv_pairs, { "     " .. (v.iswip or _("Unknown")) .. ", Chapters:", v.chapters })

        -- Combine comments, kudos, bookmarks, and hits into one line
        local stats = string.format(
            "Hits: %s | Kudos: %s | Bookmarks: %s | Comments: %s",
            v.hits or "0",
            v.kudos or "0",
            v.bookmarks or "0",
            v.comments or "0"
        )
        table.insert(kv_pairs, { "     " .. "Stats:", stats, separator = true })
        ::continue::
    end

    return kv_pairs
end

function FanficBrowser:showDeleteDialog(fanfic)
    return require("ao3lib.ui.work_actions").delete(fanfic, {
        refresh=function()
            if self.browse_window and not self.browse_window._ao3_closed then self.browse_window:reload() end
        end,
    })
end

function FanficBrowser:showDownloadDialog(fanfic)
    if not fanfic.id then 
        return
    end

    local confirmDialog
    confirmDialog = ButtonDialog:new({
        title = T("Would you like to download the work: %1 by %2?", fanfic.title, fanfic.author or "Anonymous"),
        buttons = {
            {
                {
                    text = "No",
                    callback = function()
                        UIManager:close(confirmDialog)
                    end,
                },
                {
                    text = "Yes",
                    callback = function()
                        Network.schedule(0, function()
                            self.downloadFanficCallback(fanfic.id)
                            self.browse_window:reload()
                        end)
                        UIManager:close(confirmDialog)
                    end,
                },
            },
        },
    })
    UIManager:show(confirmDialog)
end

function FanficBrowser:showAdultWarningDialog(fanfic)
    local warningDialog
    warningDialog = ButtonDialog:new({
        title = "This work could have adult content. If you continue, you have agreed that you are willing to see such content",
        buttons = {
            {
                {
                    text = "Cancel",
                    callback = function()
                        UIManager:close(warningDialog)
                    end,
                },
                {
                    text = "Continue",
                    callback = function()
                        UIManager:close(warningDialog)
                        self:showDownloadDialog(fanfic)
                    end,
                },
            },
        },
    })
    UIManager:show(warningDialog)
end

function FanficBrowser:show(ui, ficResults, fetchNextPage, updateFanficCallback, downloadFanficCallback, showAuthorInfoCallback, Fanfic, title, view_options)
    self.ui = ui
    self.updateFanficCallback = updateFanficCallback
    self.downloadFanficCallback = downloadFanficCallback
    self.showAuthorInfoCallback = showAuthorInfoCallback
    self.Fanfic = Fanfic
    view_options=view_options or {}
    -- Restore the browser callbacks when a nested author/series/work closes.
    local function resume(window)
        self.ui, self.Fanfic = ui, Fanfic
        self.updateFanficCallback, self.downloadFanficCallback = updateFanficCallback, downloadFanficCallback
        self.showAuthorInfoCallback, self.browse_window = showAuthorInfoCallback, window
    end
    local total_fic_count=ficResults.total
    local pager=require("ao3lib.ao3.work_paging").get(fetchNextPage)
    if pager then pager:setTotal(total_fic_count) end
    if not Config:readSetting("formatted_work_view",false) and pager and pager.total then
        return require("ao3lib.ui.work_list").show(self,{ui=ui,works=ficResults,fetch=fetchNextPage,
            update=updateFanficCallback,download=downloadFanficCallback,author=showAuthorInfoCallback,
            plugin=Fanfic,title=title,index=view_options.index,
            replacing=view_options.replacing,resume=resume})
    end
    if Config:readSetting("formatted_work_view",false) then
        return require("ao3lib.ui.work_view").show(self,{ui=ui,works=ficResults,fetch=fetchNextPage,
            update=updateFanficCallback,download=downloadFanficCallback,author=showAuthorInfoCallback,
            plugin=Fanfic,title=title,index=view_options.index,
            replacing=view_options.replacing,resume=resume})
    end
    local kv_pairs = self:generateTable({}, ficResults, updateFanficCallback, downloadFanficCallback)
    ficResults.total = nil
    local fanfics_loaded = ficResults

    local items_per_fic = 15

    local function fitWorkPage(window)
        local count=window.items_per_page
        if count~=items_per_fic then
            if window.item_height and count then
                window.item_height=math.floor(window.item_height*count/items_per_fic)
                window.items_font_size=math.min(require("ui/widget/textboxwidget"):getFontSizeToFitHeight(
                    window.item_height,1,1.0),22)
            end
            window.items_per_page=items_per_fic
        end
        window.pages=math.ceil(#window.kv_pairs/window.items_per_page)
    end
    local BrowseWindow = KeyValuePage:extend({
    })
    -- Override _populateItems to check if it's the last page and load more results
    BrowseWindow._populateItems = function(selfself)
        fitWorkPage(selfself)
        if fetchNextPage and selfself.show_page == selfself.pages then
            Network.run(function()
                -- The user may have left this window while connecting.
                if selfself._ao3_closed or selfself.show_page ~= selfself.pages or selfself._ao3_page_loading then return end
                local page=selfself.show_page
                selfself._ao3_page_loading=true
                local ok,newFics=pcall(fetchNextPage)
                selfself._ao3_page_loading=false
                if not ok then error(newFics,0) end
                if selfself._ao3_closed or selfself.show_page~=page then return end
                if newFics and #newFics > 0 then
                    selfself:addNewFanfics(newFics)
                end
            end)
        end

        -- Call the original _populateItems function
        KeyValuePage._populateItems(selfself)
    end

    BrowseWindow.addNewFanfics = function(selfself, newFics)
        selfself.kv_pairs = self:generateTable(selfself.kv_pairs, newFics, updateFanficCallback, downloadFanficCallback)

        newFics.total = nil
        -- Add new works to loaded fanfics table
        for k, v in pairs(newFics) do
            table.insert(fanfics_loaded, v)
        end

        -- Update the total number of pages
        selfself.pages = math.ceil(#selfself.kv_pairs / selfself.items_per_page)
        self.browse_window = BrowseWindow:new({
            title = selfself.title,
            title_bar_left_icon = require("ao3lib.ui.icons").name,
            title_bar_fm_style = true,
            is_popout = false,
            is_borderless = true,
            kv_pairs = selfself.kv_pairs,
            show_page = selfself.show_page,
            value_overflow_align = "center",
        })
        require("ao3lib.ui.navigation").bind(Fanfic, self.browse_window, {replace=selfself, resume=resume})
        self.browse_window:setMaximumPageValueCount(items_per_fic)
        UIManager:show(self.browse_window)
        UIManager:close(selfself)
    end

    BrowseWindow.reload = function(selfself)
        selfself.kv_pairs = self:generateTable({}, fanfics_loaded, updateFanficCallback, downloadFanficCallback)

        -- Update the total number of pages
        selfself.pages = math.ceil(#selfself.kv_pairs / selfself.items_per_page)
        if (self.browse_window) then
            self.Fanfic.menu_stack[self.browse_window] = nil
        end
        self.browse_window = BrowseWindow:new({
            title = selfself.title,
            title_bar_left_icon = require("ao3lib.ui.icons").name,
            title_bar_fm_style = true,
            is_popout = false,
            is_borderless = true,
            kv_pairs = selfself.kv_pairs,
            show_page = selfself.show_page,
            value_overflow_align = "center",
        })
        self.Fanfic.menu_stack[self.browse_window] = true
        require("ao3lib.ui.navigation").bind(Fanfic, self.browse_window, {replace=selfself, resume=resume})
        self.browse_window:setMaximumPageValueCount(items_per_fic)
        UIManager:show(self.browse_window)
        UIManager:close(selfself)
    end


    BrowseWindow.setMaximumPageValueCount = function(selfself)
        fitWorkPage(selfself)
        selfself:_populateItems()
    end

    BrowseWindow.onClose = function(selfself)
        selfself._ao3_closed = true
        self.Fanfic.menu_stack[selfself] = nil
        return KeyValuePage.onClose(selfself)
    end

    -- Create the KeyValuePage
    self.browse_window = BrowseWindow:new({
        title = title or T("(%1) Tap work title to download", total_fic_count or "ERROR"),
        title_bar_left_icon = require("ao3lib.ui.icons").name,
        title_bar_fm_style = true,
        is_popout = false,
        is_borderless = true,
        kv_pairs = kv_pairs,
        value_overflow_align = "center",
        show_page = view_options.index or 1,
    })

    require("ao3lib.ui.navigation").bind(Fanfic, self.browse_window, {replace=view_options.replacing, resume=resume})

    self.browse_window:setMaximumPageValueCount(items_per_fic)

    UIManager:show(self.browse_window)
end

return FanficBrowser
