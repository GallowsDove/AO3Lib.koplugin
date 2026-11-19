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
local fanfic={executeSearch=function(_,params)
    requests[#requests+1]=params
    return true, {total=0}
end,onShowFanficBrowser=function() opened=opened+1 end}
Menu.menuWidget,Menu.fanfic=widget,fanfic
Menu:onSearchFanficMenu()
assert(widget.item_table[1].text=='Search works')
for _,item in ipairs(widget.item_table) do
    assert(not item.text:find('Browse works by',1,true) and item.text~='Search using Filter search')
end
widget.item_table[1].callback()
assert(widget.title=='Search works' and widget.item_table[1].text=='New search')
assert(widget.item_table[2].text=='Saved filters:','Named saved filters must remain visible')
widget.item_table[1].callback()
assert(widget.item_table[1].text:find('Work Info',1,true))
for _,item in ipairs(widget.item_table) do
    assert(not item.text_func or not item.text_func():find('Within tag',1,true))
end
assert(writes==1 and settings.saved_filters.legacy.parameters.main_tag==nil)
assert(settings.saved_filters.legacy.parameters.additional_tags[2]=='Fluff')
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
assert(params['work_search[excluded_tag_names]']=='Excluded tag,Graphic Depictions Of Violence,F/M')
assert(params['work_search[excluded_tag_ids][]']==nil)
assert(params['exclude_work_search[category_ids][]']==nil)
assert(params['work_search[category_ids][]'][1]=='21')
assert(params['work_search[word_count]']=='>50000' and params['work_search[date_from]']=='2026-01-01')
assert(params['work_search[sort_column]']=='revised_at' and params['work_search[sort_direction]']=='desc')
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
