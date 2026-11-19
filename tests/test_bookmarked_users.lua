dofile('tests/test_network.lua')
local Menu=require('ao3lib.ui.menu')
local Config=require('ao3lib.core.config')
local UI=require('ui/uimanager')
local users={'Writer','Pen Name (Account)'}
local saved, profiles, dialogs, closed = nil, {}, {}, {}
Config.readSetting=function(_,key,default) if key=='bookmarkedUsers' then return users end;return default end
Config.saveSetting=function(_,key,value) assert(key=='bookmarkedUsers');saved=value end
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
assert(#profiles==2 and menu.buttons[1][1].text=='View user profile')
assert(menu.buttons[1][2].text=='Unbookmark User')
menu.buttons[1][1].callback()
assert(closed[menu] and profiles[3][1]=='Account')
owner.item_table[2].hold_callback()
menu=dialogs[#dialogs];menu.buttons[1][2].callback()
assert(closed[menu] and saved==users and #users==1 and users[1]=='Pen Name (Account)')
assert(#owner.item_table==2 and owner.item_table[2].text=='★ Pen Name (Account)')
print('PASS: bookmarked-user tap opens profile directly; hold preserves profile/unbookmark menu; pseud parsing and list refresh')
