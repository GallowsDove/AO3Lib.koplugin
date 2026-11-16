local Network = require("fanfic_network")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local logger = require("logger")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local BD = require("ui/bidi")
local DownloadedFanfics = require("downloaded_fanfics")
local FanficBrowser = require("fanficbrowser")
local FanficMenu = require("fanfic_menu")
local FanficReader = require("fanfic_reader")
local Config = require("fanfic_config")
local Event = require("ui/event")
local Dispatcher = require("dispatcher")
local AO3DownloaderClient = require("AO3_downloader_client")
local util = require("util")

local Fanfic = WidgetContainer:extend{
    name = "AO3 downloader",
    is_doc_only = false,
    menu_stack = {}
}

function Fanfic:init()
    require("fanfic_icons").install()
    DownloadedFanfics.load() -- Reader activation needs saved chapter progress.
    if self.ui.name == "ReaderUI" then
        FanficReader:initializeFromReaderUI(self.ui)
    else
        self.ui.menu:registerToMainMenu(self)
    end

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    -- Optional integration is owned entirely by this plugin. Bookshelf's
    -- existing tables are extended once, after enabled plugin paths are ready.
    local integrated, integration_err = pcall(function()
        require("fanfic_bookshelf_integration").install()
    end)
    if not integrated then logger.warn("AO3 Bookshelf integration:", integration_err) end
    -- FileManager builds file_chooser after loading plugins. Register against
    -- its API now, rather than waiting for a widget that does not exist yet.
    if type(self.ui.addFileDialogButtons) == "function" then
        self:registerWorkDetailsAction()
    end
end

function Fanfic:onSuspend()
    return self:onFlushSettings()
end

function Fanfic:onFlushSettings()
    local ok, err = DownloadedFanfics.flushPending()
    if not ok then logger.warn("Could not save pending AO3 progress:", err) end
end

function Fanfic:registerWorkDetailsAction()
    self.ui:addFileDialogButtons("ao3_work_details", function(file, is_file)
        if not is_file then return end
        local epub = require("fanfic_epub").read(file)
        if not epub then return end
        local work = DownloadedFanfics.rememberLocal(epub)
        return {{
            text = _("Open AO3 work"),
            callback = function()
                -- Bookshelf also hosts this hook, with its book popup underneath.
                if self.ui.file_dialog then UIManager:close(self.ui.file_dialog) end
                -- The EPUB supplies details even without download history.
                self:onShowFanficBrowser({ work, total = 1 }, nil,
                    _("AO3 work details"))
            end,
        }}
    end)
end

function Fanfic:addToMainMenu(menu_items)
    if self.ui.file_chooser then
        menu_items.AO3_downloader = {
            text = "AO3Lib",
            sorting_hint = "search",
            callback = function()
                self.ui:handleEvent(Event:new("OpenAO3DownloaderMenu"))
            end,
        }
    end
end


function Fanfic:onDispatcherRegisterActions()
    Dispatcher:registerAction("AO3Downloader_openPluginMenu", {
        category = "none",
        event = "OpenAO3DownloaderMenu",
        title = _("AO3Lib: open menu"),
        general = true,
    })

end
function Fanfic:onOpenAO3DownloaderMenu()
    if not self.ui.file_chooser then
        self.ui:handleEvent(Event:new("Home"))
    end

    self.menu = FanficMenu:show(self)
    UIManager:show(self.menu)
end

function Fanfic:onOpenFanficReader(fanfic_path, current_fanfic, start_chapter)
    self:closeAllMenus()
    FanficReader:show({
        fanfic_path = fanfic_path,
        current_fanfic = current_fanfic,
        chapter_opening_at = start_chapter,
    })
end

function Fanfic:closeAllMenus()
    for menu_widget, _ in pairs(self.menu_stack) do
        if menu_widget then
            UIManager:close(menu_widget)
        end
    end
    self.menu_stack = {}
end

function Fanfic.GenerateFileName(metadata)
    return require("fanfic_layout").filename(metadata, Config:readSetting("filename_template", "%I"))
end

