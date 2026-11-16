package.path='./?.lua;'..package.path
dofile('tests/test_network.lua')
local Menu=require('fanfic_menu')
local UI=require('ui/uimanager')
UI.setDirty=function() end
local visible=true
UI.isWidgetShown=function() return visible end
local requests={}
package.loaded.fanfic_library={scan=function(roots,done,cancelled,options)
    requests[#requests+1]={done=done,cancelled=cancelled,progress=options.progress}
end}
local owner={updates=0,GoDownInMenu=function(self,_,rows) self.item_table=rows end,
updateItems=function(self) self.updates=self.updates+1 end}
Menu.menuWidget=owner
local opened
Menu.fanfic={ui={},onOpenFanficReader=function(_,path,work) opened=work end}
package.loaded['apps/filemanager/filemanagerutil'].getHomeFolder=function() return '/books' end
package.loaded.downloaded_fanfics.get=function(id)
    if id=='1' then return {chapter_data={{read=true}},read=true} end
end
local grouped
package.loaded.downloaded_fanfics_menu.show=function(_,_,_,_,_,works) grouped=works;owner.item_table={} end
local a={id='1',path='/books/1.epub',title='First',author='Writer'}
local b={id='2',path='/books/2.epub',title='Second',author='Writer'}
Menu:onViewDownloadedFanfics()
local scan=requests[#requests]
scan.progress({['1']=a})
assert(owner.item_table[1].text:find('1 AO3 works found',1,true))
assert(owner.item_table[4].text:find('First',1,true))
owner.item_table[4].callback()
assert(opened.id=='1' and opened.read and opened.chapter_data[1].read)
owner.item_table[2].callback()
assert(grouped['1'].read)
local child=owner.item_table
scan.done({['1']=a,['2']=b})
assert(owner.item_table==child,'Completing a scan must not replace a child menu')
assert(grouped['2'] and grouped['1'].read,'Menus opened mid-scan must retain the live results table and progress')
Menu:onViewDownloadedFanfics()
scan=requests[#requests];scan.progress({['1']=a})
owner.item_table[3].callback() -- Stop scanning
assert(scan.cancelled())
scan.done({['1']=a,['2']=b})
assert(#owner.item_table==3,'Results arriving after Stop must be discarded')
Menu:onViewDownloadedFanfics()
scan=requests[#requests];visible=false
assert(scan.cancelled(),'Closing the plugin menu must cancel discovery')
print('PASS: progressive Downloaded Works UI; saved progress on partial results; live author/fandom results; no forced navigation; Stop/close discards stale results')
