local Network = require("ao3lib.ao3.network")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local logger = require("logger")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local BD = require("ui/bidi")
local DownloadedFanfics = require("ao3lib.library.history")
local FanficBrowser = require("ao3lib.ui.work_browser")
local FanficMenu = require("ao3lib.ui.menu")
local FanficReader = require("ao3lib.ui.reader")
local Config = require("ao3lib.core.config")
local Event = require("ui/event")
local Dispatcher = require("dispatcher")
local AO3LibClient = require("ao3lib.ao3.client")
local util = require("util")
local Tables = require("ao3lib.core.table")
local ResultPages = require("ao3lib.ao3.result_pages")

local Fanfic = WidgetContainer:extend{
    name = "AO3Lib",
    is_doc_only = false,
    menu_stack = {}
}

function Fanfic:init()
    require("ao3lib.ui.icons").install()
    require("ao3lib.library.delete_hooks").install()
    DownloadedFanfics.load() -- Reader activation needs saved chapter progress.
    if self.ui.name == "ReaderUI" then
        FanficReader.plugin_owner=self
        FanficReader:initializeFromReaderUI(self.ui)
    else
        self.ui.menu:registerToMainMenu(self)
    end

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    -- Optional integration is owned entirely by this plugin. Bookshelf's
    -- existing tables are extended once, after enabled plugin paths are ready.
    local integrated, integration_err = pcall(function()
        require("ao3lib.bookshelf.integration").install()
    end)
    if not integrated then logger.warn("AO3 Bookshelf integration:", integration_err) end
    -- FileManager builds file_chooser after loading plugins. Register against
    -- its API now, rather than waiting for a widget that does not exist yet.
    self:registerWorkDetailsAction()
end

function Fanfic:onSuspend()
    local checks = package.loaded["ao3lib.updates.service"]
    if checks then checks.suspend() end
    return self:onFlushSettings()
end

function Fanfic:onResume()
    local checks = package.loaded["ao3lib.updates.service"]
    if checks then checks.resume() end
end
Fanfic.onNetworkConnected = Fanfic.onResume

function Fanfic:onFlushSettings()
    local ok, err = DownloadedFanfics.flushPending()
    if not ok then logger.warn("Could not save pending AO3 progress:", err) end
    local checks = package.loaded["ao3lib.updates.service"]
    if checks then
        local saved, why = checks.flush()
        if not saved then logger.warn("Could not save AO3 update checks:", why) end
    end
end