function Fanfic:onShowFanficBrowser(ficResults, fetchNextPage, title)
    logger.dbg("AO3Downloader.koplugin: Showing fanfic browser")
    FanficBrowser:show(
        self.ui,
        ficResults,
        fetchNextPage,
        function(fanfic) self:UpdateFanfic(fanfic) end, -- Update callback
        function(fanficId) self:DownloadFanfic(fanficId) end, -- Download callback
        function (author)
            -- Check if author contains pseud, if yes parse the pseud (format: "pseeud (username)" or username)
            local username
            local pseud

            if string.find(author, "%(") and string.find(author, "%)") then
                username = string.match(author, "%((.-)%)")
                pseud = string.match(author, "^(.-)%s*%(")
            else
                username = author
                pseud = author
            end
            logger.dbg("Opening user browser for author: " .. username .. " pseud: " .. pseud)
            self:showUserInfo(username, pseud)

        end,-- Open author user browser callback
        self,
        title
    )

end

function Fanfic:DownloadFanfic(id)
    if Network.defer(function() self:DownloadFanfic(id) end) then return end

    local existing = DownloadedFanfics.checkIfStored(id)
    if existing then self:UpdateFanfic(existing); return end

    -- Fetch metadata for the work
    local request_result  = AO3DownloaderClient:getWorkMetadata(id)
    if not request_result.success then
        UIManager:show(InfoMessage:new{
            text = _("Error: failed to fetch work metadata: ") .. (request_result.error or "Unknown error")
        })
        return
    end

    -- Extract the EPUB link from the metadata
    local url = request_result.work_metadata.epub_link
    if not url then
        UIManager:show(InfoMessage:new{
            text = _("Error: EPUB link not found for this work")
        })
        return
    end

    os.execute("sleep " .. math.random(1, 3))

    local destination, path_err = require("fanfic_layout").destination(request_result.work_metadata, Config:readSetting("fanfic_folder_path"))
    if not destination then UIManager:show(InfoMessage:new{text=path_err}); return end
    local made, mkdir_err = util.makePath(destination:match("^(.*)/[^/]+$"))
    if not made then UIManager:show(InfoMessage:new{text=tostring(mkdir_err or "Could not create the author folder")}); return end
    local download_request_result = AO3DownloaderClient:downloadEpub(url, destination, false)
    if not download_request_result.success then
        UIManager:show(InfoMessage:new{
            text = T("Error: failed to download and write EPUB: %1", download_request_result.error or "Unknown error")
        })
        return
    end

    -- Save metadata of the downloaded fanfic
    local fanfic = {
        id = id,
        path = download_request_result.filepath,
        title = request_result.work_metadata.title,
        author = request_result.work_metadata.author,
        chapters = request_result.work_metadata.chapters,
        chapter_data = request_result.work_metadata.chapterData or {},
        summary = request_result.work_metadata.summary,
        fandoms = request_result.work_metadata.fandoms,
        tags = request_result.work_metadata.tags,
        relationships = request_result.work_metadata.relationships,
        characters = request_result.work_metadata.characters,
        warnings = request_result.work_metadata.warnings,
        hits = request_result.work_metadata.hits,
        kudos = request_result.work_metadata.kudos,
        bookmarks = request_result.work_metadata.bookmarks,
        comments = request_result.work_metadata.comments,
        last_accessed = os.date("%Y-%m-%d %H:%M:%S"), --current date
        rating = request_result.work_metadata.rating,
        category = request_result.work_metadata.category,
        iswip = request_result.work_metadata.iswip,
        updated = request_result.work_metadata.updated,
        published = request_result.work_metadata.published,
        wordcount = request_result.work_metadata.wordcount,
        markedForLater = request_result.work_metadata.markedForLater,
        subscriptionID = request_result.work_metadata.subscriptionID,
        bookmarkID = request_result.work_metadata.bookmarkID,
        bookmarkContent = request_result.work_metadata.bookmarkContent
    }

    if fanfic.chapter_data then
        for idx, __ in pairs(fanfic.chapter_data) do
            fanfic.chapter_data[idx].read = false
        end
    end

    DownloadedFanfics.add(fanfic)



    -- Show confirmation dialog
    UIManager:show(ConfirmBox:new{
        text = T(_("File saved to:\n%1\nWould you like to read the downloaded work now?"), BD.filepath(fanfic.path)),
        ok_text = _("Read now"),
        ok_callback = function()
            self:onOpenFanficReader(fanfic.path, fanfic)
        end,
    })
