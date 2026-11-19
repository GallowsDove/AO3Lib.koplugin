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
local cache_jobs={}
package.loaded['ao3lib.ao3.background']={available=function() return true end,
    run=function(task,done,options)
        local job={task=task,done=done,options=options}
        function job:cancel() self.cancelled=true end
        cache_jobs[#cache_jobs+1]=job;return job
    end}
package.loaded['ao3lib.library.epub'].cachedPaths=function(roots)
    assert(roots[1]=='/books');return {'/books/1.epub'}
end
package.loaded['ao3lib.library.epub'].cached=function(path)
    if path==a.path then return a,true end
end
Menu:onViewDownloadedFanfics()
local cache_job=cache_jobs[#cache_jobs]
assert(#requests==0,'Opening Downloaded Works must not start a directory scan')
cache_job.done({found={['1']=a},changed={},missing={}})
assert(owner.item_table[1].text:find('Found 1 AO3 works',1,true))
assert(owner.item_table[3].text:find('First',1,true))
local actions
UI.show=function(_,dialog) actions=dialog end
owner.item_table[3].callback()
assert(not opened and actions.buttons[1][1].text=='Work details')
actions.buttons[2][1].callback()
assert(opened.id=='1' and opened.read and opened.chapter_data[1].read)
owner.item_table[2].callback()
assert(grouped['1'].read)
local child=owner.item_table
assert(grouped['1'].read and owner.item_table==child)
require('ao3lib.library.local_cache').put({'/books','/books'},{['1']=a,['2']=b})
Menu:onViewDownloadedFanfics()
assert(owner.item_table[1].text:find('Found 2 AO3 works',1,true),
    'Reopening Downloaded Works should immediately reuse the session snapshot')
assert(#requests==0,'Reopening must not start another directory scan')
for _,item in ipairs(owner.item_table) do assert(item.text~='Rescan library') end
Menu:onViewDownloadedFanfics()
local pending=cache_jobs[#cache_jobs]
owner.paths[#owner.paths].onReturn()
assert(pending.cancelled,'Backing out of Downloaded Works must cancel validation immediately')
pending.done({found={['1']=a},changed={},missing={}})
Menu:onViewDownloadedFanfics()
pending=cache_jobs[#cache_jobs];visible=false
assert(not pending.options.valid(),'Closing the plugin menu must cancel validation')
print('PASS: cached Downloaded Works UI; saved progress; no directory scans; back/close cancels validation')

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
