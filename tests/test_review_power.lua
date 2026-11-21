-- Real review lifecycle with a reference-counted, reversible power hold.
dofile('tests/test_updates.lua')
package.loaded['ao3lib.ui.awake']=nil
local share={}
package.loaded.pluginshare=share
local UI=require('ui/uimanager')
local prevented,allowed=0,0
UI.preventStandby=function() prevented=prevented+1 end
UI.allowStandby=function() allowed=allowed+1;assert(allowed<=prevented) end
package.loaded['ao3lib.library.local_cache']={get=function() return {} end,load=function() end}
local Review=require('ao3lib.ui.update_review')
local first,one=Review.show({ui={}})
assert(share.pause_auto_suspend==true and prevented==1 and allowed==0)
local second,two=Review.show({ui={}})
assert(prevented==1)
one:onCloseWidget();one:onCloseWidget()
assert(share.pause_auto_suspend==true and allowed==0,'A second review still holds power prevention')
two:onCloseWidget();two:onCloseWidget()
assert(share.pause_auto_suspend==nil and allowed==1,'Final close must restore power behavior exactly once')
share.pause_auto_suspend=true
local _,three=Review.show({ui={}})
three:onCloseWidget()
assert(share.pause_auto_suspend==true and prevented==2 and allowed==2,'An existing power hold must survive review close')
-- Leaving an active replacement screen invalidates its pending download.
local session,four=Review.show({ui={}})
session.busy=true;session.operation='update'
local generation=session.generation
four:onCloseWidget()
assert(not session.busy and session.generation>generation)
assert(prevented==allowed)
print('PASS: review pauses autosuspend/standby; overlapping holds, repeated closes and existing settings preserved; active replacements stopped on close')