end

function Fanfic:UpdateFanfic(fanfic)
    if Network.defer(function() self:UpdateFanfic(fanfic) end) then return end
    local Updates = require("fanfic_updates")
    local ok, result = pcall(function()
        local entry = Updates.check(fanfic)
        if not entry.remote then return {success=false, error=entry.error} end
        return Updates.apply(entry)
    end)
    if not ok and require("fanfic_background").isCancelled(result) then error(result,0) end
    UIManager:show(InfoMessage:new{
        text = ok and result.success
            and T(_("Fanfic '%1' has been updated successfully."), fanfic.title)
            or T(_("Could not update work: %1"), tostring(ok and result.error or result)),
    })
end

function Fanfic:fetchFanficsByTag(selectedFandom, sortBy)
    -- Data-returning helpers run inside the caller's network-gated UI action.
    local currentPage = 1

    -- Define the function to fetch the next page for the selected fandom
    local function fetchNextPage()
        currentPage = currentPage + 1
        local next_page_results =  AO3DownloaderClient:searchByTag(selectedFandom, sortBy, currentPage)
        if not next_page_results.success then
            currentPage = currentPage - 1
            UIManager:show(InfoMessage:new{
                text = T("Error: %1", next_page_results.error),
                icon = "notice-warning",
            })
            return {}
        end

        return next_page_results.result_works
    end

    -- Fetch the first page of results
    local search_results = AO3DownloaderClient:searchByTag(selectedFandom, sortBy, currentPage)

    if not search_results.success then
        UIManager:show(InfoMessage:new{
            text = T("Error: %1", search_results.error),
            icon = "notice-warning",
        })
        return false
    end

    return true, search_results.result_works, fetchNextPage

end

function Fanfic:getWorksFromAccountHistory(marked_for_later)

    local currentPage = 1

    -- Define the function to fetch the next page for the selected fandom
    local function fetchNextPage()
        currentPage = currentPage + 1
        local next_page_results =  AO3DownloaderClient:getWorksFromAccountHistory(marked_for_later, currentPage)
        if not next_page_results.success then
            currentPage = currentPage - 1
            UIManager:show(InfoMessage:new{
                text = T("Error: %1", next_page_results.error),
                icon = "notice-warning",
            })
            return {}
        end

        return next_page_results.works
    end

    -- Fetch the first page of results
    local search_results = AO3DownloaderClient:getWorksFromAccountHistory(marked_for_later, currentPage)

    if not search_results.success then
        UIManager:show(InfoMessage:new{
            text = T("Error: %1", search_results.error),
            icon = "notice-warning",
        })
        return false
    end

    return true, search_results.works, fetchNextPage

end

function Fanfic:executeSearch(parameters)

    local currentPage = 1

    -- Define the function to fetch the next page for the search parameters
    local function fetchNextPage()
        currentPage = currentPage + 1
        local request_result = AO3DownloaderClient:searchByParameters(parameters, currentPage)

        if not request_result.success then
            UIManager:show(InfoMessage:new{
                text = _("Error: ") .. (request_result.error or "Unknown error"),
            })
            currentPage = currentPage - 1
            return false
        end

        -- no more works to fetch
        if #request_result.works == 0 then
            currentPage = currentPage - 1
            return {}
        end

        return request_result.works
    end

    -- Fetch the first page of results
    local request_result = AO3DownloaderClient:searchByParameters(parameters, currentPage)

    if not request_result.success then
        UIManager:show(InfoMessage:new{
            text = _("Error: ") .. (request_result.error or "Unknown error"),
        })
        return false
    end

    return true, request_result.works, fetchNextPage
end


