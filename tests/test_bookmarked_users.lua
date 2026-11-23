dofile('tests/test_network.lua')
local Menu=require('ao3lib.ui.menu')
local Config=require('ao3lib.core.config')
local UI=require('ui/uimanager')
local users={'Writer','Pen Name (Account)'}
local saved, profiles, dialogs, closed = nil, {}, {}, {}
Config.readSetting=function(_,key,default) if key=='bookmarkedUsers' then return users end;return default end
Config.saveSetting=function(_,key,value) assert(key=='bookmarkedUsers');saved=value;users=value end
UI.show=function(_,dialog) dialogs[#dialogs+1]=dialog end
UI.close=function(_,dialog) closed[dialog]=true end
Menu.fanfic={showUserInfo=function(_,username,pseud) profiles[#profiles+1]={username,pseud} end}
local owner={GoDownInMenu=function(self,title,items) self.item_table=items end,updateItems=function() end}
Menu.menuWidget=owner
Menu:onSelectUserSearch()
assert(#owner.item_table==3)
owner.item_table[2].callback()
assert(#dialogs==0 and profiles[1][1]=='Writer' and profiles[1][2]=='Writer')
owner.item_table[3].callback()
assert(#dialogs==0 and profiles[2][1]=='Account' and profiles[2][2]:match('^Pen Name%s*$'))
owner.item_table[3].hold_callback()
local menu=dialogs[#dialogs]
assert(#profiles==2 and menu.buttons[1][1].text=='Unbookmark User')
assert(menu.buttons[2][1].text=='Manage subscription')
owner.item_table[2].hold_callback()
menu=dialogs[#dialogs];menu.buttons[1][1].callback()
assert(closed[menu] and saved==users and #users==1 and users[1]=='Pen Name (Account)')
assert(#owner.item_table==2 and owner.item_table[2].text=='★ Pen Name (Account)')
print('PASS: bookmarked-user tap opens profile directly; hold preserves profile/unbookmark menu; pseud parsing and list refresh')
local Bookmarks=require('ao3lib.users.bookmarks')
users={'Account','Pen Name (account)','Other Pen (ACCOUNT)','Elsewhere'}
assert(#Bookmarks.list()==2 and Bookmarks.contains('aCcOuNt'))
Bookmarks.set('ACCOUNT','Pen Name',true)
assert(#users==2 and users[1]=='Account' and users[2]=='Elsewhere','Adding an existing account should remove aliases without losing unrelated entries')
users={'Account','Pen Name (account)','Other Pen (ACCOUNT)','Elsewhere'}
Bookmarks.set('account','Any Pseud',false)
assert(#users==1 and users[1]=='Elsewhere','Unbookmarking must remove every alias of the account')
Bookmarks.set('Account','Pen Name',true)
assert(users[2]=='Pen Name (Account)' and Bookmarks.contains('account'))
local Profile=require('ao3lib.ui.user_browser')
local session=setmetatable({userData={username='Account',pseud='Another Pen',fandoms={}},reloadProfile=function() end}, {__index=Profile})
local profile_rows=session:generateMenuTable()
assert(profile_rows[1][1]=='★ Remove user from bookmarks','Profile must recognize an account bookmarked under a different pseud')
profile_rows[1].callback()
assert(not Bookmarks.contains('Account'))
-- Search-result taps open the pseud directly; hold opens the shared bookmark menu.
package.loaded['ao3lib.ao3.network'].wrap=function(fn) return fn end
local results={{username='Account',pseud='Pen Name',works_count=2,bookmarks_count=3}}
Menu.fanfic.searchForUsers=function() return true,results end
owner.paths={}
function owner:GoDownInMenu(title,items)
    self.paths[#self.paths+1]={title=self.title,items=self.item_table}
    self.title,self.item_table=title,items
end
Menu:onSelectUserSearch()
owner.item_table[1].callback()
local input=dialogs[#dialogs];input.input='Pen';input.buttons[1][2].callback()
local row=owner.item_table[1]
local count=#profiles
row.callback()
assert(#profiles==count+1 and profiles[#profiles][1]=='Account' and profiles[#profiles][2]=='Pen Name')
row.hold_callback();menu=dialogs[#dialogs]
assert(menu.buttons[1][1].text=='Bookmark User' and menu.buttons[2][1].text=='Manage subscription')
menu.buttons[1][1].callback()
assert(Bookmarks.contains('ACCOUNT') and #owner.paths[#owner.paths].items==3)
row.hold_callback();menu=dialogs[#dialogs]
assert(menu.buttons[1][1].text=='Unbookmark User')
menu.buttons[1][1].callback()
assert(not Bookmarks.contains('Account') and #owner.paths[#owner.paths].items==2)
print('PASS: account-based deduplication and removal, profile pseud aliases, consistent search actions and parent refresh')
-- Both user-list and work-author menus expose the same AO3 mute control.
local Actions=require('ao3lib.ui.user_actions')
local Network=require('ao3lib.ao3.network')
Network.wrap=function(fn) return fn end
local requested_mute
package.loaded['ao3lib.ao3.client']={getMutedUsers=function() return {success=true,username='Me',users={{name='Account'}}} end}
package.loaded['ao3lib.ao3.mute_cache']={remember=function(result) assert(result.success) end}
package.loaded['ao3lib.ui.muted_users']={change=function(name,want) requested_mute={name,want} end}
local managed
package.loaded['ao3lib.ui.subscriptions']={manage=function(owner,kind,id,title) managed={owner,kind,id,title} end}
local action_owner={}
local action_menu=Actions.show({username='Account',pseud='Pen Name'},action_owner)
assert(action_menu.buttons[2][1].text=='Manage subscription')
action_menu.buttons[2][1].callback()
assert(managed[1]==action_owner and managed[2]=='User' and managed[3]=='Account')
action_menu=Actions.show({username='Account',pseud='Pen Name'},action_owner)
assert(action_menu.buttons[3][1].text=='Manage AO3 mute')
action_menu.buttons[3][1].callback()
assert(requested_mute[1]=='Account' and requested_mute[2]==false)
print('PASS: shared user action menu checks AO3 mute state before unmuting')
