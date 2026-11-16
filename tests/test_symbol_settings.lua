dofile('tests/test_network.lua')
local Config=require('fanfic_config')
local Menu=require('fanfic_menu')
local Badges=require('fanfic_bookshelf_badges')
local View=require('fanfic_work_view')
local Browser=require('fanficbrowser')
local UI=require('ui/uimanager')
local eink=false
Config.readSetting=function(_,key,default)
    if key=='ao3_eink_symbols' then return eink end
    if key=='AO3_domain' then return 'https://archiveofourown.org' end
    if key=='filename_template' then return '%I' end
    return default
end
Config.saveSetting=function(_,key,value) assert(key=='ao3_eink_symbols');eink=value end
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
    for _,item in ipairs(settings) do
        if item.text:find('AO3 symbols:',1,true) then item.callback();return shown,item.text end
    end
    error('Missing AO3 symbols setting')
end
local picker,label=selectStyle()
assert(label=='AO3 symbols: Original' and picker.buttons[1][1].text=='E-reader' and picker.buttons[2][1].text=='Original')
picker.buttons[1][1].callback()
assert(eink and rebuilds==1 and dirty==1)
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
picker.buttons[2][1].callback()
assert(not eink and rebuilds==2 and dirty==2)
html=View.html(work,rows)
assert(html:find('ao3-icons/rating-mature.png',1,true) and not html:find('ao3-icons-eink/',1,true))
visible=false;Badges.refresh();assert(rebuilds==2,'Closed Bookshelf must not be rebuilt')
package.loaded['lib/bookshelf_widget']=nil;Badges.refresh();assert(rebuilds==2)
print('PASS: Original/E-reader setting persists selection; shared Bookshelf/formatted paths; live Bookshelf refresh; optional/closed Bookshelf remains untouched')