function Fanfic:searchForUsers(query)
    local search_results = AO3DownloaderClient:searchForUsers(query)
    if not search_results.success then
        UIManager:show(InfoMessage:new{
            text = "Error: User search request failed. " .. (search_results.error or "Unknown error"),
        })
        return false
    end

    logger.dbg(search_results.result_users)

    local current_page = 1

    local function getNextPage()
        current_page = current_page + 1
        local next_page_result = AO3DownloaderClient:searchForUsers(query, current_page)
        if not next_page_result.success then
            current_page = current_page - 1
            UIManager:show(InfoMessage:new{
                text = "Error: User search request failed. " .. (next_page_result.error or "Unknown error"),
            })
            return {}
        end

        -- no more users to fetch
        if #next_page_result.result_users == 0 then
            current_page = current_page - 1
            return {}
        end

        return  next_page_result.result_users
    end

    return true,search_results.result_users, getNextPage
end

function Fanfic:showUserInfo(username, pseud)
    if Network.defer(function() self:showUserInfo(username, pseud) end) then return end
    local AO3UserBrowser = require("AO3_user_browser")
    local request_result = AO3DownloaderClient:getUserData(username, pseud)
    if not request_result.success then
        UIManager:show(InfoMessage:new{
            text = T("Error: Failed to fetch user info: %1", request_result.error or "Unknown error"),
        })
        return
    end
    AO3UserBrowser:show(request_result.user_data, self.ui, self)
end

function Fanfic:getUserData(username, pseud)
    local user_data_result = AO3DownloaderClient:getUserData(username, pseud)
    if not user_data_result.success then
        UIManager:show(InfoMessage:new{
            text = "Error: Failed to fetch user data: " .. (user_data_result.error or "Unknown error"),
        })
        return false
    end

    return true, user_data_result.user_data

end

function Fanfic:getWorksFromUserPage(username, pseud, category, fandom_id)
    local works_result = AO3DownloaderClient:getWorksFromUserPage(username, pseud, category, fandom_id)
    if not works_result.success then
        UIManager:show(InfoMessage:new{
            text = "Error: Failed to fetch works from user page: " .. (works_result.error or "Unknown error"),
        })
        return false
    end

    local currentPage = 1

    local function getNextPage()
        currentPage = currentPage + 1
        local next_page_result = AO3DownloaderClient:getWorksFromUserPage(username, pseud, category, fandom_id, currentPage)
        if not next_page_result.success then
            currentPage = currentPage - 1
            UIManager:show(InfoMessage:new{
                text = "Error: Failed to fetch works from user page: " .. (next_page_result.error or "Unknown error"),
            })
            return {}
        end

        -- no more works to fetch
        if #next_page_result.works == 0 then
            currentPage = currentPage - 1
            return {}
        end

        return  next_page_result.works
    end

    return true, works_result.works, getNextPage

end

function Fanfic:getPseudsForUser(username)
    local pseuds_result = AO3DownloaderClient:getUserPseuds(username)
    if not pseuds_result.success then
        UIManager:show(InfoMessage:new{
            text = "Error: Failed to fetch pseuds for user: " .. (pseuds_result.error or "Unknown error"),
        })
        return false
    end

    return true, pseuds_result.pseuds

end

function Fanfic:getSeriesFromUserPage(username, pseud)


    local current_page = 1

    local series_result = AO3DownloaderClient:getUserSeries(username, pseud, current_page)

    local function getNextPage()
        current_page = current_page + 1
        local next_page_result = AO3DownloaderClient:getUserSeries(username, pseud, current_page)
        if not next_page_result.success then
            current_page = current_page - 1
            UIManager:show(InfoMessage:new{
                text = "Error: Failed to fetch series from users page: " .. (next_page_result.error or "Unknown error"),
            })
            return {}
        end

        -- no more series to fetch
        if #next_page_result.series == 0 then
            current_page = current_page - 1
            return {}
        end

        return  next_page_result.series

    end
    if not series_result.success then
        UIManager:show(InfoMessage:new{
            text = "Error: Failed to fetch series from users page: " .. (series_result.error or "Unknown error"),
        })
        return false
    end

    return true, series_result.series, getNextPage

end

