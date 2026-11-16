local Network = require("fanfic_network")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local util = require("util")
local logger = require("logger")
local DownloadedFanfics = require("downloaded_fanfics")
local FanficReader = require("fanfic_reader")
local _ = require("gettext")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local UIManager = require("ui/uimanager")
local Config = require("fanfic_config")

local DownloadedFanficsMenu = {}

-- Helper function to normalize a field to always be a table
local function normalizeField(field)
    if type(field) == "string" then
        -- Split the string by commas and trim whitespace
        local result = {}
        for item in string.gmatch(field, "([^,]+)") do
            table.insert(result, util.trim(item))
        end
        return result
    elseif type(field) == "table" then
        return field -- Already a table
    else
        return {}    -- Default to an empty table
    end
end

function DownloadedFanficsMenu:show(ui, parentMenu, updateFanficCallback, Fanfic, local_works)
    self.Fanfic = Fanfic
    local browse_by_author = false

    local function refreshDownloadMenu()
        local downloaded_fanfics = local_works or {}
        if next(downloaded_fanfics) == nil then
            UIManager:show(InfoMessage:new({
                text = "No fanfics downloaded yet.",
            }))
            return
        end

        -- Normalize relationships, characters, and tags for each fanfic
        for __, fanfic in pairs(downloaded_fanfics) do
            fanfic.relationships = normalizeField(fanfic.relationships)
            fanfic.characters = normalizeField(fanfic.characters)
            fanfic.tags = normalizeField(fanfic.tags)
        end

        -- Coauthored works appear under each credited author, just as
        -- crossovers appear under each fandom. Count a work only once per group.
        local groups, last_accessed = {}, {}
        for __, fanfic in pairs(downloaded_fanfics) do
            local field = fanfic.fandoms
            if browse_by_author then field = fanfic.author end
            local names = normalizeField(field)
            local seen = {}
            for __, name in ipairs(names) do
                name = util.trim(name)
                if name ~= "" then seen[name] = true end
            end
            if next(seen) == nil then
                seen[browse_by_author and _("Anonymous") or _("Unknown Fandom")] = true
            end
            for name in pairs(seen) do
                groups[name] = groups[name] or {}
                table.insert(groups[name], fanfic)
            end
        end
        for name, fanfics in pairs(groups) do
            local latest = ""
            for __, fanfic in ipairs(fanfics) do
                if (fanfic.last_accessed or "") > latest then latest = fanfic.last_accessed end
            end
            last_accessed[name] = latest
        end
        local sorted_groups = {}
        for name in pairs(groups) do sorted_groups[#sorted_groups + 1] = name end
        table.sort(sorted_groups, function(a, b)
            if not browse_by_author and last_accessed[a] ~= last_accessed[b] then
                return last_accessed[a] > last_accessed[b]
            end
            if a:lower() ~= b:lower() then return a:lower() < b:lower() end
            return a < b
        end)

        -- Create the group menu with a work list for each author or fandom
        local menu_items = {}
        for __, group_name in ipairs(sorted_groups) do
            local fanfics = groups[group_name]

            -- Define the action for selecting a group
            table.insert(menu_items, {
                text = T("(%1) %2", #fanfics, group_name),
                callback = function()
                    -- Only sort the group being opened. Large crossover
                    -- libraries can contain many unopened groups.
                    table.sort(fanfics, function(a, b)
                        if (a.last_accessed or "") ~= (b.last_accessed or "") then
                            return (a.last_accessed or "") > (b.last_accessed or "")
                        end
                        if (a.title or "") ~= (b.title or "") then return (a.title or "") < (b.title or "") end
                        return tostring(a.id) < tostring(b.id)
                    end)
                    -- Create the submenu for the selected group
                    local submenu_items = {}
                    local group_fanfic_count = #fanfics
                    for __, fanfic in ipairs(fanfics) do
                        local fanfic_read = true
                        local first_unread_chapter = nil
                        local unread_count = 0
                        if fanfic.chapter_data and #fanfic.chapter_data > 0 then
                            for index, chapter in pairs(fanfic.chapter_data) do
                                    if not chapter.read then
                                        fanfic_read = false
                                        unread_count = unread_count + 1
                                        first_unread_chapter = first_unread_chapter or index
                                    end
                            end
                        else
                            fanfic_read = fanfic.read or false
                        end

                        local chapter_count, chapter_total = (fanfic.chapters or "?/?"):match("(%d+)%s*/%s*(%d+)")
                        local fanfic_complete = tonumber(chapter_count) and tonumber(chapter_total)
                            and tonumber(chapter_count) >= tonumber(chapter_total) or false

                        local prefix = "  "
                        if fanfic_read and (not fanfic_complete) then
                            prefix = "=" 
                        elseif fanfic_read and fanfic_complete then
                            prefix = "✓"
                      elseif (not fanfic_read) and (first_unread_chapter or 0) > 1 then

                            if Config:readSetting("show_current_chapter", true) then
                                prefix = "⛉" .. tostring(first_unread_chapter)
                            else
                                prefix = "•󠁏" .. tostring(unread_count)
                            end
                        end

                        table.insert(submenu_items, {
                            text = T("%1 (%2) %3 by %4",prefix, fanfic.chapters, fanfic.title, fanfic.author ~= "" and fanfic.author or "anonymous"),
                            id = fanfic.id,
                            callback = function()
                                -- Show options for the fanfic
                                local dialog

                                local open_buttons = {
                                    {
                                        text = _("Open"),
                                        callback = function()
                                            -- Update the `last_accessed` field
                                            fanfic.last_accessed = os.date("%Y-%m-%d %H:%M:%S")
                                            DownloadedFanfics.update(fanfic)

                                            UIManager:close(dialog)
                                            self.Fanfic:onOpenFanficReader(fanfic.path, fanfic)
                                        end,
                                    },
                                }

                                if fanfic.chapter_data and #fanfic.chapter_data > 0 then
                                    table.insert(open_buttons, {
                                        text = _("Open at chapter"),
                                        callback = function()
                                            -- Update the `last_accessed` field
                                            fanfic.last_accessed = os.date("%Y-%m-%d %H:%M:%S")
                                            DownloadedFanfics.update(fanfic)

                                            UIManager:close(dialog)
                                            DownloadedFanficsMenu:showFanficChapterSelect(
                                                ui,
                                                fanfic,
                                                parentMenu
                                            )
                                        end,
                                    })
                                end

                                dialog = ButtonDialog:new({
                                    title = T(_("Options for '%1'"), fanfic.title),
                                    buttons = {
                                        
                                            open_buttons
                                        ,
                                        {
                                            {
                                                text = _("Update"),
                                                callback = function()
                                                    Network.schedule(0, function()
                                                        -- Update the fanfic
                                                        updateFanficCallback(fanfic)
                                                        UIManager:close(dialog)
                                                    end)
                                                end,
                                                UIManager:close(dialog),
                                            },
                                            {
                                                text = _("View Details"),
                                                callback = function()
                                                    -- Show detailed information
                                                    local details = string.format(
                                                        "Fandoms: %s\n\nStatus: %s \nChapters: %s\nPublished: %s\nUpdated: %s\nAuthor: %s\n\nSummary:\n%s\n\nRating: %s\nCategory: %s\n\nTags:\nWarnings:\n%s\n\nRelationships:\n%s\n\nCharacters:\n%s\n\nOther Tags:\n%s\n\nBookmarked: %s\nMarked for Later: %s\nSubscribed: %s\n\nStats: \nWords: %s \nHits: %s\nKudos: %s\nBookmarks: %s\nComments: %s",
                                                        (
                                                            #fanfic.fandoms > 0 and table.concat(fanfic.fandoms, ", ")
                                                            or "No fandoms available"
                                                        ),
                                                        fanfic.iswip or "Unknown",
                                                        fanfic.chapters or "Unknown",
                                                        fanfic.published or "Unknown",
                                                        fanfic.updated or "Unknown",
                                                        fanfic.author or "Unknown",
                                                        fanfic.summary or "No summary available",
                                                        fanfic.rating or "Unknown",
                                                        fanfic.category or "Unknown",
                                                        (
                                                            #fanfic.warnings > 0 and table.concat(fanfic.warnings, ", ")
                                                            or "No warnings available"
                                                        ),
                                                        (
                                                            #fanfic.relationships > 0
                                                            and table.concat(fanfic.relationships, ", ")
                                                            or "No relationships available"
                                                        ),
                                                        (
                                                            #fanfic.characters > 0
                                                            and table.concat(fanfic.characters, ", ")
                                                            or "No characters available"
                                                        ),
                                                        (
                                                            #fanfic.tags > 0 and table.concat(fanfic.tags, ", ")
                                                            or "No tags available"
                                                        ),
                                                        fanfic.bookmarkID and "Yes (" .. tostring(fanfic.bookmarkID) ..")" or "No",
                                                        fanfic.markedForLater and "Yes" or "No",
                                                        fanfic.subscriptionID and "Yes (" .. fanfic.subscriptionID ..")" or "No",
                                                        fanfic.wordcount or "Unknown",
                                                        fanfic.hits or "0",
                                                        fanfic.kudos or "0",
                                                        fanfic.bookmarks or "0",
                                                        fanfic.comments or "0"
                                                    )
                                                    UIManager:show(TextViewer:new({
                                                        title = fanfic.title,
                                                        text = details,
                                                    }))
                                                    UIManager:close(dialog)
                                                end,
                                            },
                                        },
                                        {
                                            {
                                                text = _("Cancel"),
                                                callback = function()
                                                    UIManager:close(dialog)
                                                end,
                                            },
                                            {
                                                text = _("Delete"),
                                                callback = function()
                                                    local confirmDialog
                                                    -- Confirm deletion
                                                    confirmDialog = ButtonDialog:new({
                                                        title = T(_("Are you sure you want to delete '%1'?"),
                                                            fanfic.title),
                                                        buttons = {
                                                            {
                                                                {
                                                                    text = _("Delete"),
                                                                    callback = function()
                                                                        local file_path = fanfic.path
                                                                        local success, err = util.removeFile(file_path)
                                                                        if success then
                                                                            DownloadedFanfics.delete(fanfic.id)
                                                                            local_works[tostring(fanfic.id)] = nil
                                                                            UIManager:show(
                                                                                InfoMessage:new({
                                                                                    text = T(
                                                                                        _("'%1' has been deleted."),
                                                                                        fanfic.title
                                                                                    ),
                                                                                })
                                                                            )
                                                                        else
                                                                            logger.err("Failed to delete file:", err)
                                                                            UIManager:show(
                                                                                InfoMessage:new({
                                                                                    text = T(
                                                                                        _(
                                                                                            "Failed to delete file for '%1': %2"
                                                                                        ),
                                                                                        fanfic.title,
                                                                                        err
                                                                                    ),
                                                                                })
                                                                            )
                                                                            UIManager:close(confirmDialog)
                                                                            return
                                                                        end
                                                                        for i, menu_item in pairs(parentMenu.item_table) do
                                                                            if tostring(menu_item.id) == tostring(fanfic.id) then
                                                                                table.remove(parentMenu.item_table, i)
                                                                            end
                                                                        end
                                                                        parentMenu:updateItems()
                                                                        local new_download_menu_items = refreshDownloadMenu()
                                                                        parentMenu:updateMenuBack(1, nil, new_download_menu_items, nil)
                                                                        group_fanfic_count = group_fanfic_count - 1
                                                                        if group_fanfic_count == 0 then
                                                                            parentMenu:onReturn()
                                                                            if not new_download_menu_items or #new_download_menu_items == 0 then
                                                                                parentMenu:onReturn()
                                                                            end
                                                                        end
                                                                        UIManager:close(confirmDialog)

                                                                    end,
                                                                },
                                                                {
                                                                    text = _("Cancel"),
                                                                    callback = function()
                                                                        UIManager:close(confirmDialog)
                                                                    end,
                                                                },
                                                            },
                                                        },
                                                    })
                                                    UIManager:show(confirmDialog)
                                                    UIManager:close(dialog)
                                                end,
                                            }
                                        },
                                    },
                                })
                                UIManager:show(dialog)
                            end,
                        })
                    end

                    -- Use GoDownInMenu to navigate into the submenu
                    parentMenu:GoDownInMenu(T(browse_by_author and _("Works by %1") or _("Fanfics in '%1'"), group_name), submenu_items)
                end,
                hold_callback = function()
                    -- Show a notification with the full group name
                    UIManager:show(InfoMessage:new({
                        text = T("%1", group_name),
                    }))
                end,
            })
        end
        return menu_items
    end


    local download_menu_items = refreshDownloadMenu()
    if not download_menu_items then
        return
    end
    -- Create and show the main menu
    parentMenu:GoDownInMenu(_("Downloaded Works"), {
        {text = _("By fandom"), callback = function()
            browse_by_author = false
            local items = refreshDownloadMenu()
            if items then parentMenu:GoDownInMenu(_("Downloaded Works by Fandom"), items) end
        end},
        {text = _("By author"), callback = function()
            browse_by_author = true
            local items = refreshDownloadMenu()
            if items then parentMenu:GoDownInMenu(_("Downloaded Works by Author"), items) end
        end},
    })
end

function DownloadedFanficsMenu:showFanficChapterSelect(ui, fanfic, parentMenu)
    if not fanfic.chapter_data then
        return
    end

    local chapter_options = {}

    for idx, chapter in pairs(fanfic.chapter_data) do
        table.insert(chapter_options, {
            text = (chapter.read and "✓ " or "") .. chapter.name,
            callback = function()
                self.Fanfic:onOpenFanficReader(fanfic.path, fanfic, idx)
            end,
        })
    end

    parentMenu:GoDownInMenu("Select Chapter to Open", chapter_options)
end

return DownloadedFanficsMenu
