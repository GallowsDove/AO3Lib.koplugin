dofile('tests/test_network.lua')
local UI=require('ui/uimanager')
local shown,requests={},{}
UI.show=function(_,widget) shown[#shown+1]=widget end
UI.close=function() end
local deferred,jobs=nil,{}
package.loaded["ao3lib.ao3.network"]={
    wrap=function(fn) return fn end,
    defer=function(fn) if deferred==false then deferred=fn;return true end return false end,
    schedule=function(_,fn) jobs[#jobs+1]=fn end,
}
local settings={saved_filters={legacy={title='Legacy',parameters={main_tag='Fluff',additional_tags={'Old'}}}},
    bookmarkedFandoms={'A fandom'}}
local config=require('ao3lib.core.config')
local writes=0
config.readSetting=function(_,key,default) return settings[key] or default end
config.saveSetting=function(_,key,value) settings[key]=value;writes=writes+1 end
package.loaded["ao3lib.ui.search_filters_menu"]=nil
package.loaded["ao3lib.ui.menu"]=nil
local Filter=require('ao3lib.ui.search_filters_menu')
local Menu=require('ao3lib.ui.menu')
local widget={paths={},updateItems=function() end}
function widget:GoDownInMenu(title,items)
    self.paths[#self.paths+1]={title=self.title,items=self.item_table}
    self.title,self.item_table=title,items
end
function widget:onReturn()
    local previous=table.remove(self.paths)
    self.title,self.item_table=previous.title,previous.items
end
local opened=0
local browser_options
local fanfic={executeSearch=function(_,params)
    requests[#requests+1]=params
    return true, {total=0}
end,onShowFanficBrowser=function(_,_,_,_,options) opened=opened+1;browser_options=options end}
Menu.menuWidget,Menu.fanfic=widget,fanfic
Menu:onSearchFanficMenu()
assert(widget.item_table[1].text=='Search works')
for _,item in ipairs(widget.item_table) do
    assert(not item.text:find('Browse works by',1,true) and item.text~='Search using Filter search')
end
widget.item_table[1].callback()
assert(widget.title=='Search works' and widget.item_table[1].text=='New search')
assert(Filter.menuWidget==widget and Filter.fanfic==fanfic,
    'Opening saved filters must bind the editor even before starting a new search')
assert(widget.item_table[2].text=='Saved filters:','Named saved filters must remain visible')
widget.item_table[1].callback()
assert(widget.item_table[1].text:find('Work Info',1,true))
for _,item in ipairs(widget.item_table) do
    assert(not item.text_func or not item.text_func():find('Within tag',1,true))
end
assert(writes==1 and settings.saved_filters.legacy.parameters.main_tag==nil)
assert(settings.saved_filters.legacy.parameters.additional_tags[2]=='Fluff')
Filter:WorkInfoSubmenu()
local title_row=widget.item_table[1]
assert(title_row.text_func()=='Title: Any')
title_row.callback()
local title_dialog=shown[#shown]
assert(title_dialog.input=='')
title_dialog.input='A & B';title_dialog.buttons[1][2].callback()
assert(Filter.filter.work_title=='A & B' and title_row.text_func()=='Title: A & B')
title_row.callback();assert(shown[#shown].input=='A & B')
shown[#shown].input='';shown[#shown].buttons[1][2].callback()
assert(Filter.filter.work_title==nil)
Filter.filter.work_title='A & B'
Filter:selectAdditionalTags()
assert(widget.item_table[2].text=='Enter tag by name')
widget.item_table[2].callback()
local dialog=shown[#shown]
dialog.input='  My unwrangled tag  '
dialog.buttons[1][3].callback()
assert(Filter.filter.additional_tags[1]=='My unwrangled tag')
widget.item_table[2].callback();dialog=shown[#shown]
dialog.input='My unwrangled tag';dialog.buttons[1][3].callback()
assert(#Filter.filter.additional_tags==1,'Direct entry must not duplicate tags')
widget.item_table[2].callback();dialog=shown[#shown]
dialog.input='Excluded tag';dialog.buttons[1][2].callback()
Filter.filter.exclude_warnings={'17'};Filter.filter.exclude_categories={'22'}
Filter.filter.warnings={'16'};Filter.filter.categories={'21'}
Filter.filter.word_count='>50000';Filter.filter.date_from='2026-01-01'
Filter:executeSearch()
Filter.filter.additional_tags[1]='Changed after submission'
table.remove(jobs,1)()
local params=requests[#requests]
assert(params.tag_id==nil and opened==1)
assert(params['work_search[freeform_names]']=='My unwrangled tag')
assert(params['work_search[title]']=='A & B')
assert(params['work_search[excluded_tag_names]']=='Excluded tag,Graphic Depictions Of Violence,F/M')
assert(params['work_search[excluded_tag_ids][]']==nil)
assert(params['exclude_work_search[category_ids][]']==nil)
assert(params['work_search[category_ids][]'][1]=='21')
assert(params['work_search[word_count]']=='>50000' and params['work_search[date_from]']=='2026-01-01')
assert(params['work_search[sort_column]']=='revised_at' and params['work_search[sort_direction]']=='desc')
settings.tag_blacklist={{type='Freeform',name='Global tag'}}
Filter:executeSearch();table.remove(jobs,1)()
assert(requests[#requests]['work_search[excluded_tag_names]']:find('Global tag',1,true))
assert(not Filter.filter.exclude_additional_tags[2],'Global tags must not be added to the saved filter')
settings.tag_blacklist=nil
settings.tag_blacklist={{type='Rating',name='Explicit'},{type='Category',name='M/M'},
    {type='Warning',name='Major Character Death'}}
Filter:executeSearch();table.remove(jobs,1)()
local specials=requests[#requests]['work_search[excluded_tag_names]']
assert(specials:find('Explicit',1,true) and specials:find('M/M',1,true) and specials:find('Major Character Death',1,true))
settings.tag_blacklist=nil
settings.tag_blacklist={{type='Freeform',name='Changed after submission'}}
Filter:executeSearch()
local warning=shown[#shown]
assert(warning.title:find('Changed after submission',1,true) and #jobs==0)
warning.buttons[2][1].callback()
assert(#jobs==1);table.remove(jobs,1)()
assert(requests[#requests]['work_search[excluded_tag_names]']:find('Changed after submission',1,true))
assert(browser_options.blacklist==true)
Filter:executeSearch()
warning=shown[#shown]
warning.buttons[1][1].callback()
assert(#jobs==1);table.remove(jobs,1)()
assert(not requests[#requests]['work_search[excluded_tag_names]']:find('Changed after submission',1,true))
assert(requests[#requests]['work_search[excluded_tag_names]']:find('Excluded tag',1,true))
assert(browser_options.blacklist==false and settings.tag_blacklist[1].name=='Changed after submission')
settings.tag_blacklist=nil
-- Old scopes become editable included tags; editing remains isolated from storage.
Filter:UpdateFilterCrafter(settings.saved_filters.legacy)
Filter.filter.additional_tags[1]='Edited'
assert(settings.saved_filters.legacy.parameters.additional_tags[1]=='Old')
Filter.filter.exclude_categories={'22'}
Filter:executeSearch();table.remove(jobs,1)()
params=requests[#requests]
assert(params.tag_id==nil and params['work_search[freeform_names]']=='Edited,Fluff')
assert(params['work_search[excluded_tag_names]']=='F/M')
assert(params['work_search[excluded_tag_ids][]']==nil)
Filter:WorkTagsSubmenu()
for _,item in ipairs(widget.item_table) do
    assert(not item.text_func or not item.text_func():find('any type',1,true))
end
Filter:selectedFandoms()
assert(widget.item_table[4].text=='Bookmarked tags')
widget.item_table[4].callback()
widget.item_table[2].callback()
assert(Filter.filter.fandom_names[1]=='A fandom')
-- The migrated tag is editable in Additional Tags like every other freeform tag.
Filter:selectAdditionalTags()
for _,item in ipairs(widget.item_table) do
    if item.value=='Fluff' then item.callback();break end
end
shown[#shown].buttons[1][2].callback() -- Remove tag.
assert(Filter.filter.additional_tags[1]=='Edited' and #Filter.filter.additional_tags==1)
Filter:refreshMainMenu()
assert(writes==1,'Opening searches again must not repeat migration writes')
-- Wi-Fi continuation uses the submitted criteria, even after another filter opens.
Filter.filter={additional_tags={'Offline tag'}};deferred=false
Filter:executeSearch()
assert(type(deferred)=='function' and #jobs==0)
Filter.filter={main_tag='Another search'}
local resume=deferred;deferred=nil;resume();table.remove(jobs,1)()
assert(requests[#requests].tag_id==nil and requests[#requests]['work_search[freeform_names]']=='Offline tag')
Menu:onBrowseByTag('Fluff')
assert(Filter.filter.main_tag==nil and Filter.filter.additional_tags[1]=='Fluff' and widget.title=='Search works')
print('PASS: one work-search interface; direct include/exclude tags; global filters; persisted legacy migration; editable migrated tags; bookmarks; submitted criteria survive Wi-Fi and edits')
