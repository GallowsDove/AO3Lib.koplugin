dofile('tests/test_failures.lua')
local Client=require('ao3lib.ao3.client')
local parser=require('htmlparser')
local request
local form_action='/series/12/bookmarks'
local form={attributes={action=form_action},select=function() return {} end}
parser.parse=function()
    form.attributes.action=form_action
    return {select=function(_,selector)
        if selector=='#bookmark-form > form' then return {form} end
        return {}
    end}
end
require('ssl.https').request=function(req)
    request={url=req.url,body=req.source and req.source()}
    req.sink('ok');return 1,200,{}
end
Client.GetSessionStatus=function() return {success=true,logged_in=true,username='Reader'} end
Client.requestAO3Token=function() return {success=true,token='csrf'} end
Client.getAccountPseudID=function() return {success=true,pseud_id='7'} end
local result=Client:getUsersSeriesBookmark(12)
assert(result.success and not result.bookmark_id)
assert(request.url:match('/series/12$'))
form_action='/bookmarks/45'
result=Client:getUsersSeriesBookmark(12)
assert(result.success and result.bookmark_id=='45')
form_action='/series/999/bookmarks'
assert(not Client:getUsersSeriesBookmark(12).success)
assert(not Client:getUsersSeriesBookmark('../bad').success)
result=Client:updateBookmark(12,nil,'A note','Tag','Collection',true,false,'series')
assert(result.success and request.url:match('/series/12/bookmarks$') and request.body:find('bookmark%%5Bprivate%%5D=1'))
result=Client:updateBookmark(12,'45','Changed','','',false,true,'series')
assert(result.success and request.url:match('/bookmarks/45$') and request.body:find('_method=put'))
-- The series management menu opens the editor with the existing data, and
-- only closes it after a successful save or deletion.
local UI={}
package.loaded['ui/uimanager']=UI
package.loaded.gettext=function(value) return value end
local shown
UI.show=function(_,widget) shown=widget end
UI.close=function() end
local dialog_class={new=function(_,fields) fields.onShowKeyboard=function() end;return fields end}
package.loaded['ui/widget/buttondialog']=dialog_class
package.loaded['ui/widget/infomessage']=dialog_class
package.loaded['ao3lib.ui.bookmark_dialog']=dialog_class
package.loaded['ao3lib.ao3.network']={defer=function() return false end}
Client.getUsersSeriesBookmark=function() return {success=true,bookmark_id='45',bookmark_data={notes='Saved',private=true}} end
local saved,deleted
Client.updateBookmark=function(_,id,bid,notes,tags,collections,private,rec,kind)
    saved={id,bid,notes,tags,collections,private,rec,kind};return {success=true}
end
Client.deleteBookmark=function(_,id) deleted=id;return {success=true} end
package.loaded['ao3lib.ui.series_actions']=nil
local Actions=require('ao3lib.ui.series_actions')
local menu=Actions.show({}, {id=12,title='Series'})
menu.buttons[1][1].callback()
local editor=shown
assert(editor.title=='Bookmark series' and editor.current_fanfic.bookmarkID=='45' and editor.bookmark_notes_original=='Saved' and editor.bookmark_private)
assert(editor.save_dialog_callback{notes='New',tags='T',collections='C',private=true,rec=false})
assert(saved[1]==12 and saved[2]=='45' and saved[8]=='series')
assert(editor.delete_dialog_callback() and deleted=='45')
print('PASS: series bookmark form validation; create/update destinations; editor and delete')
