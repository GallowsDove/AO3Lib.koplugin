dofile('tests/test_network.lua')
local UI=require('ui/uimanager')
UI.setDirty=function() end
local shown
UI.show=function(_,w) shown=w end
local Client=require('ao3lib.ao3.client')
local S=require('ao3lib.ui.subscriptions')
local requests,removed={},{}
local fail=false
Client.getSubscriptions=function(_,page,kind)
    requests[#requests+1]={page=page,kind=kind}
    if fail then return {success=false,error='Maintenance'} end
    return {success=true,subscriptions={{kind='User',target='Writer',title='Writer',subscription_id='9'}},next_page=page==1 and 2 or nil}
end
Client.deleteSubscription=function(_,id) removed[#removed+1]=id;return {success=true} end
local profile
local owner={menu_stack={},showUserInfo=function(_,u) profile=u end}
local window=S.show(owner)
window.updateItems=function() end
assert(window.item_table[1].text=='Type: All')
window.item_table[3].callback()
assert(shown.buttons[1][1].text=='Open')
shown.buttons[1][1].callback();assert(profile=='Writer')
window.item_table[3].callback();shown.buttons[2][1].callback()
assert(#removed==0 and shown.ok_text=='Unsubscribe')
shown.ok_callback();assert(removed[1]=='9' and #requests==2)
window.item_table[#window.item_table].callback()
assert(requests[#requests].page==2)
local old=window.item_table
fail=true;window.item_table[2].callback()
assert(window.item_table==old and shown.text=='Maintenance')
fail=false
window.item_table[1].callback();shown.buttons[3][1].callback()
assert(requests[#requests].kind=='Series' and requests[#requests].page==1)
local mutations=0
Client.getSubscriptionTarget=function() return {success=true,target_id='17',subscription_id='9'} end
Client.setSubscription=function(_,kind,id,sub)
    assert(kind=='User' and id=='17' and sub=='9');mutations=mutations+1;return {success=true}
end
S.manage(owner,'User','Writer','Writer')
assert(shown.buttons[1][1].text=='Unsubscribe' and mutations==0)
shown.buttons[1][1].callback();assert(mutations==1)
Client.getSubscriptionTarget=function() return {success=false,error='Maintenance'} end
S.manage(owner,'User','Writer','Writer')
assert(shown.text=='Maintenance' and mutations==1)
print('PASS: subscription list, profile navigation, unsubscribe confirmation, pagination, filters, failure retention and explicit author action')
-- Returning from a subscribed item's screen must reload the retained list,
-- whether Back comes from the header or PocketBook's physical button.
local Nav=require('ao3lib.ui.navigation')
local ticks={}
UI.nextTick=function(_,fn) ticks[#ticks+1]=fn end
UI.close=function(_,w) if w.onCloseWidget then w:onCloseWidget() end end
local function tick() assert(table.remove(ticks,1))() end
local empty=false
Client.getSubscriptions=function(_,page,kind)
    requests[#requests+1]={page=page,kind=kind}
    if fail then return {success=false,error='Maintenance'} end
    return {success=true,subscriptions=empty and {} or {{kind='User',target='Writer',title='Writer',subscription_id='9'}}}
end
local updates=0
window.updateItems=function() updates=updates+1 end
for _,back in ipairs{'onClose','onCloseWithKey'} do
    local child={onClose=function(self) UI:close(self) end}
    Nav.bind(owner,child)
    window.page=3
    local before=#requests
    child[back](child)
    assert(#requests==before,'Refresh must wait until the child is closed')
    tick()
    assert(#requests==before+1 and requests[#requests].kind=='Series')
    assert(window.page==3 and updates>0)
end
-- An unsubscribe made inside the child disappears on return. Failed refreshes
-- preserve the list; a queued refresh after closing the parent does nothing.
local function leaveChild()
    local child={onClose=function(self) UI:close(self) end}
    Nav.bind(owner,child);child:onCloseWithKey()
end
empty=true;leaveChild();tick()
assert(window.item_table[3].text=='No subscriptions on this page.')
old=window.item_table;fail=true;leaveChild();tick()
assert(window.item_table==old and shown.text=='Maintenance')
fail=false;leaveChild()
local before=#requests
Nav.closeAll(owner);tick()
assert(#requests==before)
print('PASS: header and hardware Back refresh subscriptions after closing the child; filter/position retained; removed items disappear; outages and closed lists are safe')
