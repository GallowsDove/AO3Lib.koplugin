dofile('tests/test_network.lua')
local UI = require('ui/uimanager')
local Nav = require('ao3lib.ui.navigation')
local Menu = require('ao3lib.ui.menu')
local NativeMenu = require('ui/widget/menu')
package.loaded["ao3lib.ui.user_browser"] = nil -- test_network replaces show with a spy.
local Profile = require('ao3lib.ui.user_browser')
local Browser = require('ao3lib.ui.work_browser')
local visible, closed = {}, {}
UI.setDirty = function() end
UI.show = function(_, window) visible[window] = true end
UI.close = function(_, window)
    visible[window] = nil
    closed[window] = (closed[window] or 0) + 1
    if window.onCloseWidget then window:onCloseWidget() end
end
NativeMenu.onClose = function(self)
    UI:close(self)
    if self.close_callback then self.close_callback() end
    return true
end
local rtl = false
require('ui/bidi').mirroredUILayout = function() return rtl end
local function title(window)
    window.title_bar = {setRightIcon=function(self, icon) self.icon = icon end}
    Nav.update(window)
    return window.title_bar
end
local owner = {menu_stack={}}
local home = Menu:show(owner)
home.paths = {}
home.page = 3
home.updateItems = function() end
home.switchItemTable = function(self, text, rows, _, __, subtitle)
    self.title, self.item_table, self.subtitle, self.page = text, rows, subtitle, 1
end
local header = title(home)
assert(header.icon == 'close')
local homeRows = home.item_table
home:GoDownInMenu('Downloaded', {{text='Groups'}}, 'Authors')
assert(header.icon == 'chevron.left')
home.page = 4
local downloadedRows = home.item_table
home:GoDownInMenu('Writer', {{text='Story'}})
home:onCloseWithKey()
assert(home.title == 'Downloaded' and home.item_table == downloadedRows and home.page == 4)
assert(visible[home] == nil and not closed[home], 'Back must not close the menu widget')
home:onClose()
assert(home.item_table == homeRows and home.page == 3 and header.icon == 'close')
-- Nested work screens keep the parent mounted; a view/page replacement keeps
-- exactly one history frame and restores the parent's active browser context.
UI:show(home)
local resumed, cleanups = 0, 0
local function screen()
    return {onClose=NativeMenu.onClose, onCloseWidget=function() cleanups=cleanups+1 end}
