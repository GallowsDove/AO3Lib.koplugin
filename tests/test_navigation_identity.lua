dofile('tests/test_network.lua')
local Nav=require('ao3lib.ui.navigation')
local Net=require('ao3lib.ao3.network')
Net.defer=function() return false end
Net.run=function(fn,...) return fn(...) end
local UI=require('ui/uimanager')
UI.setDirty=function() end
local owner={menu_stack={},ui={}}
local requests,opened=0,0
function owner:getWorksFromSeries(id)
    requests=requests+1;return true,{{id='work',title='Work'}}
end
function owner:onShowFanficBrowser(works,next_page,title,options)
    opened=opened+1
    local window={}
    Nav.bind(self,window,{identity=options.identity})
end
local Series=require('ao3lib.ui.subscriptions')
Series.openSeries(owner,42,'First')
assert(requests==1 and opened==1 and #owner._ao3_navigation==1)
assert(Nav.isCurrent(owner,Nav.key('series','42')))
Series.openSeries(owner,'42','Changed title')
assert(requests==1 and opened==1 and #owner._ao3_navigation==1,'Current series must not fetch or push another view')
local defer_calls=0
Net.defer=function() defer_calls=defer_calls+1;return true end
Series.openSeries(owner,42,'First')
assert(defer_calls==0,'Reopening the current series must not prompt for Wi-Fi')
Net.defer=function() return false end
local first=owner._ao3_navigation[1].window
local replacement={}
Nav.bind(owner,replacement,{replace=first,identity=Nav.key('series',42)})
Series.openSeries(owner,42,'First')
assert(requests==1 and #owner._ao3_navigation==1,'Repainting must preserve destination identity')
Series.openSeries(owner,43,'Second')
assert(requests==2 and opened==2 and #owner._ao3_navigation==2)
Series.openSeries(owner,42,'First')
assert(requests==3 and opened==3 and #owner._ao3_navigation==3,'A series underneath a different active view may be opened')
Nav.closeAll(owner)
local tag=Nav.key('tag','Fluff')
Nav.bind(owner,{}, {identity=tag})
local tag_fetches=0
owner.fetchFanficsByTag=function() tag_fetches=tag_fetches+1;return true,{} end
local shown
UI.show=function(_,dialog) shown=dialog end
UI.close=function() end
local Tags=require('ao3lib.ui.tag_actions')
Tags.show(owner,'Freeform','Fluff').buttons[1][1].callback()
assert(tag_fetches==0 and #owner._ao3_navigation==1)
Tags.show(owner,'Freeform','Other').buttons[1][1].callback()
assert(tag_fetches==1 and #owner._ao3_navigation==2)
Nav.closeAll(owner)
-- User profile identities include the pseud, not only the account.
local Fanfic=require('main')
local calls=0
local client=require('ao3lib.ao3.client')
client.getUserData=function(_,username,pseud)
    calls=calls+1;return {success=true,user_data={username=username,pseud=pseud}}
end
local Profile=require('ao3lib.ui.user_browser')
local oldShow=Profile.show
Profile.show=function() end
Nav.bind(owner,{}, {identity=Nav.key('user','Writer','Pseud')})
Fanfic.showUserInfo(owner,'writer','pseud')
assert(calls==0)
Fanfic.showUserInfo(owner,'Writer','Other')
assert(calls==1,'A different pseud is a different profile view')
Profile.show=oldShow
print('PASS: same series, tag and profile do not refetch or nest; identity survives repaint; distinct destinations remain accessible')
