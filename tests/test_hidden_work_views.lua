dofile('tests/test_network.lua')
local View=require('ao3lib.ui.work_view')
package.loaded['ao3lib.library.blacklist']={match=function(work)
    return work.id=='1' and {'First tag','Second tag'} or {}
end}
package.loaded['ao3lib.ao3.mute_cache']={ensure=function() end,watch=function() end,unwatch=function() end,
    match=function(work) return work.id=='1' and {'MutedWriter'} or {} end}
local works={{id='1',title='Hidden',author='Writer'},{id='2',title='Visible',author='Writer'}}
local rendered,actions
local context={works=works,blacklist=true,mutes=true,network=function(fn) fn() end,
    rows=function(work) return {{work.title}} end,
    present=function(_,html,links) rendered,actions=html,links end}
local state=View.new(context);state:render()
assert(state:pageCount()==2 and rendered:find('First tag',1,true) and rendered:find('Second tag',1,true)
    and rendered:find('Muted author: MutedWriter',1,true))
actions[1]();assert(rendered:find('Hidden',1,true) and not rendered:find('Hidden because of:',1,true))
state:next();assert(state.index==2 and rendered:find('Visible',1,true))
context.blacklist=false
local muted=View.new(context);muted:render()
assert(rendered:find('Muted author: MutedWriter',1,true) and not rendered:find('First tag',1,true))
print('PASS: rendered works retain hidden reasons, reveal, independent blacklist toggle and page count')
