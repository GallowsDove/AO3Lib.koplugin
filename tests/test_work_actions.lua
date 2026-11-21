dofile('tests/test_network.lua')
local Actions = require('ao3lib.ui.work_actions')
local History = require('ao3lib.library.history')
local UI = require('ui/uimanager')
local shown, closed = {}, {}
UI.show = function(_, widget) shown[#shown+1] = widget end
UI.close = function(_, widget)
    closed[widget] = true
    if widget.onCloseWidget then widget:onCloseWidget() end
end
UI.setDirty = function() end
require('ui/widget/menu').onClose=function(self) UI:close(self);return true end
local original = {id='action-work',path='/books/action.epub',title='A work',chapter_data={}}
local latest = {id=original.id,path=original.path,title=original.title,read=true,
    chapter_data={{id='1',name='First',read=true},{id='2',name='Second',read=false}}}
History.get = function(id) assert(id==original.id);return latest end
local writes, opened, detail, checked = 0, nil, nil, nil
History.update = function(work) assert(work==latest);writes=writes+1 end
local plugin = {menu_stack={},onOpenFanficReader=function(_, path, work, chapter)
    assert(path==original.path and work==latest);opened={work=work,chapter=chapter}
end,onShowFanficBrowser=function(_, works, fetch, title)
    assert(fetch==nil and title=='AO3 work details' and works.total==1)
    detail=works[1]
end}
package.loaded["ao3lib.ui.update_review"] = {showWork=function(owner, work)
    assert(owner==plugin and work==latest);checked=work
end}
local expected = {'Work details','Check for updates','Open for reading','Select chapter','Delete local copy','Cancel'}
local function menu(options)
    local result=Actions.show(plugin, original, options)
    local index=0
    for _,row in ipairs(result.buttons) do
        for _,button in ipairs(row) do index=index+1;assert(button.text==expected[index]) end
    end
    assert(index==#expected and not opened)
    return result
end
local dialog=menu()
dialog.buttons[1][1].callback()
assert(closed[dialog] and detail==latest and writes==0)
local remoteDetails={id=original.id,title='Remote metadata'}
dialog=menu{details=remoteDetails};dialog.buttons[1][1].callback()
assert(detail==remoteDetails and writes==0)
dialog=menu();dialog.buttons[1][2].callback()
assert(closed[dialog] and checked==latest and writes==0)
dialog=menu();dialog.buttons[2][2].callback()
local chapters=shown[#shown]
assert(closed[dialog] and chapters.title=='Select chapter')
assert(chapters.item_table[1].text=='✓ First' and chapters.item_table[2].text=='Second')
assert(writes==0 and not opened and #plugin._ao3_navigation==1)
chapters:onCloseWithKey()
assert(closed[chapters] and #plugin._ao3_navigation==0 and not opened)
dialog=menu();dialog.buttons[2][2].callback()
chapters=shown[#shown];chapters:onMenuSelect(chapters.item_table[2])
assert(opened.chapter==2 and writes==1 and latest.last_accessed)
opened=nil
dialog=menu();dialog.buttons[2][1].callback()
assert(opened.chapter==nil and writes==2)
opened=nil
History.get=function() return {id=original.id,path='/other/location.epub',chapter_data=latest.chapter_data} end
dialog=menu()
assert(dialog.buttons[2][2].enabled==false, 'Reading state from a different path leaked into the chapter picker')
dialog.buttons[2][2].callback()
assert(shown[#shown]==dialog and not opened)
print('PASS: shared management-first action order; offline details; current reading state; single-work review; explicit reading; chapter selection/cancel; missing chapter metadata')

local selected
Actions.show(plugin,original,{details=function(work) selected=work end}).buttons[1][1].callback()
assert(selected==original and detail==remoteDetails,'Local details callback must replace the duplicate browser action')
local author
local profile=require('main'):extend{showUserInfo=function(_,username,pseud) author={username,pseud} end}
profile:onShowAuthor('Writer');assert(author[1]=='Writer' and author[2]=='Writer')
profile:onShowAuthor('Pseud (account)');assert(author[1]=='account' and author[2]=='Pseud')
print('PASS: rendered detail routing; shared author/pseud navigation')