function Fanfic:registerWorkDetailsAction()
    local function build(file,is_file)
        if not is_file then return end
        local ok,epub=pcall(function() return require("ao3lib.library.epub").read(file) end)
        if not ok then logger.warn("AO3 work action could not inspect EPUB:",file,epub);return end
        if not epub then return end
        return {{
            text=_("Open AO3 work"),
            callback=function()
                if self.ui.file_dialog then UIManager:close(self.ui.file_dialog) end
                -- Building a Bookshelf menu is read-only. Register the local
                -- work only after the user actually chooses to open it.
                local work=DownloadedFanfics.rememberLocal(epub)
                self:onShowFanficBrowser({work,total=1},nil,_("AO3 work details"),{summary_html=true})
            end,
        }}
    end
    local targets,seen={},{}
    local function add(target)
        if type(target)=='table' and type(target.addFileDialogButtons)=='function' and not seen[target] then
            seen[target]=true;targets[#targets+1]=target
        end
    end
    -- Bookshelf reads the active FileManager registry, or the class registry
    -- when entered without a FileManager. Cover both reader-first startup and
    -- hosts with their own per-instance button list.
    local ok,FileManager=pcall(require,"apps/filemanager/filemanager")
    if ok then add(FileManager);add(FileManager.instance) end
    add(self.ui)
    for _,target in ipairs(targets) do
        target:addFileDialogButtons("ao3_work_details",build)
        local rows=target.file_dialog_added_buttons
        local index=rows and rows.index and rows.index.ao3_work_details
        -- KOReader deduplicates IDs. Refresh the closure when plugins are
        -- re-created, so callbacks do not retain a closed reader/FileManager.
        if index then rows[index]=build end
    end
end


function Fanfic:addToMainMenu(menu_items)
    if self.ui.file_chooser then
        menu_items.AO3Lib = {
            text = "AO3Lib",
            sorting_hint = "search",
            callback = function()
                self.ui:handleEvent(Event:new("OpenAO3LibMenu"))
            end,
        }
    end
end


function Fanfic:onDispatcherRegisterActions()
    Dispatcher:registerAction("AO3Lib_openPluginMenu", {
        category = "none",
        event = "OpenAO3LibMenu",
        title = _("AO3Lib: open menu"),
        general = true,
    })

end
function Fanfic:onOpenAO3LibMenu()
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
    require("ao3lib.ui.navigation").closeAll(self)
end

-- Shared by online browsing and offline work details. showUserInfo handles
-- the network continuation, so opening local details itself stays offline.
function Fanfic:onShowAuthor(author)
    local username=author:match('%((.-)%)') or author
    local pseud=author:match('^(.-)%s*%(') or author
    return self:showUserInfo(username,pseud)
end

function Fanfic:onShowFanficBrowser(ficResults, fetchNextPage, title, view_options)
    logger.dbg("AO3Lib.koplugin: Showing work browser")
    FanficBrowser:show(
        self.ui,
        ficResults,
        fetchNextPage,
        function(fanfic) self:UpdateFanfic(fanfic) end, -- Update callback
        function(fanficId, done) self:DownloadFanfic(fanficId, done) end, -- Download callback
        function(author) self:onShowAuthor(author) end,-- Open author user browser callback
        self,
        title,
        view_options
    )

end

function Fanfic:DownloadFanfic(id, done)
    if Network.defer(function() self:DownloadFanfic(id, done) end) then return end

    local existing = DownloadedFanfics.checkIfStored(id)
    if existing then self:UpdateFanfic(existing); return end

    -- Fetch metadata for the work
    local request_result  = AO3LibClient:getWorkMetadata(id)
    if not request_result.success then
        UIManager:show(InfoMessage:new{
            text = _("Error: failed to fetch work metadata: ") .. (request_result.error or "Unknown error")
        })
        return
    end

    -- Extract the EPUB link from the metadata
    local metadata = request_result.work_metadata
    local fallback = Config:readSetting("html_download_fallback", false) and metadata.html_link
    local url = fallback and metadata or metadata.epub_link
    if not url then
        UIManager:show(InfoMessage:new{
            text = _("Error: EPUB link not found for this work")
        })
        return
    end

    if DownloadedFanfics.checkIfStored(id) then return end
    local destination, path_err = require("ao3lib.library.layout").destination(request_result.work_metadata, Config:readSetting("fanfic_folder_path"))
    if not destination then UIManager:show(InfoMessage:new{text=path_err}); return end
    local made, mkdir_err = util.makePath(destination:match("^(.*)/[^/]+$"))
    if not made then UIManager:show(InfoMessage:new{text=tostring(mkdir_err or "Could not create the destination folder")}); return end
    local download_request_result = AO3LibClient:downloadEpub(url, destination, false)
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
        language = request_result.work_metadata.language,
        series = request_result.work_metadata.series,
        tags = request_result.work_metadata.tags,
        tag_names = request_result.work_metadata.tag_names,
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
    local indexed, dismissed, refreshed = false, false, false
    local function refreshWhenReady()
        if done and indexed and dismissed and not refreshed then
            refreshed=true
            UIManager:nextTick(done)
        end
    end
    pcall(function() require('ao3lib.library.local_cache').index(fanfic.path, function()
        indexed=true
        refreshWhenReady()
    end) end)



    -- Show confirmation dialog
    local missing=download_request_result.missing_images or 0
    local message=T(_("File saved to:\n%1"), BD.filepath(fanfic.path))
    if missing>0 then message=message..'\n\n'..T(_("%1 image(s) could not be included. Links are preserved in the book."),missing) end
    UIManager:show(ConfirmBox:new{
        text = message..'\n'.._("Would you like to read the downloaded work now?"),
        ok_text = _("Read now"),
        cancel_callback = function()
            dismissed=true
            refreshWhenReady()
        end,
        ok_callback = function()
            self:onOpenFanficReader(fanfic.path, fanfic)
        end,
    })
end

function Fanfic:UpdateFanfic(fanfic)
    if Network.defer(function() self:UpdateFanfic(fanfic) end) then return end
    local Updates = require("ao3lib.updates.checks")
    local ok, result = pcall(function()
        local entry = Updates.check(fanfic)
        if not entry.remote then return {success=false, error=entry.error} end
        return Updates.apply(entry)
    end)
    if not ok and require("ao3lib.ao3.background").isCancelled(result) then error(result,0) end
    local message=ok and result.success
        and T(_("Work '%1' has been updated successfully."), fanfic.title)
        or T(_("Could not update work: %1"), tostring(ok and result.error or result))
    if ok and result.success and (result.missing_images or 0)>0 then
        message=message..'\n\n'..T(_("%1 image(s) could not be included. Links are preserved in the book."),result.missing_images)
    end
    if ok and result.success and result.move_error then
        message=message..'\n\n'.._('Could not move updated work: ')..tostring(result.move_error)
    end
    UIManager:show(InfoMessage:new{text=message})
end

function Fanfic:showUserInfo(username, pseud)
    local Nav=require('ao3lib.ui.navigation')
    local identity=Nav.key('user',username,pseud or username)
    if Nav.isCurrent(self,identity) then return end
    if Network.defer(function() self:showUserInfo(username, pseud) end) then return end
    local AO3UserBrowser = require("ao3lib.ui.user_browser")
    local request_result = AO3LibClient:getUserData(username, pseud)
    if not request_result.success then
        UIManager:show(InfoMessage:new{
            text = T("Error: Failed to fetch user info: %1", request_result.error or "Unknown error"),
        })
        return
    end
    if not Nav.isCurrent(self,identity) then AO3UserBrowser:show(request_result.user_data, self.ui, self) end
end

function Fanfic:getUserData(username, pseud)
    local user_data_result = AO3LibClient:getUserData(username, pseud)
    if not user_data_result.success then
        UIManager:show(InfoMessage:new{
            text = "Error: Failed to fetch user data: " .. (user_data_result.error or "Unknown error"),
        })
        return false
    end

    return true, user_data_result.user_data

end

function Fanfic:getPseudsForUser(username)
    local pseuds_result = AO3LibClient:getUserPseuds(username)
    if not pseuds_result.success then
        UIManager:show(InfoMessage:new{
            text = "Error: Failed to fetch pseuds for user: " .. (pseuds_result.error or "Unknown error"),
        })
        return false
    end

    return true, pseuds_result.pseuds

end

function Fanfic:searchForTags(query, type)
    local search_results = AO3LibClient:searchForTags(query, type)
    if not search_results.success then
        UIManager:show(InfoMessage:new{
            text = "Error: Tag search request failed. " .. (search_results.error or "Unknown error"),
        })
        return false
    end
    return true,search_results.result_tags
end

function Fanfic:checkLoggedIn()
    local request_result = AO3LibClient:GetSessionStatus()
    if not request_result.success then
        UIManager:show(InfoMessage:new{
            text = "Error: Check logged in request failed. " .. (request_result.error or "Unknown error"),
        })
    end

    -- Check logged in status using the Downloader module
    return request_result.success, request_result.logged_in, request_result.username

end

function Fanfic:loginToAO3(username, password, remember_me)

    -- Attempt to log in using the Downloader module
    local request_result = AO3LibClient:startLoggedInSession(username, password, remember_me)

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
    local request_result = AO3LibClient:endLoggedInSession()


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

-- Each endpoint is defined once for both sequential and numbered navigation.
local result_pages = {
    fetchFanficsByTag = {method="searchByTag", arguments=2, field="result_works", numbered=true,
        advance_empty=true, warning=true},
    getWorksFromAccountHistory = {method="getWorksFromAccountHistory", arguments=1, field="works", numbered=true,
        advance_empty=true, warning=true},
    executeSearch = {method="searchByParameters", arguments=1, field="works", numbered=true,
        failure=false},
    searchForUsers = {method="searchForUsers", arguments=1, field="result_users",
        error="Error: User search request failed. "},
    getWorksFromUserPage = {method="getWorksFromUserPage", arguments=4, field="works", numbered=true,
        error="Error: Failed to fetch works from user page: "},
    getSeriesFromUserPage = {method="getUserSeries", arguments=2, field="series",
        error="Error: Failed to fetch series from users page: "},
    getCollectionsFromUserPage = {method="getUserCollections", arguments=1, field="collections",
        error="Error: Failed to fetch collections from users collections page: "},
    getWorksFromSeries = {method="getWorksFromSeries", arguments=1, field="works", numbered=true,
        error="Error: Failed to fetch works from series: "},
    getWorksFromCollection = {method="getWorksFromCollection", arguments=1, field="works", numbered=true,
        error="Error: Failed to fetch works from collection: "},
}
for name, spec in pairs(result_pages) do
    Fanfic[name] = function(self, ...)
        local args = Tables.deepCopy({...})
        local function request(page)
            -- Explicit arity preserves optional nil arguments before the page.
            args[spec.arguments + 1] = page
            return AO3LibClient[spec.method](AO3LibClient,
                unpack(args, 1, spec.arguments + 1))
        end
        return ResultPages.open(request, spec, function(err)
            UIManager:show(InfoMessage:new{
                text = (spec.error or _("Error: ")) .. (err or "Unknown error"),
                icon = spec.warning and "notice-warning" or nil,
            })
        end)
    end
end

return Fanfic
