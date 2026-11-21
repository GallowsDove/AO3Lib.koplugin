dofile('tests/test_network.lua')
local Menu=require('ao3lib.ui.menu')
local UI=require('ui/uimanager')
local Config=require('ao3lib.core.config')
Config.readSetting=function(_,key,default)
    if key=='AO3_domain' then return 'https://archiveofourown.org' end
    if key=='fanfic_folder_path' then return '/downloads' end
    if key=='filename_template' then return '%I' end
    return default
end
package.loaded['apps/filemanager/filemanagerutil'].getHomeFolder=function() return '/home' end
local owner={GoDownInMenu=function(self,title,rows) self.title,self.item_table=title,rows end}
Menu.menuWidget=owner;Menu.fanfic={ui={}}
local shown={}
UI.show=function(_,widget) shown[#shown+1]=widget end
UI.close=function() end
local scan,puts
package.loaded['ao3lib.library.local_cache']={put=function(roots,works)
    puts={roots=roots,works=works}
end}
package.loaded['ao3lib.library.discovery']={scan=function(roots,done,invalid)
    scan={roots=roots,done=done,invalid=invalid}
    return {cancel=function() scan.cancelled=true end}
end}
Menu:onOpenSettings()
assert(owner.title=='Settings')
local item
for _,row in ipairs(owner.item_table) do if row.text=='Library maintenance…' then row.callback() end end
for _,row in ipairs(shown[#shown].buttons) do if row[1].text=='Rescan library' then item=row[1] end end
assert(item and item.callback,'Settings must expose the rescan action')
item.callback()
local dialog=shown[#shown]
assert(scan.roots[1]=='/downloads' and scan.roots[2]=='/home')
dialog.dismiss_callback()
assert(scan.cancelled and scan.invalid())
scan.done({a={id='a'}})
assert(not puts,'Cancelling must leave the shared index unchanged')
item.callback()
scan.done({a={id='a'},b={id='b'}})
assert(puts and puts.works.a.id=='a' and shown[#shown].text:find('2 AO3 works',1,true))
item.callback();puts=nil
scan.done({},'unavailable')
assert(not puts and shown[#shown].text:find('unavailable',1,true),
    'A failed scan must preserve the index and report the error')
print('PASS: Settings rescan updates the index; cancellation and errors preserve it')
