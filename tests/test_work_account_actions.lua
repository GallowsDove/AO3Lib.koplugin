dofile('tests/test_network.lua')
package.loaded['ao3lib.ui.reader']=nil
local UI=require('ui/uimanager')
local shown,closed
UI.show=function(_,w) shown=w end
UI.close=function(_,w) closed=w end
local H=require('ao3lib.library.history')
local Client=require('ao3lib.ao3.client')
local Actions=require('ao3lib.ui.work_account_actions')
local writes=0
local stored
H.checkIfStored=function() return stored end
H.update=function(work) writes=writes+1;assert(work==stored) end
local target={success=true,target_id='123',subscription_id=nil}
local mutations={}
Client.getSubscriptionTarget=function(_,kind,id) assert(kind=='Work' and id=='123');return target end
Client.setWorkSubscription=function(_,id,sub)
    mutations[#mutations+1]={id=id,sub=sub}
    return {success=true,subscription_id=not sub and '99' or nil}
end
Client.markForLaterWork=function(_,id,read) assert(id=='123' and not read);return {success=true} end
Client.kudosWork=function(_,id) assert(id=='123');return {success=true} end
local work={id='123',title='Remote story'}
local function menu()
    local dialog=Actions.show(work)
    local labels={}
    for _,row in ipairs(dialog.buttons) do
        for _,button in ipairs(row) do labels[button.text]=true end
    end
    assert(labels['Give kudos to work ♥'] and labels['Read comments'] and labels['Comment on work'] and labels['Bookmark work'])
    assert(not labels['Delete local copy'] and not labels['Open for reading'] and not labels['Check for updates'])
    return dialog
end
local d=menu();d.buttons[2][1].callback()
assert(work.subscriptionID=='99' and #mutations==1 and not mutations[1].sub and writes==0)
target.subscription_id='100' -- account state changed outside this menu
menu().buttons[2][1].callback()
assert(mutations[2].sub=='100' and work.subscriptionID==false and writes==0)
-- A stale Subscribe label must never unsubscribe an already-subscribed work.
menu().buttons[2][1].callback()
assert(#mutations==2 and work.subscriptionID=='100')
target={success=false,error='Maintenance'}
menu().buttons[2][1].callback()
assert(#mutations==2 and shown.text=='Maintenance')
menu().buttons[1][1].callback()
assert(work.markedForLater and writes==0,'Remote account actions must not create a downloaded-library entry')
stored={id='123',path='/books/story.epub',read=true,bookmarkContent={notes='Preserve me'},chapter_data={{read=true}}}
work.markedForLater=false
menu().buttons[1][1].callback()
assert(writes==1 and stored.markedForLater and stored.read and stored.chapter_data[1].read)
assert(stored.bookmarkContent.notes=='Preserve me' and stored.subscriptionID==nil)
-- Title holds use the same account menu regardless of download state; taps
-- on downloaded titles still open the existing local-management menu.
local Browser=require('ao3lib.ui.work_browser')
Browser.Fanfic={}
local rows=Browser:generateTable({}, {work},function() end,function() end)
rows[1].hold_callback()
assert(shown.buttons[2][1].text=='Unsubscribe from work')
rows[1].callback()
assert(shown.buttons[1][1].text=='Check for updates')
stored=nil
rows=Browser:generateTable({}, {work},function() end,function() end)
rows[1].hold_callback()
assert(shown.buttons[1][1].text=='Mark as read')
print('PASS: account-only title menu; subscribe/unsubscribe with live IDs; stale state and outages; remote-only actions; preserving downloaded state; unchanged short tap')

local Comments=require('ao3lib.ui.comments')
local showComments=Comments.show
local commentOwner,commentWork
Comments.show=function(owner,work) commentOwner,commentWork=owner,work end
local owner={menu_stack={}}
local account=Actions.show(work,owner)
for _,row in ipairs(account.buttons) do
    if row[1].text=='Read comments' then row[1].callback() end
end
assert(commentOwner==owner and commentWork==work)
Comments.show=showComments