end
local work = screen()
Nav.bind(owner, work, {resume=function(window) resumed=resumed+1;assert(window == work) end})
UI:show(work)
assert(title(work).icon == 'chevron.left')
local child = screen()
Nav.bind(owner, child);UI:show(child)
child:onCloseWithKey()
assert(visible[work] and visible[home] and not visible[child] and resumed == 1)
child:onClose();assert(closed[child] == 1, 'Repeated Back closed the parent')
local replacement = screen()
Nav.bind(owner, replacement, {replace=work})
UI:show(replacement);UI:close(work)
assert(#owner._ao3_navigation == 2 and not owner.menu_stack[work])
rtl = true
assert(title(replacement).icon == 'chevron.right')
rtl = false
replacement:onClose()
assert(#owner._ao3_navigation == 1 and visible[home])
home:onClose()
assert(#owner._ao3_navigation == 0 and not visible[home])
-- Direct Bookshelf entry has Back and returns straight to its caller.
local direct = screen();Nav.bind(owner, direct);UI:show(direct)
assert(title(direct).icon == 'chevron.left')
direct:onCloseWithKey();assert(#owner._ao3_navigation == 0)

-- Profile -> series replaces the same session frame, preserving each page.
Profile.Fanfic, Profile.userData, Profile.menu_layers = owner, {username='Writer',pseud='Writer'}, {}
Profile.AO3UserWindow = nil
Profile:loadPage('Writer', {{'Profile',''}})
local profile = Profile.AO3UserWindow
profile.show_page = 5
Profile:GoDownInMenu('Series', {{'Series A',''}})
local series = Profile.AO3UserWindow
assert(#owner._ao3_navigation == 1 and closed[profile])
series:onCloseWithKey()
assert(Profile.AO3UserWindow.title == 'Writer' and Profile.AO3UserWindow.show_page == 5)
assert(#owner._ao3_navigation == 1)
Profile.AO3UserWindow:onClose()
assert(#owner._ao3_navigation == 0)
-- Independent author sessions must not share profile data or nested history.
Profile.generateMenuTable = function(self) return {{self.userData.username,''}} end
local first = Profile:show({username='First',pseud='First'}, {}, owner)
first.AO3UserWindow.show_page = 3
first:GoDownInMenu('First series', {{'A',''}})
local second = Profile:show({username='Second',pseud='Second'}, {}, owner)
second.AO3UserWindow:onClose()
assert(first.userData.username == 'First' and #first.menu_layers == 1)
first.AO3UserWindow:onClose()
assert(first.AO3UserWindow.title == 'First' and first.AO3UserWindow.show_page == 3)
Nav.closeAll(owner)
assert(#owner._ao3_navigation == 0 and next(owner.menu_stack) == nil)
print('PASS: root X; nested header/physical Back; menu/profile page restoration; view replacement; direct Bookshelf entry; independent author sessions; RTL arrows; complete teardown')

-- Use KOReader's real visibility dispatch: Menu:updatePageInfo calls both of
-- these on every redraw, even after the return button was explicitly hidden.
local sourceFile=assert(io.open('../koreader/frontend/ui/widget/button.lua'))
local source=sourceFile:read('*a');sourceFile:close()
local Button={}
for __,name in ipairs({'hide','show','showHide','enableDisable'}) do
    local body=assert(source:match('function Button:'..name..'%((.-)\nend\n'))
    local args,code=body:match('^(.-)%)\n(.*)$')
    Button[name]=assert(loadstring('return function(self'..(args~='' and ','..args or '')..')\n'..code..'\nend'))()
end
Button.disable=function(self) self.enabled=false end
Button.enable=function(self) self.enabled=true end
local arrow=setmetatable({icon='back.top',frame={background='white'},label_widget={},enabled=true},{__index=Button})
local screenWithArrow=screen();screenWithArrow.page_return_arrow=arrow
Nav.bind(owner,screenWithArrow)
assert(arrow.hidden and not arrow.enabled and not arrow.focusable)
for i=1,3 do
    arrow:showHide(true);arrow:enableDisable(true)
    assert(arrow.hidden and not arrow.enabled,'Menu redraw restored the duplicate return arrow')
end
-- A non-AO3 button using the same native methods remains fully functional.
local native=setmetatable({icon='back.top',frame={},label_widget={},enabled=false},{__index=Button})
native:hide();native:showHide(true);native:enableDisable(true)
assert(not native.hidden and native.enabled)
Nav.closeAll(owner)
print('PASS: duplicate bottom-left return arrow stays hidden and disabled across native redraw dispatch; other buttons are unaffected')

-- Menu opens the host's native top menu without unwinding AO3 navigation.
-- Home continues to follow exactly the one-level Back path.
local topMenus=0
local hostMenu
hostMenu={onShowMenu=function(self)
    assert(self==hostMenu)
    topMenus=topMenus+1
end}
local keyOwner={menu_stack={},ui={menu=hostMenu}}
local keyHome=Menu:show(keyOwner)
keyHome.paths={};keyHome.page=1
keyHome.updateItems=function() end
keyHome.switchItemTable=home.switchItemTable
keyHome:GoDownInMenu('Search', {{text='Tags'}})
keyHome:GoDownInMenu('Fandom', {{text='Works'}})
keyHome:onHome()
assert(keyHome.title=='Search' and #keyHome.paths==1)
local profileScreen=screen();Nav.bind(keyOwner,profileScreen);UI:show(profileScreen)
profileScreen:onAO3Menu()
assert(topMenus==1 and not closed[profileScreen] and keyHome.title=='Search' and #keyHome.paths==1)
assert(#keyOwner._ao3_navigation==2 and visible[profileScreen])
assert(keyHome.key_events.Home[1][1]=='Home' and keyHome.key_events.AO3Menu[1][1]=='Menu')
assert(not keyHome.key_events.LeftButtonTap)
profileScreen:onHome();assert(#keyOwner._ao3_navigation==1)
keyHome:onAO3Menu();assert(topMenus==2 and #keyHome.paths==1)
keyHome:onHome();keyHome:onHome();assert(#keyOwner._ao3_navigation==0)
local directOwner={menu_stack={},ui={menu=hostMenu}}
local directProfile=screen();Nav.bind(directOwner,directProfile)
directProfile:onAO3Menu()
assert(topMenus==3 and not closed[directProfile] and #directOwner._ao3_navigation==1)
Nav.closeAll(directOwner)
print('PASS: PocketBook Home goes back one level; Menu opens native KOReader menu from nested screens and direct Bookshelf entry without discarding AO3 state')
