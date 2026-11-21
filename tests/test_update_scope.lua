dofile('tests/test_updates.lua')
local Scope=require('ao3lib.ui.update_scope')
assert(Scope.matches({authors={'Writer','Coauthor'},fandoms={'Tag, with comma','Other'}},{kind='author',value='Coauthor'}))
assert(Scope.matches({author='Writer, Coauthor'},{kind='author',value='Coauthor'}))
assert(not Scope.matches({author='WriterTwo'},{kind='author',value='Writer'}))
assert(Scope.matches({author=' '},{kind='author',value='Anonymous'}))
assert(Scope.matches({fandoms={'Tag, with comma'}},{kind='fandom',value='Tag, with comma'}))
local groups=Scope.groups({{work={authors={'Writer','Writer'}}},{work={author='Writer'}}},'author')
assert(#groups==1 and groups[1].count==2)
local UI=require('ui/uimanager')
local shown,worker
UI.show=function(_,w) shown=w end
UI.close=function() end
local works={
    {id='a',path='/books/a.epub',title='A',authors={'Writer'},author='Writer',fandoms={'Fandom'}},
    {id='b',path='/books/b.epub',title='B',authors={'Writer','Other'},author='Writer, Other',fandoms={'Other Fandom'}},
    {id='c',path='/books/c.epub',title='C',authors={'Other'},author='Other',fandoms={'Fandom'}},
}
package.loaded['ao3lib.library.local_cache']={get=function() return works end,
    load=function(_,done) worker=done;return {cancel=function() end} end}
local Review=require('ao3lib.ui.update_review')
local session,menu=Review.show({ui={}},{kind='author',value='Writer'})
assert(menu.review_model.total==2 and menu.review_model.scope_label=='Author: Writer')
local calls={}
session.run=function(_,operation,targets,refresh)
    local ids={};for _,entry in ipairs(targets) do ids[#ids+1]=entry.work.id end
    calls[#calls+1]={operation=operation,ids=table.concat(ids,',')}
    return true
end
menu.review_model.buttons[1][1].callback()
assert(calls[1].operation=='check' and calls[1].ids=='a,b')
for _,entry in ipairs(session.entries) do
    entry.status='update';entry.remote={chapters='1/1'};entry.local_work={chapters='1/1'};entry.changes={'Words: 1 → 2'}
end
menu.review_model.filters[1].callback()
menu.review_model.select_all.callback()
assert(menu.review_model.selected==2)
menu.review_model.buttons[1][2].callback()
assert(calls[2].operation=='update' and calls[2].ids=='a,b')
-- Changing scope clears previous selections and keeps unrelated books out.
menu.review_model.scope.callback()
assert(shown.title=='Check updates for')
shown.buttons[2][1].callback()
assert(shown.title=='Choose author')
for _,row in ipairs(shown.item_table) do if row.text=='Other (2)' then row.callback();break end end
assert(menu.review_model.total==2 and menu.review_model.scope_label=='Author: Other' and menu.review_model.selected==0)
menu.review_model.filters[3].callback()
assert(#menu.item_table==2 and menu.item_table[1].entry.work.id=='b' and menu.item_table[2].entry.work.id=='c')
-- Cache validation adds all works to the session, but only matching ones to scope.
works[#works+1]={id='d',path='/books/d.epub',title='D',author='Writer'}
works[#works+1]={id='e',path='/books/e.epub',title='E',author='Other'}
worker(works)
assert(menu.review_model.total==3 and #menu.item_table==3)
menu.review_model.buttons[1][1].callback()
assert(calls[#calls].ids=='e','Only the unchecked matching work needs checking')
-- Recheck and clear results are scoped too.
local recheck,clear
for _,action in ipairs(menu.review_model.more) do
    if action.text=='Recheck all' then recheck=action end
    if action.text=='Clear results' then clear=action end
end
recheck.callback();assert(calls[#calls].ids=='b,c,e')
clear.callback()
for _,entry in ipairs(session.entries) do if entry.work.id=='a' then assert(entry.status=='update') end end
-- A scope change also cancels an old Wi-Fi continuation before requests start.
local pending
local network=require('ao3lib.ao3.network')
local run=network.run
network.run=function(callback) pending=callback end
menu.review_model.buttons[1][1].callback()
menu.review_model.scope.callback();shown.buttons[1][1].callback()
local before=#calls
pending();assert(#calls==before)
network.run=run
assert(menu.review_model.total==5 and menu.review_model.scope_label=='Entire library')
-- Completion filtering is optional and combines with author/fandom scope.
assert(Scope.isComplete({chapters='1/1'}))
assert(Scope.isComplete({chapters=' 3 / 3 '}))
assert(not Scope.isComplete({chapters='2/3'}))
assert(not Scope.isComplete({chapters='1/?'}))
assert(not Scope.isComplete({chapters='?/?'}))
assert(Scope.isComplete({iswip='Complete'}))
assert(Scope.matches({chapters='1/1'},{kind='library'}),'Completed works remain eligible by default')
assert(not Scope.matches({chapters='1/1'},{incomplete_only=true}))
assert(Scope.matches({chapters='?/?'},{incomplete_only=true}),'Unknown completion must not be silently excluded')
for _,entry in ipairs(session.entries) do
    entry.work.chapters=(entry.work.id=='a' or entry.work.id=='c') and '1/1' or '1/?'
end
menu.review_model.scope.callback()
local incomplete=shown.buttons[4][1]
assert(incomplete.text=='Incomplete works only' and not incomplete.checked_func())
incomplete.callback()
assert(menu.review_model.total==3 and menu.review_model.scope_label=='Entire library · Incomplete only')
menu.review_model.buttons[1][1].callback()
assert(calls[#calls].ids=='b,d,e','Checks must exclude completed works')
menu.review_model.scope.callback();shown.buttons[2][1].callback()
local author_row
for _,row in ipairs(shown.item_table) do if row.text=='Writer (2)' then author_row=row end end
assert(author_row,'Author picker counts must respect completion filtering')
author_row.callback()
assert(menu.review_model.total==2 and menu.review_model.scope_label=='Author: Writer · Incomplete only')
menu.review_model.buttons[1][1].callback()
assert(calls[#calls].ids=='b,d')
menu.review_model.scope.callback()
assert(shown.buttons[4][1].checked_func())
shown.buttons[4][1].callback()
assert(menu.review_model.total==3 and menu.review_model.scope_label=='Author: Writer','Filter can be disabled without changing author')
menu:onCloseWidget()
print('PASS: optional incomplete-only filter; complete/unfinished/unknown metadata; combined author scope; filtered group counts; completed works included by default')
print('PASS: exact author/coauthor/fandom scopes; scoped checks, updates, counts and clearing; late cache merges; selection reset; stale Wi-Fi continuation ignored')

-- Downloaded-library reading filters must stay fixed when opening review.
local subset,subset_menu=Review.showWorks({ui={}},{works[2],works[4]},'Writer · Unread')
assert(subset_menu.library_model==nil and subset_menu.review_model.total==2)
assert(subset_menu.review_model.scope==nil and subset_menu.review_model.scope_label=='Writer · Unread')
assert(subset_menu.title=='Updates: Writer · Unread')
local subset_ids
subset.run=function(_,operation,targets)
    assert(operation=='check')
    local ids={};for _,entry in ipairs(targets) do ids[#ids+1]=entry.work.id end
    subset_ids=table.concat(ids,',');return true
end
subset_menu.review_model.buttons[1][1].callback()
assert(subset_ids=='b,d','Filtered library review must not expand into all works from a previous review')
subset_menu:onCloseWidget()
print('PASS: downloaded-library subset review keeps exact work/path membership and disables scope expansion')
