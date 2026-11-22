dofile('tests/test_network.lua')
local Browser=require('ao3lib.ui.work_browser')
local Config=require('ao3lib.core.config')
local UI=require('ui/uimanager')
local shown
UI.show=function(_,window) shown=window end
Config.readSetting=function(_,key,default)
    if key=='formatted_work_view' then return false end
    return default
end
package.loaded['ao3lib.library.blacklist']={match=function(work)
    return work.id=='1' and {'First tag','Second tag'} or {}
end}
package.loaded['ao3lib.ao3.mute_cache']={ensure=function() end,watch=function() end,unwatch=function() end,
    match=function(work) return work.id=='1' and {'MutedWriter'} or {} end}
local works={{id='1',title='Hidden',author='Writer'},{id='2',title='Visible',author='Writer'}}
local owner={menu_stack={}}
Browser:show({},works,nil,function() end,function() end,function() end,owner)
local window=shown
assert(#window.kv_pairs==30 and window.pages==2,'Hidden works must occupy one page')
assert(window.kv_pairs[1][1]=='Hidden work')
assert(window.kv_pairs[1][2]:find('First tag',1,true) and window.kv_pairs[1][2]:find('Second tag',1,true)
    and window.kv_pairs[1][2]:find('Muted author: MutedWriter',1,true))
window.kv_pairs[2].callback();window=shown
assert(window.kv_pairs[1][1]=='Hidden' and #window.kv_pairs==30 and window.pages==2)
-- Disabling the blacklist for a query must leave author muting in effect.
works={{id='1',title='Hidden',author='Writer'}}
Browser:show({},works,nil,function() end,function() end,function() end,owner,nil,{blacklist=false})
window=shown
assert(window.kv_pairs[1][2]:find('Muted author: MutedWriter',1,true)
    and not window.kv_pairs[1][2]:find('First tag',1,true))
print('PASS: legacy information view shares hidden reasons, reveal, independent blacklist toggle and page count')
