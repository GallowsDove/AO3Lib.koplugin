dofile('tests/test_network.lua')
local Browser=require('ao3lib.ui.work_browser')
local UI=require('ui/uimanager')
local shown,closed,opened={},{},{}
UI.show=function(_,dialog) shown[#shown+1]=dialog end
UI.close=function(_,dialog) closed[dialog]=true end
Browser.Fanfic={}
Browser.showAuthorInfoCallback=function(author) opened[#opened+1]=author end
local selected
local original=package.loaded['ao3lib.ui.user_actions']
package.loaded['ao3lib.ui.user_actions']={show=function(user) selected=user end}
local function row(work) return Browser:generateTable({}, {work},function() end,function() end)[2] end
row{id='1',title='Single',author='A Pseud',author_accounts={'the-account'}}.hold_callback()
assert(selected.username=='the-account' and selected.pseud=='A Pseud' )
selected=nil
row{id='2',title='Multi',author='First, Second',author_accounts={'first','second-account'}}.hold_callback()
local chooser=shown[#shown]
assert(chooser.title=='Choose author' and chooser.buttons[2][1].text=='Second' and not selected)
chooser.buttons[2][1].callback()
assert(closed[chooser] and selected.username=='second-account' and selected.pseud=='Second')
local count=#shown
row{id='3',title='Anon',author='Anonymous'}.hold_callback()
assert(#shown==count,'Anonymous works must not offer account actions')
package.loaded['ao3lib.ui.user_actions']=original
local View=require('ao3lib.ui.work_view')
local title_hold,author_hold=0,0
local work={id='4',title='Story',author='Writer'}
local rows=Browser:generateTable({}, {work},function() end,function() end)
rows[1].hold_callback=function() title_hold=title_hold+1 end
rows[2].hold_callback=function() author_hold=author_hold+1 end
local html,actions,holds=View.html(work,rows)
assert(html:find('ao3-action:1',1,true) and html:find('ao3-action:2',1,true))
assert(holds[1] and holds[2]);holds[1]();holds[2]()
assert(title_hold==1 and author_hold==1)
package.loaded['ui/gesturerange']={new=function(_,args) return args end}
local uri='ao3-action:2'
local box={getPosFromAbsPos=function() return {} end,getLinkByPosition=function() return {uri=uri} end}
View.bindTitleHold({htmlbox_widget=box},function(id) if holds[id] then holds[id]();return true end end)
assert(box:onHoldAO3Title(nil,{pos={}}) and author_hold==2)
uri='ao3-action:1';assert(box:onHoldAO3Title(nil,{pos={}}) and title_hold==2)
uri='other';assert(not box:onHoldAO3Title(nil,{pos={}}))
print('PASS: author holds in work rows and rendered links; account identities, chooser and anonymous works')

local Network=require('ao3lib.ao3.network')
Network.wrap=function(fn) return fn end
local selected_series,managed_series
package.loaded['ao3lib.ui.subscriptions']={openSeries=function(_,id,title) selected_series={id,title} end,
    manage=function(_,kind,id,title) managed_series={kind,id,title} end}
package.loaded['ao3lib.ui.series_actions']={show=function(_,series) managed_series={'Series',series.id,series.title} end}
local single={id='5',title='Story',series={{id=12,title='Only',position=2}}}
local series_row=Browser:generateTable({}, {single},function() end,function() end)[3]
local before=#shown
series_row.callback()
assert(#shown==before and selected_series[1]==12)
series_row.hold_callback()
assert(#shown==before and managed_series[1]=='Series' and managed_series[2]==12)
local multiple={id='6',title='Story',series={{id=12,title='One'},{id=34,title='Two'},{title='Unknown'}}}
series_row=Browser:generateTable({}, {multiple},function() end,function() end)[3]
series_row.hold_callback();chooser=shown[#shown]
assert(chooser.buttons[3][1].enabled==false)
chooser.buttons[2][1].callback()
assert(managed_series[2]==34 and managed_series[3]=='Two')
local series_rows=Browser:generateTable({}, {multiple},function() end,function() end)
local _,_,series_holds=View.html(multiple,series_rows)
assert(series_holds[3], 'Rendered series link must expose the same hold action')
print('PASS: single series opens directly; multi-series chooser and rendered hold manage the selected subscription')
