-- Run from the plugin directory: luajit tests/test_network.lua
package.path = './?.lua;' .. package.path
local function stub(name, value) package.loaded[name] = value end
local Class = {}
function Class:extend(t) return setmetatable(t, { __index = self }) end
function Class:new(t)
    t = t or {}
    t.items_per_page = t.items_per_page or 20
    t.pages = t.pages or 1
    return setmetatable(t, { __index = self })
end
function Class:addWidget(w) self.extra_widget=w end
function Class:onShowKeyboard() end
function Class:onCloseKeyboard() end
function Class:getInputText() return self.input end
function Class:getFields() return self.fields end
function Class:_populateItems() end
function Class:onClose() end
local connected, pending, prompts = false, nil, 0
stub('ui/network/manager', {
    isConnected = function() return connected end,
    runWhenConnected = function(_, callback)
        assert(type(callback) == 'function', 'connection must have a continuation')
        prompts = prompts + 1
        pending = callback
    end,
})
local shown, closed, tasks, task_delays = {}, {}, {}, {}
local UI = {
    show = function(_, w) shown[#shown + 1] = w end,
    close = function(_, w) closed[w] = true end,
    scheduleIn = function(_, delay, callback) tasks[#tasks + 1] = callback;task_delays[#task_delays+1]=delay end,
    nextTick = function(_, callback) tasks[#tasks + 1] = callback end,
}
stub('ui/uimanager', UI)
local function connect()
    assert(pending, 'no pending operation')
    local callback = pending
    pending, connected = nil, true
    callback()
end
local function offline() connected, pending = false, nil end
local function lastShown() return shown[#shown] end
for _, name in ipairs({ 'ui/widget/menu', 'ui/widget/inputdialog',
    'ui/widget/multiinputdialog', 'ui/widget/checkbutton', 'ui/widget/buttondialog', 'ui/widget/keyvaluepage',
    'ui/widget/infomessage', 'ui/widget/confirmbox', 'ui/widget/notification',
    'ui/widget/container/widgetcontainer' }) do stub(name, Class) end
stub('gettext', function(s) return s end)
stub('ffi/util', { template = function(s, ...)
    local args = {...}
    return (s:gsub('%%(%d)', function(i) return tostring(args[tonumber(i)]) end))
end })
stub('logger', { dbg = function() end })
stub('util', { trim = function(s) return s:match('^%s*(.-)%s*$') end })
stub('ao3lib.core.config', { readSetting = function(_, key, default) if key=='formatted_work_view' then return false end; return default end })
for _, name in ipairs({ 'ui/bidi', 'ui/event', 'dispatcher', 'ao3lib.ui.reader',
    'ao3lib.ui.search', 'ao3lib.ui.search_filters_menu',
    'apps/filemanager/filemanagerutil', 'apps/reader/readerui', 'ao3lib.ui.bookmark_dialog' }) do stub(name, {}) end
local work = { id = '123', path = '/books/test.epub', title = 'Test', author = 'Writer',
    wordcount = '1234', updated = '2026-01-01', chapters = '1/1' }
local updates = 0
stub('ao3lib.library.epub', { read = function(path) if path == work.path then return work end end })
stub('ao3lib.library.history', {
    rememberLocal = function(epub) return epub end,
    checkIfStored = function(id) if id == work.id then return work end end,
    update = function() updates = updates + 1 end,
})
local queries, profiles, comments = {}, {}, {}
local client = {
    searchForUsers = function(_, query)
        queries[#queries + 1] = query
        return { success = true, result_users = {{ username = 'Writer', pseud = 'Writer', works_count = 2, bookmarks_count = 1 }} }
    end,
    getUserData = function(_, username, pseud)
        profiles[#profiles + 1] = {username, pseud}
        return { success = true, user_data = { username = username, pseud = pseud } }
    end,
    startLoggedInSession = function(_, username, password)
        assert(username == 'Writer' and password == 'secret')
        return { success = true }
    end,
    markForLaterWork = function() return { success = false, error = 'offline error' } end,
    commentOnWork = function(_, text, id)
        comments[#comments + 1] = {text, id}
        return { success = true }
    end,
    kudosWork = function() return { success = true } end,
}
stub('ao3lib.ao3.client', client)
local Network = require('ao3lib.ao3.network')
-- Preserve parameters (including nils) and synchronous return values online.
connected = true
local fn = Network.wrap(function(a,b,c) assert(a == 1 and b == nil and c == 3); return true, 'result' end)
local ok, result = fn(1,nil,3)
assert(ok and result == 'result' and prompts == 0)
offline()
local count = 0
Network.run(function() count = count + 1 end)
assert(count == 0)
pending = nil -- cancel connection
assert(count == 0)

local Fanfic = require('main')
local Menu = require('ao3lib.ui.menu')
local Browser = require('ao3lib.ui.work_browser')
local fm = { addFileDialogButtons = function(self, _, builder) self.row_builder = builder end }
local plugin = Fanfic:extend{ ui = fm, menu_stack = {} }
-- KOReader initializes plugins before FileManager creates file_chooser.
-- Exercise init itself: registering the hook manually hides this regression.
fm.name = 'FileManager'
fm.menu = { registerToMainMenu = function() end }
plugin.onDispatcherRegisterActions = function() end
require('ao3lib.library.history').load = function() end
assert(fm.file_chooser == nil and fm.row_builder == nil)
plugin:init()
assert(type(fm.row_builder) == 'function', 'AO3 action must register before file_chooser exists')
assert(fm.row_builder(work.path, true)[1].text == 'Open AO3 work')
local navigations = {}
Menu.fanfic = plugin
Menu.menuWidget = {
    GoDownInMenu = function(_, title, items) navigations[#navigations + 1] = {title, items} end,
    updateItems = function() end,
}
-- Author search stays open if the connection is cancelled, then renders results
-- from the original input when resubmitted and connected.
Menu:onSearchUser()
local search = lastShown()
search.input = 'Writer query'
search.buttons[1][2].callback()
assert(#queries == 0 and not closed[search])
pending = nil
assert(search.input == 'Writer query' and not closed[search])
search.buttons[1][2].callback()
connect()
assert(#queries == 1 and queries[1] == 'Writer query' and closed[search])
assert(#navigations == 1 and #navigations[1][2] == 1)
-- Direct profile opening used to bypass Wi-Fi entirely.
local UserBrowser = require('ao3lib.ui.user_browser')
local profileShown
UserBrowser.show = function(_, data) profileShown = data end
offline()
plugin:showUserInfo('Writer','Pseud')
assert(#profiles == 0 and not profileShown)
connect()
assert(#profiles == 1 and profileShown.username == 'Writer' and profileShown.pseud == 'Pseud')
-- Login continuation must update the account menu, as well as logging in.
offline()
Menu:enterUserDetails()
local login = lastShown()
login.fields = {'Writer', 'secret'}
login.buttons[1][2].callback()
assert(not closed[login])
connect()
assert(closed[login] and Menu.logged_in and Menu.username == 'Writer')
-- Cached details stay offline and open the rendered work browser.
offline()
plugin:registerWorkDetailsAction()
assert(fm.row_builder('/other/test.epub', true) == nil)
assert(fm.row_builder(work.path, false) == nil)
local rendered=require('ao3lib.ui.work_view')
local original_render=rendered.show
local details_context
rendered.show=function(_,context) details_context=context end
fm.row_builder(work.path, true)[1].callback()
assert(not pending and details_context.title=='AO3 work details' and details_context.works[1].updated=='2026-01-01')
rendered.show=original_render
-- Reader inputs survive Wi-Fi cancellation, and submitting after connection
-- performs the action and closes the input dialog exactly once.
package.loaded["ao3lib.ui.reader"] = nil
local Reader = require('ao3lib.ui.reader')
Reader.current_fanfic = work
local entries = {}
Reader:addToMainMenu(entries)
offline()
entries.AO3Lib_comment_work.callback()
local comment = lastShown()
comment.input = 'Keep this comment'
comment.buttons[1][2].callback()
assert(#comments == 0 and not closed[comment])
connect()
assert(#comments == 1 and comments[1][1] == 'Keep this comment' and comments[1][2] == work.id)
assert(closed[comment])
-- A failed mark-for-later request must not change locally saved state.
entries.AO3_manage_work.callback()
local manage = lastShown()
manage.buttons[1][1].callback()
assert(not work.markedForLater and updates == 0)
-- Imported multi-chapter EPUBs may have no AO3 chapter-ID map. Reaching an
-- early chapter end must not mark the entire work read.
local completed = 0
work.chapter_data = {}
Reader.is_showing = true
require('apps/reader/readerui').instance = { document = {file=work.path, getPageCount = function() return 100 end } }
Reader._reader_ui = require('apps/reader/readerui').instance
require('ao3lib.library.history').markWorkAsRead = function(id)
    assert(id == work.id)
    completed = completed + 1
    work.read = true
    return work
end
Reader:onPageUpdate(2)
assert(completed == 0)
Reader:onPageUpdate(100)
assert(completed == 1)
-- Bookmark actions must resume both the request and the caller's close-on-success.
for _, name in ipairs({ 'ui/widget/textboxwidget', 'ui/widget/inputtext',
    'ui/widget/checkbutton', 'ui/widget/button', 'ui/widget/horizontalgroup' }) do stub(name, Class) end
stub('device', {})
stub('ui/font', { getFace = function() return {} end })
stub('ui/size', {})
function Class:getTextHeight() return 20 end
local stopAfterButtons = {}
Class.init = function() error(stopAfterButtons) end
package.loaded["ao3lib.ui.bookmark_dialog"] = nil
local Bookmark = require('ao3lib.ui.bookmark_dialog')
local saved, deleted, bookmarkClosed = 0, 0, false
local function field(text) return { getText = function() return text end } end
local bookmark = Bookmark:new{
    current_fanfic = { bookmarkID = '321' },
    bookmark_notes_field = field('Keep these notes'),
    bookmark_tags_field = field('tag'),
    bookmark_collections_field = field('collection'),
    save_dialog_callback = function(data)
        assert(data.notes == 'Keep these notes' and data.tags == 'tag')
        saved = saved + 1
        return true
    end,
    delete_dialog_callback = function() deleted = deleted + 1; return true end,
    close_widget_callback = function() bookmarkClosed = true end,
    search_collections_callback = function(query)
        assert(query == 'Collection query')
        return {{ name = 'Found collection' }}
    end,
}
local initialized, err = pcall(function() bookmark:init() end)
assert(not initialized and err == stopAfterButtons)
Class.init = nil
offline()
bookmark.buttons[1][1].callback()
assert(saved == 0 and not bookmarkClosed)
connect()
assert(saved == 1 and bookmarkClosed)
bookmarkClosed = false
offline()
bookmark.buttons[1][2].callback()
local confirm = lastShown()
confirm.buttons[1][1].callback()
assert(deleted == 0 and not bookmarkClosed and not closed[confirm])
connect()
assert(deleted == 1 and bookmarkClosed and closed[confirm])
local selection
bookmark.collectionSearchSelectionWidget = function(_, _, results) selection = results end
offline()
bookmark:collectionSearchWidget()
local collections = lastShown()
collections.input = 'Collection query'
collections.buttons[1][2].callback()
assert(not selection and not closed[collections])
connect()
assert(selection[1].name == 'Found collection' and closed[collections])
-- Deletion from an already-downloaded work requires confirmation, preserves
-- history on file errors, and refreshes the downloaded marker on success.
local history = require('ao3lib.library.history')
local stored, removals, reloads, removeOK = true, 0, 0, false
history.checkIfStored = function(id) if stored and id == work.id then return work end end
history.delete = function(id) assert(id == work.id); stored = false; removals = removals + 1 end
require('util').removeFile = function(path)
    assert(path == work.path)
    return removeOK, 'permission denied'
end
Browser.browse_window = { reload = function() reloads = reloads + 1 end }
local rows = Browser:generateTable({}, {work}, function() end, function() end)
rows[1].callback()
local options = lastShown()
assert(#options.buttons[1] == 1 and options.buttons[1][1].text == 'Check for updates')
for _,row in ipairs(options.buttons) do
    for _,button in ipairs(row) do assert(button.text ~= 'Work details') end
end
assert(options.buttons[2][1].text == 'Open for reading' and options.buttons[2][2].text == 'Select chapter')
assert(options.buttons[3][1].text == 'Delete local copy' and options.buttons[3][2].text == 'Cancel')
options.buttons[3][1].callback()
local deleteConfirm = lastShown()
assert(closed[options] and removals == 0)
deleteConfirm.buttons[1][2].callback()
assert(closed[deleteConfirm] and removals == 0 and stored)
Browser:showDeleteDialog(work)
lastShown().buttons[1][1].callback()
assert(stored and removals == 0 and reloads == 0)
removeOK = true
Browser:showDeleteDialog(work)
lastShown().buttons[1][1].callback()
assert(not stored and removals == 1 and reloads == 1)
assert(Browser:generateTable({}, {work}, function() end, function() end)[1][1] == work.title)
assert(not pending) -- Deleting a local download never requires Wi-Fi.
print('PASS: network continuations; search/profile/login; cached details; pagination; reader/bookmark actions; deletion confirmation, failure, and refresh')
-- Failed online operations must show their error without losing input or
-- damaging already-known account state.
connected = true
local outage = 'AO3 is temporarily unavailable or under maintenance (HTTP 503). Please try again later.'
client.getUserData = function() return {success=false,error=outage} end
local previousProfile = profileShown
plugin:showUserInfo('Writer','Writer')
assert(lastShown().text:find('maintenance',1,true) and profileShown==previousProfile)
client.getWorksFromUserPage = function() return {success=false,error=outage} end
UserBrowser.Fanfic, UserBrowser.userData, UserBrowser.ui = plugin, {username='Writer',pseud='Writer'}, fm
assert(pcall(function() UserBrowser:openFanficBrowserForCategory('works',0) end))
assert(lastShown().text:find('maintenance',1,true))
local savedSearch = client.searchForUsers
client.searchForUsers = function() return {success=false,error=outage} end
Menu:onSearchUser()
local failedSearch = lastShown()
failedSearch.input = 'Retain my query'
failedSearch.buttons[1][2].callback()
assert(not closed[failedSearch] and failedSearch.input=='Retain my query')
client.searchForUsers = savedSearch
client.startLoggedInSession = function() return {success=false,error=outage} end
Menu:enterUserDetails()
local failedLogin = lastShown()
failedLogin.fields = {'Writer','retained password'}
failedLogin.buttons[1][2].callback()
assert(not closed[failedLogin] and failedLogin.fields[2]=='retained password')
client.GetSessionStatus = function() return {success=false,error=outage} end
Menu.logged_in, Menu.username = true, 'Writer'
Menu:onAccountManagementMenu()
assert(Menu.logged_in and Menu.username=='Writer')
local pages = {}
client.searchByTag = function(_, _, _, page)
    pages[#pages+1] = page
    if #pages==1 then return {success=true,result_works={}} end
    return {success=false,error=outage}
end
local success, _, fetchNext = plugin:fetchFanficsByTag('tag','title')
assert(success and #fetchNext()==0 and #fetchNext()==0)
assert(pages[1]==1 and pages[2]==2 and pages[3]==2)
print('PASS: online failures retain search/login inputs and account state; author/category errors remain in UI; pagination can retry the failed page')
-- Future downloads use the configured Author/Title layout and reserve names
-- against existing EPUBs/sidecars; re-downloading a tracked ID updates it.
local Config=require('ao3lib.core.config')
Config.readSetting=function(_,key,default)
    if key=='fanfic_folder_path' then return '/books' end
    if key=='author_folders' then return true end
    return default
end
stub('libs/libkoreader-lfs',{attributes=function(path)
    if path=='/books/Account/Fresh title.epub' then return 'file' end
end})
local util=require('util')
util.getSafeFilename=function(s) return s end
local made
util.makePath=function(path) made=path; return true end
local added,downloaded,updated,downloadCalls
require('ao3lib.library.history').add=function(data) added=data end
require('ao3lib.library.history').checkIfStored=function(id) if added and id==added.id then return added end end
client.getWorkMetadata=function(_,id)
    return {success=true,work_metadata={id=id,title='Fresh title',author='Pseud (Account)',epub_link='https://example.test/file.epub',chapterData={{read=true}}}}
end
client.downloadEpub=function(_,_,destination,allow_replace)
    assert(allow_replace==false)
    downloaded=destination; downloadCalls=(downloadCalls or 0)+1
    return {success=true,filepath=destination}
end
require('ui/bidi').filepath=function(path) return path end
local indexed, index_done, reloads = {}, nil, 0
stub('ao3lib.library.local_cache', {index=function(path, done)
    indexed[#indexed+1]=path; index_done=done
end})
local notified=false
stub('ao3lib.library.metadata_refresh', {notify=function() notified=true end})
plugin:DownloadFanfic('900',function() reloads=reloads+1 end)
assert(made=='/books/Account' and downloaded=='/books/Account/Fresh title [900].epub')
assert(added.id=='900' and added.path==downloaded and added.chapter_data[1].read==false)
assert(not notified, 'New downloads should not trigger a broad metadata refresh')
assert(indexed[1]==downloaded and reloads==0, 'Work view must wait for the background index')
index_done({id='900'});assert(reloads==0)
lastShown().cancel_callback()
assert(reloads==0);table.remove(tasks,#tasks)();assert(reloads==1)
added.chapter_data[1].read=true
plugin.UpdateFanfic=function(_,existing) updated=existing end
plugin:DownloadFanfic('900')
assert(downloadCalls==1 and updated==added and updated.chapter_data[1].read)
-- Losing Wi-Fi before the request resumes the same download after reconnecting.
offline();plugin:DownloadFanfic('901')
assert(pending and downloadCalls==1)
connect()
assert(downloadCalls==2 and added.id=='901')
local earlier=reloads
plugin:DownloadFanfic('902',function() reloads=reloads+1 end)
lastShown().cancel_callback()
assert(reloads==earlier,'Dismissing the prompt must not scan the EPUB')
index_done({id='902'})
table.remove(tasks,#tasks)()
assert(reloads==earlier+1,'The work view refreshes after indexing completes')
print('PASS: new downloads use Author/Title and safe collision suffixes; downloading an existing ID preserves tracked progress through Update')

local history_flushes=0
package.loaded["ao3lib.library.history"].flushPending=function() history_flushes=history_flushes+1;return true end
Fanfic:onSuspend()
Fanfic:onFlushSettings()
assert(history_flushes==2,'Suspend and explicit settings flush must checkpoint pending AO3 progress')
print('PASS: suspend and settings-flush checkpoints persist pending AO3 progress')

-- Work series links preserve their destination through Wi-Fi prompts and
-- use the existing series fetcher, pagination and failure handling.
local seriesCalls,seriesOpened={},{}
local seriesFailure=false
client.getWorksFromSeries=function(_,id,page)
    seriesCalls[#seriesCalls+1]={id=id,page=page}
    if seriesFailure then return {success=false,error='maintenance'} end
    return {success=true,works={{id='series-work',title='Next work'},total=3}}
end
plugin.onShowFanficBrowser=function(_,works,nextPage,title)
    seriesOpened[#seriesOpened+1]={works=works,nextPage=nextPage,title=title}
end
Browser.Fanfic=plugin
local linkWork={id='series-example',title='Story',series={
    {id=12,title='First series',position='2'},
    {id=34,title='Second series',position='1'},
    {title='Legacy series'},
}}
local links={}
for _,row in ipairs(Browser:generateTable({}, {linkWork},function() end,function() end)) do
    if row[1]=='     Series:' then links[#links+1]=row end
end
assert(#links==1 and links[1].callback)
local function openSeriesLink(index)
    links[1].callback()
    local chooser=lastShown()
    assert(chooser.buttons[3][1].enabled==false, 'Legacy entries without IDs must stay disabled')
    chooser.buttons[index][1].callback()
end
offline()
openSeriesLink(1)
assert(#seriesCalls==0 and #seriesOpened==0 and pending)
pending=nil -- Cancel Wi-Fi: no navigation and the original row can be retried.
openSeriesLink(1)
connect()
assert(#seriesCalls==1 and seriesCalls[1].id==12)
assert(#seriesOpened==1 and seriesOpened[1].title=='First series' and seriesOpened[1].works.total==3)
seriesOpened[1].nextPage()
assert(seriesCalls[2].id==12 and seriesCalls[2].page==2)
openSeriesLink(2)
assert(seriesCalls[3].id==34 and seriesOpened[2].title=='Second series')
seriesFailure=true
openSeriesLink(1)
assert(#seriesOpened==2 and lastShown().text:find('maintenance',1,true))
print('PASS: clickable work series; independent destinations; Wi-Fi cancel/retry; series title; pagination; failures preserve the current list; missing IDs stay plain text')

-- One author opens directly, even when there are gift recipients. Multiple
-- authors keep the picker and its existing giftee destinations.
local authorOpened={}
Browser.showAuthorInfoCallback=function(author) authorOpened[#authorOpened+1]=author end
local function authorRow(author,gifted)
    return Browser:generateTable({},{{id='authors',title='Story',author=author,gifted_to=gifted}},
        function() end,function() end)[2]
end
local beforeDialogs=#shown
authorRow(' Writer '):callback()
assert(#shown==beforeDialogs and authorOpened[1]=='Writer')
authorRow('Writer','Recipient'):callback()
assert(#shown==beforeDialogs and authorOpened[2]=='Writer')
authorRow('Writer, Coauthor','Recipient'):callback()
local authorPicker=lastShown()
assert(#shown==beforeDialogs+1 and authorPicker.buttons[1][1].text=='Writer'
    and authorPicker.buttons[2][1].text=='Coauthor')
authorPicker.buttons[2][1].callback()
assert(authorOpened[3]=='Coauthor' and closed[authorPicker])
authorRow(nil):callback()
assert(#shown==beforeDialogs+1 and #authorOpened==3)
print('PASS: single author opens directly; multiple authors choose; gift recipients preserve direct single-author navigation; anonymous works do not open an empty picker')
