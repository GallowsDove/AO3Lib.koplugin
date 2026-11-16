local Network = require("fanfic_network")
local Menu = require("ui/widget/menu")
local _ = require("gettext")
local FanficSearch = require("fanfic_search")
local FanficBrowser = require("fanficbrowser")
local Config = require("fanfic_config")
local UIManager = require("ui/uimanager")
local DownloadedFanficsMenu = require("downloaded_fanfics_menu")
local ButtonDialog = require("ui/widget/buttondialog")
local util = require("util")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local logger = require("logger")
local CustomFilterMenu = require("custom_filter_menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local DownloadedFanfics = require("downloaded_fanfics")

function util.contains(table, value)
    for _, v in ipairs(table) do
        if v == value then
            return true
        end
    end
    return false
end

local FanficMenuWidget = Menu:extend({
    fanfic = nil,
    is_popout = false,
    is_borderless = true,
    paths = nil,
    title = "AO3Lib",
    subtitle = "",
    lock_return = false,
})

-- Menu action on return-arrow tap (go to one-level upper catalog)
function FanficMenuWidget:onReturn()
    if self.lock_return then
        return
    end
    local path = self.paths[#self.paths]
    if path then
        self:switchItemTable(path.title, path.items, -1, -1, path.subtitle)
        self.title = path.title
        self.subtitle = path.subtitle
        table.remove(self.paths, #self.paths)
    end
    return true
end

function FanficMenuWidget:GoDownInMenu(newTitle, newItems, newSubtitle)
    table.insert(self.paths, {
        title = self.title,
        items = self.item_table,
        subtitle = self.subtitle,
    })
    self:switchItemTable(newTitle, newItems, -1, -1, newSubtitle)
    self.title = newTitle
    self.subtitle = newSubtitle
end

function FanficMenuWidget:updateMenuBack(backAmount, newTitle, newItems, newSubtitle)
    local currentBackMenu = self.paths[#self.paths]
    local index = #self.paths - (backAmount - 1)
    self.paths[index].title = newTitle or currentBackMenu.title
    self.paths[index].items = newItems or currentBackMenu.items
    self.paths[index].subtitle = newSubtitle or currentBackMenu.subtitle
end

function FanficMenuWidget:onClose()
    self.Fanfic.menu_stack[self] = nil
    return Menu.onClose(self)
end

local FanficMenu = {}

function FanficMenu:show(fanfic)
    self.fanfic = fanfic
    self.menuWidget = FanficMenuWidget:new({
        title = _("AO3Lib"),
        title_bar_left_icon = require("fanfic_icons").name,
        item_table = {
            {
                text = "\u{f002} Search and download works from AO3",
                callback = function()
                    self:onSearchFanficMenu()
                end,
            },
            {
                text = "\u{2193} View downloaded fanfics",
                callback = function()
                    self:onViewDownloadedFanfics()
                end,
            },
            {
                text = _("Review downloaded work updates"),
                callback = function()
                    require("fanfic_update_review").show(self.fanfic)
                end,
            },
            {
                text = "Account management",
                callback = function()
                    self:onAccountManagementMenu()
                end,
            },
            {
                text = "\u{2699} Settings",
                callback = function()
                    self:onOpenSettings()
                end,
            },
        },
        Fanfic = self.fanfic,
    })

    self.fanfic.menu_stack[self.menuWidget] = true

    return self.menuWidget
end

function FanficMenu:refreshAccountManagementMenu()
    local menu_items = {
        {
            text = self.logged_in and ("Logged in as: " .. self.username) or "Not logged in",
        },
    }

    if not self.logged_in then
        table.insert(menu_items, {
            text = "Log in",
            callback = function()
                self:enterUserDetails()
            end,
        })
    else
        table.insert(menu_items, {
            text = "View your AO3 profile",
            callback = function()
                self.fanfic:showUserInfo(self.username, self.username, self.menuWidget)
            end,
        })
        table.insert(menu_items, {
            text = "Log out",
            callback = Network.wrap(function()
                self.logged_in = not self.fanfic:logoutOfAO3()
                self.menuWidget.item_table = self:refreshAccountManagementMenu()
                self.menuWidget:updateItems()
            end),
        })
    end

    return menu_items
end

function FanficMenu:onAccountManagementMenu()
    if Network.defer(function() self:onAccountManagementMenu() end) then return end
    local success, logged_in, username = self.fanfic:checkLoggedIn()

    if success then
        self.logged_in, self.username = logged_in, username
        self.menuWidget:GoDownInMenu("Account management", self:refreshAccountManagementMenu())
    end
end

function FanficMenu:enterUserDetails()
    self.login_dialog = MultiInputDialog:new({
        title = "Enter login details:",
        fields = {
            {
                text = "",
                --description = T(_("Username and password")),
                hint = "Username",
            },
            {
                text = "",
                text_type = "password",
                hint = "Password",
            },
        },
        buttons = {
            {
                {
                    text = "Cancel",
                    id = "close",
                    callback = function()
                        UIManager:close(self.login_dialog)
                    end,
                },
                {
                    text = "Login",
                    callback = Network.wrap(function()
                        local myfields = self.login_dialog:getFields()
                        local logged_in = self.fanfic:loginToAO3(myfields[1], myfields[2])
                        if not logged_in then return end
                        UIManager:close(self.login_dialog)
                        self.logged_in = logged_in
                        self.username = myfields[1]
                        self.menuWidget.item_table = self:refreshAccountManagementMenu()
                        self.menuWidget:updateItems()
                    end),
                },
            },
        },
    })
    UIManager:show(self.login_dialog)
    self.login_dialog:onShowKeyboard()
end

function FanficMenu:onSearchFanficMenu()
    local menu_items = {
        {
            text = "Browse works by Fandom",
            callback = function()
                self:onSelectTag("Fandom")
            end,
        },
        {
            text = "Browse works by Character",
            callback = function()
                self:onSelectTag("Character")
            end,
        },
        {
            text = "Browse works by Relationship",
            callback = function()
                self:onSelectTag("Relationship")
            end,
        },
        {
            text = "Browse works by Freeform tag",
            callback = function()
                self:onSelectTag("Freeform")
            end,
        },
        {
            text = _("Search using Filter search"), -- New menu item
            callback = function()
                CustomFilterMenu:show(self.menuWidget, self.fanfic)
            end,
        },
        {
            text = _("Download work by ID"),
            callback = function()
                self:onShowFanficSearch()
            end,
        },
        {
            text = _("Search for users"),
            callback = function()
                self:onSelectUserSearch()
            end,
        },
        {
            text = _("Browse Account History"),
            callback = function()
                self:onSelectAccountHistory(false)
            end,
        },
        {
            text = _("Browse Account Marked for Later"),
            callback = function()
                self:onSelectAccountHistory(true)
            end,
        }
    }
    self.menuWidget:GoDownInMenu("Select search mode", menu_items)
end

function FanficMenu:onShowFanficSearch()
    FanficSearch:show(function(fanficId)
        self.fanfic:DownloadFanfic(fanficId)
    end)
end

function FanficMenu:onSelectTag(category)
    local bookmarkSetting = T("bookmarked%1s", category)
    local function refreshMenu()
        local menu_items = {}

        -- Add an option to search for fandoms
        table.insert(menu_items, {
            text = T("\u{f002} Search %1", category),
            callback = function()
                self:onSearchTag(category)
            end,
        })

        -- Get the list of bookmarked fandoms
        local bookmarks = Config:readSetting(bookmarkSetting, {})

        -- Add bookmarked fandoms to the menu
        for __, tag in ipairs(bookmarks) do
            local displayText = T("★ %1", tag)
            table.insert(menu_items, {
                text = displayText,
                callback = function()
                    -- Submenu for the selected fandom
                    local dialog
                    dialog = ButtonDialog:new({
                        title = displayText,
                        buttons = {
                            {
                                {
                                    text = _("Browse Works"),
                                    callback = function()
                                        self:onBrowseByTag(tag)
                                        UIManager:close(dialog)
                                    end,
                                },
                                {
                                    text = _(T("Unbookmark %1", category)),
                                    callback = function()
                                        -- Remove the fandom from bookmarks
                                        for i, v in ipairs(bookmarks) do
                                            if v == tag then
                                                table.remove(bookmarks, i)
                                                break
                                            end
                                        end
                                        Config:saveSetting(bookmarkSetting, bookmarks)
                                        UIManager:show(InfoMessage:new({
                                            text = T("'%1' has been removed from your bookmarks.", tag),
                                        }))
                                        UIManager:close(dialog)
                                        refreshMenu()                              -- Refresh the menu to update the star
                                        self.menuWidget.item_table = refreshMenu() -- Refresh the menu to update the star
                                        self.menuWidget:updateItems()
                                    end,
                                },
                            },
                        },
                    })
                    UIManager:show(dialog)
                end,
            })
        end

        return menu_items
    end

    -- Initial menu display

    self.menuWidget:GoDownInMenu(T("Select a %1 tag", category), refreshMenu())
end

function FanficMenu:onSearchTag(category)
    -- Show an input dialog to enter the fandom search query
    local searchDialog
    local bookmarkSetting = T("bookmarked%1s", category)
    searchDialog = InputDialog:new({
        title = T("Search for %1s tags on AO3", category),
        input = "",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Close"),
                    id = "close",
                    callback = function()
                        UIManager:close(searchDialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = Network.wrap(function()
                        local query = searchDialog:getInputText()
                        local success, tags
                        -- Function to refresh the menu items
                        local function refreshMenu()
                            local bookmarks = Config:readSetting(bookmarkSetting, {})

                            -- Show the matching fandoms in a menu
                            local menu_items = {}
                            for __, tag in ipairs(tags) do
                                local isBookmarked = util.contains(bookmarks, tag.name)
                                local displayText = isBookmarked and T("★ (%1) %2", tag.uses, tag.name)
                                    or T("(%1) %2", tag.uses, tag.name)

                                table.insert(menu_items, {
                                    text = displayText,
                                    callback = function()
                                        local dialog
                                        dialog = ButtonDialog:new({
                                            title = displayText,
                                            buttons = {
                                                {
                                                    {
                                                        text = _("Browse Works"),
                                                        callback = function()
                                                            self:onBrowseByTag(tag.name)
                                                            UIManager:close(dialog)
                                                        end,
                                                    },
                                                    {
                                                        text = _(
                                                            not isBookmarked and T("Bookmark %1", category)
                                                            or T("Unbookmark %1", category)
                                                        ),
                                                        callback = function()
                                                            -- Add the fandom to bookmarks
                                                            if not isBookmarked then
                                                                table.insert(bookmarks, tag.name)
                                                                Config:saveSetting(bookmarkSetting, bookmarks)
                                                                UIManager:show(
                                                                    InfoMessage:new({
                                                                        text = T(
                                                                            "'%1' has been added to your bookmarks.",
                                                                            tag.name
                                                                        ),
                                                                    })
                                                                )
                                                            else
                                                                for i, v in ipairs(bookmarks) do
                                                                    if v == tag.name then
                                                                        table.remove(bookmarks, i)
                                                                        break
                                                                    end
                                                                end
                                                                Config:saveSetting(bookmarkSetting, bookmarks)
                                                                UIManager:show(
                                                                    InfoMessage:new({
                                                                        text = T(
                                                                            "'%1' has been removed from your bookmarks.",
                                                                            tag.name
                                                                        ),
                                                                    })
                                                                )
                                                            end
                                                            UIManager:close(dialog)
                                                            self.menuWidget.item_table = refreshMenu() -- Refresh the menu to update the star
                                                            self.menuWidget:updateItems()
                                                        end,
                                                    },
                                                },
                                            },
                                        })
                                        UIManager:show(dialog)
                                    end,
                                })
                            end
                            return menu_items
                        end
                        Network.schedule(0, function()
                            local success
                            success, tags = self.fanfic:searchForTags(query, category)

                            if not success or not tags then
                                return
                            end
                            UIManager:close(searchDialog)
                            --

                            -- Initial menu display

                            self.menuWidget:GoDownInMenu(T('"%1" %2 query results', query, category), refreshMenu())
                        end)
                    end),
                },
            },
        },
    })

    UIManager:show(searchDialog)
    searchDialog:onShowKeyboard()
end

function FanficMenu:onBrowseByTag(selectedTag)
    -- Define available sorting options
    local sorting_options = {
        { text = _("Sort by Author"),       value = "authors_to_sort_on" },
        { text = _("Sort by Title"),        value = "title_to_sort_on" },
        { text = _("Sort by Date Posted"),  value = "created_at" },
        { text = _("Sort by Date Updated"), value = "revised_at" },
        { text = _("Sort by Word Count"),   value = "word_count" },
        { text = _("Sort by Hits"),         value = "hits" },
        { text = _("Sort by Kudos"),        value = "kudos_count" },
        { text = _("Sort by Comments"),     value = "comments_count" },
        { text = _("Sort by Bookmarks"),    value = "bookmarks_count" },
    }

    -- Create a menu for sorting options
    local menu_items = {}
    for __, option in ipairs(sorting_options) do
        table.insert(menu_items, {
            text = option.text,
            callback = Network.wrap(function()
                Network.schedule(0, function()
                    local success, ficResults, fetchNextPage = self.fanfic:fetchFanficsByTag(selectedTag, option.value)
                    if not success then
                        return
                    end

                    self.fanfic:onShowFanficBrowser(
                        ficResults,
                        fetchNextPage
                    )
                end)
            end),
        })
    end

    self.menuWidget:GoDownInMenu("Sort by...", menu_items)
end

function FanficMenu:onViewDownloadedFanfics()
    local cancelled,complete=false,false
    local works,rows={},{}
    local owner=self.menuWidget
    local function replace(found)
        -- Keep this table stable for author/fandom menus opened mid-scan.
        for id in pairs(works) do if not found[id] then works[id]=nil end end
        for id,work in pairs(found) do
            local state=DownloadedFanfics.get(id)
            local merged={}
            for key,value in pairs(work) do merged[key]=value end
            if state then
                merged.chapter_data=state.chapter_data or merged.chapter_data
                merged.read=state.read
                merged.last_accessed=state.last_accessed
            end
            works[id]=merged
        end
    end
    local function invalid()
        return cancelled or (UIManager.isWidgetShown and not UIManager:isWidgetShown(owner))
    end
    local render
    render=function()
        for i=#rows,1,-1 do rows[i]=nil end
        local sorted={}
        for _,work in pairs(works) do sorted[#sorted+1]=work end
        table.sort(sorted,function(a,b) return (a.title or "")<(b.title or "") end)
        rows[#rows+1]={text=complete and T("Found %1 AO3 works",#sorted)
            or T("Scanning… %1 AO3 works found",#sorted),enabled=false}
        rows[#rows+1]={text=_("Browse by fandom or author"),enabled=#sorted>0,callback=function()
            if #sorted==0 then return end
            DownloadedFanficsMenu:show(self.fanfic.ui,owner,function(work) self.fanfic:UpdateFanfic(work) end,self.fanfic,works)
        end}
        if not complete then rows[#rows+1]={text=_("Stop scanning"),callback=function()
            cancelled=true;complete=true;render()
        end} end
        for _,work in ipairs(sorted) do
            rows[#rows+1]={text=(work.title or work.path).." — "..(work.author or ""),callback=function()
                self.fanfic:onOpenFanficReader(work.path,work)
            end}
        end
        if owner.item_table==rows then owner:updateItems();UIManager:setDirty(owner,"ui") end
    end
    render()
    owner:GoDownInMenu(_("Downloaded Works"),rows)
    local roots={Config:readSetting("fanfic_folder_path"),filemanagerutil.getHomeFolder()}
    require("fanfic_library").scan(roots,function(found,err)
        if invalid() then return end
        replace(found);complete=true;render()
        if err then UIManager:show(InfoMessage:new{text=_("Could not finish the library scan: ")..err}) end
    end,invalid,{progress=function(found)
        replace(found)
        render()
    end})
end

function FanficMenu:onSelectUserSearch()
    local function refreshMenu()
        local users = Config:readSetting("bookmarkedUsers", {})


        -- Show the matching fandoms in a menu
        local menu_items = {}


        table.insert(menu_items, {
            text = "\u{f002} " .. _("Search for user"),
            callback = function()
                self:onSearchUser()
            end,
        })

        for __, user in ipairs(users) do
            local displayText = T("★ %1", user)
            table.insert(menu_items, {
                text = displayText,
                callback = function()
                    local dialog = nil
                    dialog = ButtonDialog:new({
                        title = displayText,
                        buttons = {
                            {
                                {
                                    text = _("View user profile"),
                                    callback = function()
                                        local username, pseud
                                        if string.find(user, "%(") and string.find(user, "%)") then
                                            username = string.match(user, "%((.-)%)")
                                            pseud = string.match(user, "^(.-)%s*%(")
                                        else
                                            username = user
                                            pseud = user
                                        end
                                        self.fanfic:showUserInfo(username, pseud, self.menuWidget)
                                        UIManager:close(dialog)
                                    end,
                                },
                                {
                                    text = _("Unbookmark User"),
                                    callback = function()
                                        -- Remove the fandom from bookmarks
                                        for i, v in ipairs(users) do
                                            if v == user then
                                                table.remove(users, i)
                                                break
                                            end
                                        end
                                        Config:saveSetting("bookmarkedUsers", users)
                                        UIManager:show(InfoMessage:new({
                                            text = T("User: '%1' has been removed from your bookmarks.", user),
                                        }))
                                        UIManager:close(dialog)
                                        self.menuWidget.item_table = refreshMenu() -- Refresh the menu to update the star
                                        self.menuWidget:updateItems()
                                    end,
                                },
                            },
                        },

                    })
                    UIManager:show(dialog)
                end,
            })
        end

        return menu_items
    end

    self.menuWidget:GoDownInMenu("Bookmarked Users", refreshMenu())

end


function FanficMenu:onSearchUser()
    local search_dialog
    search_dialog = InputDialog:new({
        title = _("Search for user on AO3"),
        input = "",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Close"),
                    id = "close",
                    callback = function()
                        UIManager:close(search_dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = Network.wrap(function()
                        local user_query = search_dialog:getInputText()
                        local success, users, next_page = self.fanfic:searchForUsers(user_query)
                        if not success then
                            return
                        end
                        UIManager:close(search_dialog)
                        local function generateMenuItems()
                            local menu_items = {}
                            for __, user in ipairs(users) do
                                table.insert(menu_items, {
                                    text = T("%1 (%2) | (%3 works) (%4 bookmarks)",user.pseud, user.username, tostring(user.works_count), tostring(user.bookmarks_count)),
                                    callback = function()
                                        local dialog
                                        dialog = ButtonDialog:new({
                                            buttons = {
                                                {
                                                    {
                                                        text = _("View user profile"),
                                                        callback = function()
                                                            self.fanfic:showUserInfo(user.username, user.pseud, self.menuWidget)
                                                            UIManager:close(dialog)
                                                        end,
                                                    },
                                                },
                                                {
                                                    {
                                                        text = _("Bookmark User"),
                                                        callback = function()
                                                            local users = Config:readSetting("bookmarkedUsers", {})
                                                            if not util.contains(users, user.username) then
                                                                table.insert(users, user.username)
                                                                Config:saveSetting("bookmarkedUsers", users)
                                                                UIManager:show(InfoMessage:new({
                                                                    text = T("User: '%1' has been added to your bookmarks.", user.username),
                                                                }))
                                                            else
                                                                UIManager:show(InfoMessage:new({
                                                                    text = T("User: '%1' is already in your bookmarks.", user.username),
                                                                }))
                                                            end
                                                            UIManager:close(dialog)
                                                        end,
                                                    },
                                                },
                                            },
                                        })
                                        UIManager:show(dialog)
                                    end,
                                })
                            end
                            return menu_items
                        end
                        self.menuWidget:GoDownInMenu(T('"%1" user search results', user_query), generateMenuItems())
                    end),
                },
            }
        }
    })

    UIManager:show(search_dialog)
    search_dialog:onShowKeyboard()
end

function FanficMenu:onSelectAccountHistory(marked_for_later)
    if Network.defer(function() self:onSelectAccountHistory(marked_for_later) end) then return end
    Network.schedule(0, function()
        local success, ficResults, fetchNextPage = self.fanfic:getWorksFromAccountHistory(marked_for_later)
        if not success then
            return
        end

        self.fanfic:onShowFanficBrowser(
            ficResults,
            fetchNextPage
        )
    end)
end

function FanficMenu:onOpenSettings()
    local function checkFilenameTemplate(template)
        if util.trim(template) == "" then return false, "Filename template cannot be empty" end
        if template:find('[\\/:*?"<>|]') then return false, "Filename template cannot contain path separators or reserved filename characters" end
        if template:find("[%.%s]+$") then return false, "Filename template cannot end with a dot or whitespace" end
        for token in template:gmatch("%%(.)") do
            if token ~= "I" and token ~= "T" and token ~= "A" then return false, "Use %I, %T, or %A in the filename template" end
        end
        return true
    end

    local settings_options = {
        { text = "AO3 URL",                 setting = "AO3_domain",         type = "String"},
        { text = "Show adult work warning", setting = "show_adult_warning", type = "Bool" },
        { text = "Download layout", setting = "author_folders", type = "Bool", on = "Author/Title", off = "Flat (filename template)" },
        { text = "Flat filename template", description = "%I = id, %T = title, %A = author", setting = "filename_template", type = "String", check = checkFilenameTemplate },
        { text = "Fanfic folder",   setting = "fanfic_folder_path",  type = "Folder"},
        { text = "Organize downloaded works…", type = "Action", call_function = function()
            require("fanfic_organizer_ui").show(self.fanfic)
        end },
        { text = "Chapter progress format", setting = "show_current_chapter", type = "Bool", on="First Unread", off="Total Remaining"},
    }
    local function generateMenuItems()
        local settings_menu_items = {}

        for __, setting in ipairs(settings_options) do
            local menu_item
            if setting.type == "String" then
                menu_item = {
                    text = setting.text .. ": " .. Config:readSetting(setting.setting, nil),
                    callback = function()
                        -- Show an input dialog to update the setting
                        local inputDialog
                        inputDialog = InputDialog:new({
                            title = setting.description or T("Set value for '%1'", setting.text),
                            input = Config:readSetting(setting.setting),
                            input_type = "text",
                            buttons = {
                                {
                                    {
                                        text = _("Cancel"),
                                        callback = function()
                                            UIManager:close(inputDialog)
                                        end,
                                    },
                                    {
                                        text = _("Save"),
                                        is_enter_default = true,
                                        callback = function()
                                            local newValue = inputDialog:getInputText()
                                            if setting.check then
                                                local check_result, message = setting.check(newValue)

                                                if not check_result then
                                                    UIManager:show(InfoMessage:new({
                                                        text = message
                                                    }))
                                                    return
                                                end
                                            end
                                            Config:saveSetting(setting.setting, newValue)
                                            UIManager:close(inputDialog)
                                            self.menuWidget:switchItemTable(nil, generateMenuItems())
                                            self.menuWidget:updateItems()
                                            UIManager:show(InfoMessage:new({
                                                text = T("'%1' updated successfully.", setting.text),
                                            }))
                                        end,
                                    },
                                },
                            },
                        })
                        UIManager:show(inputDialog)
                        inputDialog:onShowKeyboard()
                    end,
                }
            elseif setting.type == "Bool" then
                menu_item = {
                    text = setting.text .. ": " .. (Config:readSetting(setting.setting) and (setting.on or "On") or (setting.off or "Off")),
                    callback = function()
                        -- Show an input dialog to update the setting
                        local buttonDialog
                        buttonDialog = ButtonDialog:new({
                            buttons = {
                                {
                                    {
                                        text = (setting.on or "On"),
                                        callback = function()
                                            Config:saveSetting(setting.setting, true)
                                            UIManager:close(buttonDialog)
                                            self.menuWidget:switchItemTable(nil, generateMenuItems())
                                            self.menuWidget:updateItems()
                                            UIManager:show(InfoMessage:new({
                                                text = T("'%1' updated successfully.", setting.text),
                                            }))
                                        end,
                                    },
                                },
                                {
                                    {
                                        text = (setting.off or "Off"),
                                        is_enter_default = true,
                                        callback = function()
                                            Config:saveSetting(setting.setting, false)
                                            UIManager:close(buttonDialog)
                                            self.menuWidget:switchItemTable(nil, generateMenuItems())
                                            self.menuWidget:updateItems()
                                            UIManager:show(InfoMessage:new({
                                                text = T("'%1' updated successfully.", setting.text),
                                            }))
                                        end,
                                    },
                                },
                            },
                        })
                        UIManager:show(buttonDialog)
                    end,
                }
            elseif setting.type == "Folder" then
                menu_item = {
                    text = setting.text .. ": " .. (Config:readSetting(setting.setting) or ""),
                    callback = function()
                        local title_header = T("Current %1:", setting.text)
                        local current_path = Config:readSetting(setting.setting)
                        local default_path = filemanagerutil.getDefaultDir()
                        local caller_callback = function(path)
                            Config:saveSetting(setting.setting, path);
                            menu_item.text = setting.text .. ": " .. (Config:readSetting(setting.setting) or "")
                            self.menuWidget:switchItemTable(nil, generateMenuItems())
                            self.menuWidget:updateItems()
                        end
                        filemanagerutil.showChooseDialog(title_header, caller_callback, current_path, default_path)
                    end
                }
            elseif setting.type == "Action" then
                menu_item = { text = setting.text, callback = setting.call_function }

            end
            table.insert(settings_menu_items, menu_item)
        end
        return settings_menu_items
    end

    self.menuWidget:GoDownInMenu("Settings", generateMenuItems())
end

return FanficMenu