function Fanfic:getCollectionsFromUserPage(username)

    local currentPage = 1

    local works_result = AO3DownloaderClient:getUserCollections(username, currentPage)
    if not works_result.success then
        UIManager:show(InfoMessage:new{
            text = "Error: Failed to fetch collections from users collections page: " .. (works_result.error or "Unknown error"),
        })
        return false
    end


    local function getNextPage()
        currentPage = currentPage + 1
        local next_page_result = AO3DownloaderClient:getUserCollections(username, currentPage)
        if not next_page_result.success then
            currentPage = currentPage - 1
            UIManager:show(InfoMessage:new{
                text = "Error: Failed to fetch collections from users collections page: " .. (next_page_result.error or "Unknown error"),
            })
            return {}
        end

        -- no more works to fetch
        if #next_page_result.collections == 0 then
            currentPage = currentPage - 1
            return {}
        end

        return  next_page_result.collections
    end

    return true, works_result.collections, getNextPage
end

function Fanfic:getWorksFromSeries(series_id)
    local works_result = AO3DownloaderClient:getWorksFromSeries(series_id)
    if not works_result.success then
        UIManager:show(InfoMessage:new{
            text = "Error: Failed to fetch works from series: " .. (works_result.error or "Unknown error"),
        })
        return false
    end

    local currentpage = 1

    local function fetchNextPage()
        currentpage = currentpage + 1
        local next_page_result = AO3DownloaderClient:getWorksFromSeries(series_id, currentpage)
        if not next_page_result.success then
            currentpage = currentpage - 1
            UIManager:show(InfoMessage:new{
                text = "Error: Failed to fetch works from series: " .. (next_page_result.error or "Unknown error"),
            })
            return {}
        end

        -- no more works to fetch
        if #next_page_result.works == 0 then
            currentpage = currentpage - 1
            return {}
        end

        return  next_page_result.works

    end

    return true, works_result.works, fetchNextPage

end

function Fanfic:getWorksFromCollection(collection_id)
    local works_result = AO3DownloaderClient:getWorksFromCollection(collection_id)
    if not works_result.success then
        UIManager:show(InfoMessage:new{
            text = "Error: Failed to fetch works from collection: " .. (works_result.error or "Unknown error"),
        })
        return false
    end

    local currentpage = 1

    local function fetchNextPage()
        currentpage = currentpage + 1
        local next_page_result = AO3DownloaderClient:getWorksFromCollection(collection_id, currentpage)
        if not next_page_result.success then
            currentpage = currentpage - 1
            UIManager:show(InfoMessage:new{
                text = "Error: Failed to fetch works from collection: " .. (next_page_result.error or "Unknown error"),
            })
            return {}
        end

        -- no more works to fetch
        if #next_page_result.works == 0 then
            currentpage = currentpage - 1
            return {}
        end

        return  next_page_result.works

    end

    return true, works_result.works, fetchNextPage

end

function Fanfic:searchForTags(query, type)
    local search_results = AO3DownloaderClient:searchForTags(query, type)
    if not search_results.success then
        UIManager:show(InfoMessage:new{
            text = "Error: Tag search request failed. " .. (search_results.error or "Unknown error"),
        })
        return false
    end
    return true,search_results.result_tags
end

function Fanfic:checkLoggedIn()
    local request_result = AO3DownloaderClient:GetSessionStatus()
    if not request_result.success then
        UIManager:show(InfoMessage:new{
            text = "Error: Check logged in request failed. " .. (request_result.error or "Unknown error"),
        })
    end

    -- Check logged in status using the Downloader module
    return request_result.success, request_result.logged_in, request_result.username

end

function Fanfic:loginToAO3(username, password)

    -- Attempt to log in using the Downloader module
    local request_result = AO3DownloaderClient:startLoggedInSession(username, password)

    if request_result.success then
        UIManager:show(InfoMessage:new{
            text = "Login successful! Welcome, " .. username .. "!",
        })
        return true
    else
        UIManager:show(InfoMessage:new{
            text = "Failed to log in. Error:" .. (request_result.error or "Unknown error"),
        })
        return false
    end
end

function Fanfic:logoutOfAO3()

    -- Attempt to log in using the Downloader module
    local request_result = AO3DownloaderClient:endLoggedInSession()


    if request_result.success then
        UIManager:show(InfoMessage:new{
            text = _("Successfully logged out"),
        })
        return true
    else
        UIManager:show(InfoMessage:new{
            text = _("Error: Failed to log out. ") .. (request_result.error or "Unknown error"),
        })
        return false
    end
end

return Fanfic
