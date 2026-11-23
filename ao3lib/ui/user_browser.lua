local Network = require("ao3lib.ao3.network")

local KeyValuePage = require("ui/widget/keyvaluepage")
local UIManager = require("ui/uimanager")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local logger = require("logger")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")

local AO3UserBrowser = {
    Fanfic = nil,
    userData = nil,
    uiManager = nil,
    menu = nil,
    menu_layers = {},
}

local UserWindow = KeyValuePage:extend{
    title = "",
    kv_pairs = {},
}

-- Series lists use the same readable font with less vertical padding.
-- Profile and collection pages retain KOReader's normal row spacing.
function UserWindow:_populateItems()
    if self._ao3_compact and not self._ao3_compact_applied and self.item_height then
        local height=self.item_height*self.items_per_page
        local minimum=math.ceil((self.items_font_size or 18)*1.6)
        local row_height=math.max(minimum,math.floor(self.item_height*.75))
        self.items_per_page=math.max(self.items_per_page,math.floor(height/row_height))
        self.item_height=math.floor(height/self.items_per_page)
        self.pages=math.ceil(#self.kv_pairs/self.items_per_page)
        self._ao3_compact_applied=true
    end
    return KeyValuePage._populateItems(self)
end

function AO3UserBrowser:GoDownInMenu(new_title, new_keypairs)
    local current_state = {
        title = self.AO3UserWindow.title,
        kv_pairs = self.AO3UserWindow.kv_pairs,
        show_page = self.AO3UserWindow.show_page,
    }
    table.insert(self.menu_layers, current_state)

    self:loadPage(new_title, new_keypairs)
end

function AO3UserBrowser:GoUpInMenu()
    local previousState = self.menu_layers[#self.menu_layers]
    self.menu_layers[#self.menu_layers] = nil
    if previousState then
        self:loadPage(previousState.title, previousState.kv_pairs, false, previousState.show_page)
    end
end


function AO3UserBrowser:show(userData, ui, fanfic)
    local session = setmetatable({userData=userData, ui=ui, Fanfic=fanfic, menu_layers={}},
        {__index=AO3UserBrowser})
    session:reloadProfile()
    return session

end

function AO3UserBrowser:generateMenuTable()
    local kv_pairs = {}

    local bookmarks=require('ao3lib.users.bookmarks')
    local user_display_name = (self.userData.username == self.userData.pseud and self.userData.username or self.userData.pseud .. " (" .. self.userData.username .. ")")
    local bookmark_user_item = {
        bookmarks.contains(self.userData.username) and "★ Remove user from bookmarks" or "☆ Bookmark user",
        "",
        callback = function()
            require('ao3lib.ui.user_actions').toggle(self.userData,function() self:reloadProfile() end)
        end,
        separator = true,
    }

    table.insert(kv_pairs, bookmark_user_item)
    table.insert(kv_pairs, {_("Manage author subscription"), "", callback=Network.wrap(function()
        require("ao3lib.ui.subscriptions").manage(self.Fanfic,"User",self.userData.username,user_display_name)
    end)})

    table.insert(kv_pairs, {_("Manage AO3 mute"), "", callback=Network.wrap(function()
        local result=require('ao3lib.ao3.client'):getMutedUsers()
        if not result.success then UIManager:show(InfoMessage:new{text=result.error});return end
        local muted=false
        for _,entry in ipairs(result.users) do
            if entry.name:lower()==self.userData.username:lower() then muted=true;break end
        end
        require('ao3lib.ao3.mute_cache').remember(result)
        require('ao3lib.ui.muted_users').change(self.userData.username,not muted,function() self:reloadProfile() end)
    end)})

    local pseuds_item = {
        "Other Pseuds:",
        self.userData.total_pseuds,
        callback = function()
            self:openPseudsList()
        end,
        separator = true,
    }

    table.insert(kv_pairs, pseuds_item)

    local all_works_item = {
        "Works:",
        self.userData.total_works,
        callback = function()
            self:openFanficBrowserForCategory("works", nil)
        end,
    }

    table.insert(kv_pairs, all_works_item)

    local series_item = {
        "Series:",
        self.userData.total_series,
        callback = function()
            self:openUserSeriesList()
        end,
    }

    table.insert(kv_pairs, series_item)

    local bookmarks_item = {
        "Bookmarked works:",
        self.userData.total_bookmarks,
        callback = function()
            self:openFanficBrowserForCategory("bookmarks", self.userData.total_bookmarks, nil)
        end,
    }

    table.insert(kv_pairs, bookmarks_item)

    local collections_item = {
        "Collections:",
        self.userData.total_collections,
        callback = function()
            self:openUserCollectionsList()
        end,
    }

    table.insert(kv_pairs, collections_item)

    local gifts_item = {
        "Gifted works:",
        self.userData.total_gifts,
        callback = function()
            self:openFanficBrowserForCategory("gifts", self.userData.total_gifts, nil)
        end,
        separator = true,
    }

    table.insert(kv_pairs, gifts_item)

    local fandom_title_item = {
        "Works by fandom:",
        "",
        separator = true,

    }

    table.insert(kv_pairs, fandom_title_item)

    for __, fandom in pairs(self.userData.fandoms) do
        local fandom_item = {
            T("(%1) %2", fandom.count, fandom.name),
            "",
            callback = function()
                self:openFanficBrowserForCategory("works", fandom.count, fandom.id)
            end
        }
        table.insert(kv_pairs, fandom_item)
    end


    return kv_pairs
end

function AO3UserBrowser:reloadProfile()
    local author_string
    self.menu_layers = {}

    if self.userData.pseud ~= self.userData.username then
        author_string = T("%1 (%2)", self.userData.pseud, self.userData.username)
    else
        author_string = self.userData.username
    end

    local new_menu_table = self:generateMenuTable()
    self:loadPage(author_string, new_menu_table)
end

function AO3UserBrowser:loadPage(title, menu_table, keeping_current_page, restored_page)
    local set_page = restored_page or 1
    if keeping_current_page and self.AO3UserWindow then
        set_page = self.AO3UserWindow.show_page
    end
    local previous = self.AO3UserWindow

    self.AO3UserWindow = UserWindow:new({
        title = title,
        kv_pairs = menu_table,
        _ao3_compact = menu_table._ao3_compact,
        title_bar_left_icon = require("ao3lib.ui.icons").name,
        title_bar_fm_style = true,
        is_popout = false,
        is_borderless = true,
        show_page = set_page,
    })
    require("ao3lib.ui.navigation").bind(self.Fanfic, self.AO3UserWindow, {
        replace=previous,
        back=function()
            if #self.menu_layers > 0 then self:GoUpInMenu(); return true end
            return false
        end,
    })
    UIManager:show(self.AO3UserWindow)
    if previous then UIManager:close(previous) end
end

function AO3UserBrowser:openFanficBrowserForCategory(category, total, fandom_id)
    if Network.defer(function() self:openFanficBrowserForCategory(category, total, fandom_id) end) then return end
    local success, works, getNextPage = self.Fanfic:getWorksFromUserPage(self.userData.username, self.userData.pseud, category, fandom_id)
    if success then
        works.total =  works.total or total or 0
        self.Fanfic:onShowFanficBrowser(works, getNextPage)
    end
end

function AO3UserBrowser:openUserSeriesList()
    if Network.defer(function() self:openUserSeriesList() end) then return end
    local success, seriesList, getNextPage = self.Fanfic:getSeriesFromUserPage(self.userData.username, self.userData.pseud)  --
    if success then
        local series_menu_kv = {}

        local function insert_back_to_profile_item()
            table.insert(series_menu_kv, 1, {
                "← Back to profile",
                "",
                separator = true,
                callback = function()
                    self:GoUpInMenu()
                end,
            })
        end

        local function add_series_to_menu(series)
            table.insert(series_menu_kv, {
                series.title,
                "",
                callback = Network.wrap(function()
                    require("ao3lib.ui.subscriptions").openSeries(self.Fanfic,series.id,series.title,series.work_count)
                end),
                hold_callback = function()
                    require("ao3lib.ui.subscriptions").manage(self.Fanfic,'Series',series.id,series.title)
                end,
                separator = true,
            })
            table.insert(series_menu_kv,{
                "Fandoms:"
                , table.concat(series.fandoms, ", "),
            })
            table.insert(series_menu_kv,{
                _("Stats:"), T(_("%1 works · %2 words"),series.work_count or 0,series.word_count or 0),
            })
            table.insert(series_menu_kv,{
                "Author:"
                , series.author,
            })
            table.insert(series_menu_kv,{
                "Date:"
                , series.date_posted,
            })
            if series.summary and series.summary ~= "" then
                table.insert(series_menu_kv,{
                    "Summary:"
                    , series.summary,
                })
            end
        end

        local function refreshSeriesMenu()
            series_menu_kv = {_ao3_compact=true}
            insert_back_to_profile_item()

            for __, series in pairs(seriesList) do
                add_series_to_menu(series)
                series_menu_kv[#series_menu_kv].separator = true
            end

            table.insert(series_menu_kv, {
                "Load more series...",
                "",
                callback = Network.wrap(function()
                    local extra_series_list = getNextPage()

                    if #extra_series_list > 0 then
                        for __, series in pairs(extra_series_list) do
                            table.insert(seriesList, series)
                        end

                        refreshSeriesMenu()
                        self:loadPage("Series", series_menu_kv, true)


                    end
                end),
            })
        end

        refreshSeriesMenu()


        self:GoDownInMenu("Series", series_menu_kv)
    end
end

function AO3UserBrowser:openUserCollectionsList()
    if Network.defer(function() self:openUserCollectionsList() end) then return end
    local success, collectionsList, getNextPage = self.Fanfic:getCollectionsFromUserPage(self.userData.username)  --
    if success then
        local collections_menu_kv = {}

        local function insert_back_to_profile_item()
            table.insert(collections_menu_kv, 1, {
                "← Back to profile",
                "",
                separator = true,
                callback = function()
                    self:GoUpInMenu()
                end,
            })
        end

        local function add_collection_to_menu(collection)
            table.insert(collections_menu_kv, {
                collection.title,
                "",
                callback = Network.wrap(function()
                    local success, collectionWorks, fetchNextPage = self.Fanfic:getWorksFromCollection(collection.id)
                    if success == false then
                        return
                    end

                    collectionWorks.total = collection.work_count or 0
                    self.Fanfic:onShowFanficBrowser(collectionWorks, fetchNextPage)
                end),
                separator = true,
            })
            table.insert(collections_menu_kv,{
                "Tags:"
                , table.concat(collection.tags, ", "),
            })
            table.insert(collections_menu_kv,{
                "Work count:"
                , collection.work_count,
            })
            table.insert(collections_menu_kv,{
                "Author:"
                , collection.author,
            })
            table.insert(collections_menu_kv,{
                "Date:"
                , collection.date_posted,
            })
            if collection.summary and collection.summary ~= "" then
                table.insert(collections_menu_kv,{
                    "Summary:"
                    , collection.summary,
                })
            end
        end

        local function refreshCollectionsMenu()
            collections_menu_kv = {}
            insert_back_to_profile_item()

            for __, collection in pairs(collectionsList) do
                add_collection_to_menu(collection)
                collections_menu_kv[#collections_menu_kv].separator = true
            end

            table.insert(collections_menu_kv, {
                "Load more collections...",
                "",
                callback = Network.wrap(function()
                    local extra_collections_list = getNextPage()

                    if #extra_collections_list > 0 then
                        for __, collection in pairs(extra_collections_list) do
                            table.insert(collectionsList, collection)
                        end

                        refreshCollectionsMenu()
                        self:loadPage("Collections", collections_menu_kv, true)
                    end
                end),
            })
        end

        refreshCollectionsMenu()
        self:GoDownInMenu("Collections", collections_menu_kv)
    end
end

function AO3UserBrowser:openPseudsList()
    if Network.defer(function() self:openPseudsList() end) then return end
    local success, pseuds = self.Fanfic:getPseudsForUser(self.userData.username)
    if success then
        local pseuds_menu_kv = {}

        table.insert(pseuds_menu_kv, {
            "← Back to profile",
            "",
            separator = true,
            callback = function()
                self:GoUpInMenu()
            end,
        })

        for __, pseud in pairs(pseuds) do
            table.insert(pseuds_menu_kv, {
                T("%1 (%2 works) (%3 recs)", pseud.name, pseud.works_count, pseud.recs_count),
                "",
                callback = Network.wrap(function()
                    local success, userData = self.Fanfic:getUserData(self.userData.username, pseud.name)
                    if success then
                        self:show(userData, self.ui, self.Fanfic)
                    else
                        UIManager:show(InfoMessage:new({
                            text = T("Failed to fetch data for pseud: '%1'", pseud.name),
                        }))
                    end
                end),
            })

        end

        pseuds_menu_kv[#pseuds_menu_kv].separator = true


        self:GoDownInMenu("Other Pseuds", pseuds_menu_kv)
    else
        UIManager:show(InfoMessage:new({
            text = T("Failed to fetch pseuds for user: '%1'", self.userData.username),
        }))
    end
end

return AO3UserBrowser
