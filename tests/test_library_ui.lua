package.path='./?.lua;'..package.path
dofile('tests/test_network.lua')
local Menu=require('ao3lib.ui.menu')
local UI=require('ui/uimanager')
UI.setDirty=function() end
local visible=true
UI.isWidgetShown=function() return visible end
local requests={}
package.loaded["ao3lib.library.discovery"]={scan=function(roots,done,cancelled,options)
    requests[#requests+1]={done=done,cancelled=cancelled,progress=options.progress}
end}
local owner={updates=0,paths={},GoDownInMenu=function(self,title,rows)
    self.paths[#self.paths+1]={title=self.title,items=self.item_table}
    self.title,self.item_table=title,rows
end,
updateItems=function(self) self.updates=self.updates+1 end}
Menu.menuWidget=owner
local opened
Menu.fanfic={ui={},onOpenFanficReader=function(_,path,work) opened=work end}
package.loaded['apps/filemanager/filemanagerutil'].getHomeFolder=function() return '/books' end
package.loaded["ao3lib.library.history"].get=function(id)
    if id=='1' then return {chapter_data={{read=true}},read=true} end
end
local grouped
package.loaded["ao3lib.ui.downloaded_menu"].show=function(_,_,_,_,_,works) grouped=works;owner.item_table={} end
local a={id='1',path='/books/1.epub',title='First',author='Writer'}
local b={id='2',path='/books/2.epub',title='Second',author='Writer'}
Menu:onViewDownloadedFanfics()
local scan=requests[#requests]
scan.progress({['1']=a})
assert(owner.item_table[1].text:find('1 AO3 works found',1,true))
assert(owner.item_table[4].text:find('First',1,true))
local actions
UI.show=function(_,dialog) actions=dialog end
owner.item_table[4].callback()
assert(not opened and actions.buttons[1][1].text=='Work details')
actions.buttons[2][1].callback()
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
scan=requests[#requests];scan.progress({['1']=a})
owner.paths[#owner.paths].onReturn()
assert(scan.cancelled(),'Backing out of Downloaded Works must cancel discovery immediately')
scan.done({['1']=a,['2']=b})
Menu:onViewDownloadedFanfics()
scan=requests[#requests];visible=false
assert(scan.cancelled(),'Closing the plugin menu must cancel discovery')
print('PASS: progressive Downloaded Works UI; saved progress on partial results; live author/fandom results; no forced navigation; Stop/close discards stale results')

-- All nested downloaded/author/fandom/chapter pages inherit the same menu
-- class; do not let the default Menu row borders creep back into these lists.
local plugin={menu_stack={}}
Menu:show(plugin)
assert(Menu.menuWidget.is_borderless and not Menu.menuWidget.is_popout)
assert(Menu.menuWidget.linesize==0 and Menu.menuWidget.with_bottom_line)
assert(Menu.menuWidget.title_bar_left_icon=='ao3' and Menu.menuWidget.covers_fullscreen)
local Style=require('ao3lib.ui.widgets')
local original={title='Local works',is_popout=false}
local styled=Style.menu(original)
assert(styled~=original and original.linesize==nil and styled.linesize==0)
print('PASS: borderless AO3 list styling; no heavy row underlines; consistent header and logo; caller options stay isolated')
