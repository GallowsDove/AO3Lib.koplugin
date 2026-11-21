dofile('tests/test_network.lua')
local Config=require('ao3lib.core.config')
local Menu=require('ao3lib.ui.menu')
local Badges=require('ao3lib.bookshelf.badges')
local View=require('ao3lib.ui.work_view')
local Browser=require('ao3lib.ui.work_browser')
local UI=require('ui/uimanager')
local eink,style=false,nil
Config.readSetting=function(_,key,default)
    if key=='ao3_eink_symbols' then return eink end
    if key=='ao3_symbol_style' then return style end
    if key=='AO3_domain' then return 'https://archiveofourown.org' end
    if key=='filename_template' then return '%I' end
    return default
end
Config.saveSetting=function(_,key,value) assert(key=='ao3_symbol_style');style=value end
local settings,shown
Menu.menuWidget={GoDownInMenu=function(_,_,items) settings=items end,
    switchItemTable=function(_,_,items) settings=items end,updateItems=function() end}
UI.show=function(_,dialog) shown=dialog end
UI.close=function() end
local rebuilds,dirty,visible=0,0,true
local live={_rebuild=function() rebuilds=rebuilds+1 end}
package.loaded['lib/bookshelf_widget']={live=live}
UI.isWidgetShown=function(_,widget) assert(widget==live);return visible end
UI.setDirty=function(_,widget) assert(widget==live);dirty=dirty+1 end
local function selectStyle()
    Menu:onOpenSettings()
    for _,item in ipairs(settings) do if item.text=='Reading and display' then item.callback();break end end
    for _,item in ipairs(settings) do
        if item.text=='AO3 symbols' then item.callback();return shown,item.text..': '..item.mandatory end
    end
    error('Missing AO3 symbols setting')
end
local picker,label=selectStyle()
assert(label=='AO3 symbols: Original' and picker.buttons[1][1].text=='Original' and picker.buttons[2][1].text=='E-reader' and #picker.buttons==4)
picker.buttons[2][1].callback()
assert(style=='eink' and rebuilds==1 and dirty==1)
assert(Badges.relativePath('rating-mature')=='ao3-icons-eink/rating-mature.png')
local work={id='eink-setting',title='Title',author='Writer',rating='Mature',category='M/M',
    warnings={'No Archive Warnings Apply'},chapters='1/1'}
local rows=Browser:generateTable({}, {work},function() end,function() end)
local html=View.html(work,rows)
for _,icon in ipairs({'rating-mature','category-slash','warning-no','complete-yes'}) do
    assert(html:find('ao3-icons-eink/'..icon..'.png',1,true))
end
picker,label=selectStyle()
assert(label=='AO3 symbols: E-reader')
picker.buttons[1][1].callback()
assert(style=='original' and rebuilds==2 and dirty==2)
html=View.html(work,rows)
assert(html:find('ao3-icons/rating-mature.png',1,true) and not html:find('ao3-icons-eink/',1,true))
for i,key in ipairs({'zerafina','zerafina_eink'}) do
    picker=selectStyle();picker.buttons[i+2][1].callback()
    assert(style==key and rebuilds==i+2)
    html=View.html(work,rows)
    local folder=key=='zerafina' and 'ao3-icons-zerafina/' or 'ao3-icons-zerafina-eink/'
    assert(html:find(folder..'rating-mature.png',1,true))
    assert(Badges.relativePath('complete-yes')==folder..'complete-yes.png')
end
style='zerafina_bw';assert(Badges.style()=='zerafina_eink')
-- Legacy monochrome preferences survive the new selector until explicitly set.
style=nil;eink=true;assert(Badges.style()=='eink')
eink=false;assert(Badges.style()=='original')
style='unknown';assert(Badges.style()=='original')
visible=false;Badges.refresh();assert(rebuilds==4,'Closed Bookshelf must not be rebuilt')
package.loaded['lib/bookshelf_widget']=nil;Badges.refresh();assert(rebuilds==4)
print('PASS: Original/E-reader/Zerafina color and E-reader choices persist; legacy preference retained; shared Bookshelf/formatted paths; live Bookshelf refresh; optional/closed Bookshelf remains untouched')
