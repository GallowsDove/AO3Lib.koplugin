local Network = require("ao3lib.ao3.network")
local Menu = require("ui/widget/menu")
local _ = require("gettext")
local FanficSearch = require("ao3lib.ui.search")
local FanficBrowser = require("ao3lib.ui.work_browser")
local Config = require("ao3lib.core.config")
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local util = require("util")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local logger = require("logger")
local CustomFilterMenu = require("ao3lib.ui.search_filters_menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local DownloadedFanfics = require("ao3lib.library.history")

function util.contains(table, value)
    for _, v in ipairs(table) do
        if v == value then
            return true
        end
    end
    return false
end

local FanficMenuWidget = Menu:extend(require("ao3lib.ui.widgets").menu{
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
    self.lock_return = false
    local path = self.paths[#self.paths]
    if path then
        if path.onReturn then pcall(path.onReturn) end
        self:switchItemTable(path.title, path.items, -1, -1, path.subtitle)
        self.title = path.title
        self.subtitle = path.subtitle
        table.remove(self.paths, #self.paths)
        if path.page then self.page = path.page; self:updateItems() end
        require("ao3lib.ui.navigation").update(self)
        return true
    end
    return false
end

function FanficMenuWidget:GoDownInMenu(newTitle, newItems, newSubtitle)
    table.insert(self.paths, {
        title = self.title,
        items = self.item_table,
        subtitle = self.subtitle,
        page = self.page,
    })
    self:switchItemTable(newTitle, newItems, -1, -1, newSubtitle)
    self.title = newTitle
    self.subtitle = newSubtitle
    require("ao3lib.ui.navigation").update(self)
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
        title_bar_left_icon = require("ao3lib.ui.icons").name,
        item_table = {
            {
                text = "\u{f002} Search and download works from AO3",
                callback = function()
                    self:onSearchFanficMenu()
                end,
            },
            {
                text = "\u{2193} View downloaded works",
                callback = function()
                    self:onViewDownloadedFanfics()
                end,
            },
            {
                text = "\u{21bb} " .. _("Review downloaded work updates"),
                callback = function()
                    require("ao3lib.ui.update_review").show(self.fanfic)
                end,
            },
            {
                text = "\u{f007} " .. _("Account management"),
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

    local window = self.menuWidget
    require("ao3lib.ui.navigation").bind(fanfic, window, {
        root=function() return #(window.paths or {}) == 0 end,
        back=function() return window:onReturn() end,
        resume=function()
            if not self.refreshBookmarkedUsers then return end
            local title=_("Bookmarked Users")
            if window.title==title then
                window.item_table=self.refreshBookmarkedUsers();window:updateItems()
            end
            for __,path in ipairs(window.paths or {}) do
                if path.title==title then path.items=self.refreshBookmarkedUsers() end
            end
        end,
    })

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
    local remember
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
                        local logged_in = self.fanfic:loginToAO3(myfields[1], myfields[2], remember.checked)
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
    remember = require("ui/widget/checkbutton"):new{ text="Keep me signed in", checked=true, parent=self.login_dialog }
    self.login_dialog:addWidget(remember)
    UIManager:show(self.login_dialog)
    self.login_dialog:onShowKeyboard()
end

function FanficMenu:searchWorksRows()
    local widget=self.menuWidget
    local filters=require("ao3lib.ui.saved_searches").saved(Config)
    local rows={{text=_("New search"),callback=function()
        CustomFilterMenu.menuWidget=widget
        CustomFilterMenu.fanfic=self.fanfic
        CustomFilterMenu:FilterCrafter()
    end},{text=_("Saved filters:"),enabled=false}}
    for __,entry in ipairs(require("ao3lib.ui.saved_searches").sorted(filters)) do
        local key,saved_filter=entry.key,entry.filter
        rows[#rows+1]={text="     "..(saved_filter.title or tostring(key)),callback=function()
            local options
            options=ButtonDialog:new{buttons={{
                {text=_("Search using filter"),callback=function()
                    CustomFilterMenu.menuWidget=widget
                    CustomFilterMenu.fanfic=self.fanfic
                    CustomFilterMenu.filter=require("ao3lib.core.table").deepCopy(saved_filter.parameters)
                    CustomFilterMenu:executeSearch();UIManager:close(options)
                end},
            },{
                {text=_("Edit filter"),callback=function()
                    CustomFilterMenu.menuWidget=widget
                    CustomFilterMenu.fanfic=self.fanfic
                    CustomFilterMenu:UpdateFilterCrafter(saved_filter);UIManager:close(options)
                end},
            },{
                {text=_("Delete filter"),callback=function()
                    filters[key]=nil;Config:saveSetting("saved_filters",filters)
                    widget.item_table=self:searchWorksRows();widget:updateItems();UIManager:close(options)
                end},
            },{
                {text=_("Cancel"),callback=function() UIManager:close(options) end},
            }}}
            UIManager:show(options)
        end}
    end
    return rows
end

function FanficMenu:onSearchFanficMenu()
    local widget=self.menuWidget
    -- Saved-filter actions can open the editor without going through the
    -- "New search" callback, so bind the filter menu as soon as this route
    -- is entered.
    CustomFilterMenu.menuWidget=widget
    CustomFilterMenu.fanfic=self.fanfic
    widget:GoDownInMenu(_("Search"),{{text=_("Search works"),callback=function()
        CustomFilterMenu.menuWidget=widget
        CustomFilterMenu.fanfic=self.fanfic
        CustomFilterMenu.refreshSearchRows=function() return self:searchWorksRows() end
        widget:GoDownInMenu(_("Search works"),self:searchWorksRows())
    end},
    {text=_("Search work by ID"),callback=function() self:onShowFanficSearch() end},
    {text=_("Search for users"),callback=function() self:onSelectUserSearch() end},
    {text=_("Browse Account History"),callback=function() self:onSelectAccountHistory(false) end},
    {text=_("Browse Account Marked for Later"),callback=function() self:onSelectAccountHistory(true) end},
    {text=_("Browse Account Subscriptions"),callback=Network.wrap(function()
        require("ao3lib.ui.subscriptions").show(self.fanfic)
    end)}})
end

function FanficMenu:onShowFanficSearch()
    FanficSearch:show(function(fanficId)
        local result = require("ao3lib.ao3.client"):getWorkMetadata(fanficId)
        if not result.success then
            UIManager:show(InfoMessage:new{
                text = _("Error: failed to fetch work metadata: ") .. (result.error or _("Unknown error")),
            })
            return false
        end
        local work = result.work_metadata
        work.id = fanficId
        self.fanfic:onShowFanficBrowser({work, total=1}, nil, _("AO3 work details"))
        return true
    end)
end

-- Reuse the last discovered library within this KOReader session. The EPUB
-- cache supplies the initial snapshot in a worker on a cold start.
function FanficMenu:onViewDownloadedFanfics()
    return require("ao3lib.ui.downloaded_works").show(self.fanfic)
end

function FanficMenu:onSelectUserSearch()
    local function refreshMenu()
        local rows={{text="\u{f002} ".._("Search for user"),callback=function() self:onSearchUser() end}}
        for __,user in ipairs(require('ao3lib.users.bookmarks').list()) do
            rows[#rows+1]=require('ao3lib.ui.user_actions').row(user,self,"★ "..user.display,function()
                self.menuWidget.item_table=refreshMenu();self.menuWidget:updateItems()
            end)
        end
        return rows
    end
    self.refreshBookmarkedUsers=refreshMenu
    self.menuWidget:GoDownInMenu(_("Bookmarked Users"),refreshMenu())
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
                                local label=T("%1 (%2) | (%3 works) (%4 bookmarks)",user.pseud,user.username,
                                    tostring(user.works_count),tostring(user.bookmarks_count))
                                menu_items[#menu_items+1]=require('ao3lib.ui.user_actions').row(user,self,label,function()
                                    -- The bookmarked-users screen sits directly behind search results.
                                    local paths=self.menuWidget.paths
                                    if self.refreshBookmarkedUsers and paths then
                                        for __,path in ipairs(paths) do
                                            if path.title==_("Bookmarked Users") then path.items=self.refreshBookmarkedUsers() end
                                        end
                                    end
                                    self.menuWidget:updateItems()
                                end)
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

    return require("ao3lib.ui.settings").show(self,checkFilenameTemplate)
end

return FanficMenu
