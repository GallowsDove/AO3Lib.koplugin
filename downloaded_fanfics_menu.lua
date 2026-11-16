local InfoMessage = require("ui/widget/infomessage")
local util = require("util")
local _ = require("gettext")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local UIManager = require("ui/uimanager")
local Config = require("fanfic_config")

local DownloadedFanficsMenu = {}

local Fields = require("fanfic_fields")

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
            Fields.normalize(fanfic, {"relationships", "characters", "tags"}, true)
        end

        -- Coauthored works appear under each credited author, just as
        -- crossovers appear under each fandom. Count a work only once per group.
        local groups, last_accessed = {}, {}
        for __, fanfic in pairs(downloaded_fanfics) do
            local field = fanfic.fandoms
            if browse_by_author then field = fanfic.author end
            local names = Fields.list(field, true)
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
                                require("fanfic_work_actions").show(Fanfic, fanfic, {
                                    deleted=function()
                                        local_works[tostring(fanfic.id)] = nil
                                        for i = #parentMenu.item_table, 1, -1 do
                                            if tostring(parentMenu.item_table[i].id) == tostring(fanfic.id) then
                                                table.remove(parentMenu.item_table, i)
                                            end
                                        end
                                        parentMenu:updateItems()
                                        local groups = refreshDownloadMenu() or {}
                                        parentMenu:updateMenuBack(1, nil, groups, nil)
                                        group_fanfic_count = group_fanfic_count - 1
                                        if group_fanfic_count == 0 then
                                            parentMenu:onReturn()
                                            if #groups == 0 then parentMenu:onReturn() end
                                        end
                                    end,
                                })
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
    return require("fanfic_work_actions").chapters(self.Fanfic, fanfic)
end

return DownloadedFanficsMenu
