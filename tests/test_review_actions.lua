dofile('tests/test_updates.lua')
local UI=require('ui/uimanager')
local shown
UI.show=function(_,widget) shown=widget end
package.loaded['ao3lib.library.local_cache']={get=function() return {
    {id='changes',title='Changed work',author='First author',path='/books/changes.epub'},
    {id='failure',title='Failed work',author='Second author',path='/books/failure.epub'},
    {id='same',title='Unchanged work',author='Third author',path='/books/same.epub'},
} end,load=function() end}
local session,menu=require('ao3lib.ui.update_review').show({ui={}})
local changed,failed,current
for _,e in ipairs(session.entries) do
    if e.work.id=='changes' then changed=e elseif e.work.id=='failure' then failed=e else current=e end
end
changed.status='update';changed.remote={chapters='1/1'};changed.local_work={chapters='1/1'};changed.changes={'Words: 100 → 200'}
failed.status='error';failed.error='Connection failed'
current.status='current'
local function filter(index) menu.review_model.filters[index].callback() end
filter(1)
assert(#menu.item_table==1 and menu.item_table[1].entry==changed)
assert(menu.item_table[1].text:find('Text changed',1,true))
assert(not menu.item_table[1].text:find('1/1 → 1/1',1,true))
for _,row in ipairs(menu.item_table) do assert(row.entry,'Book list must not contain commands or status rows') end
menu:onMenuSelect(menu.item_table[1],{x=0.5})
assert(shown.title=='Work update details' and not changed.selected,'Title opens details without selecting')
assert(shown.buttons_table[1][1].text=='Select work')
shown.buttons_table[1][1].callback()
assert(changed.selected and menu.review_model.selected==1)
menu:onMenuSelect(menu.item_table[1],{x=0.05})
assert(not changed.selected,'Checkbox toggles independently')
package.loaded['ui/bidi'].mirroredUILayout=function() return true end
menu:onMenuSelect(menu.item_table[1],{x=0.95})
assert(changed.selected,'Checkbox position mirrors in RTL')
package.loaded['ui/bidi'].mirroredUILayout=function() return false end
filter(2)
assert(#menu.item_table==1 and menu.item_table[1].entry==failed and menu.item_table[1].mandatory=='Retry')
assert(not menu.review_model.select_all)
local retried=0
session.run=function(_,operation,targets) assert(operation=='check' and targets[1]==failed);retried=retried+1;return true end
menu:onMenuSelect(menu.item_table[1],{x=0.95})
assert(retried==1)
filter(3)
assert(#menu.item_table==3)
changed.local_work.chapters='7/10';changed.remote.chapters='8/10'
changed.changes={'1 new chapter · 7 → 8','Words: 43,199 → 46,494'}
menu.review_model.filters[1].callback()
menu:onMenuSelect(menu.item_table[1],{x=0.5})
local _,mentions=shown.text:gsub('1 new chapter','')
assert(mentions==1 and shown.text:find('Update available',1,true))
assert(shown.text:find('Words: 43,199 → 46,494',1,true))
assert(not shown.text:find('chapter(s)',1,true))
filter(3)
local more=menu.review_model.buttons[1][3]
assert(more.text=='More…')
more.callback()
assert(shown.title=='Update actions')
local cleared=false
for _,row in ipairs(shown.buttons) do
    if row[1].text=='Clear results' then row[1].callback();cleared=true;break end
end
assert(cleared and changed.status=='unchecked' and failed.status=='unchecked' and current.status=='unchecked')
assert(not changed.selected and #menu.item_table==3)
menu:onCloseWidget()
print('PASS: fixed controls, work-only rows, descriptive status, checkbox/title separation, RTL, filters, individual retry and secondary actions')
