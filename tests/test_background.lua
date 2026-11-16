package.path='./?.lua;'..package.path
local H=dofile('tests/support/async.lua')
local B=require('fanfic_background')
local anchor={item_table={}}
H.UI:show(anchor)
local result,completed
B.wrap(function()
    result=assert(B.await(function()
        assert(H.inChild(),'Work ran on UI process')
        return {body=string.rep('x',200000),name='Writer',n=42}
    end))
    completed=true
end)
assert(not completed,'A wrapped operation must give control back to UI')
H.tick();assert(not completed)
H.drain();assert(completed and #result.body==200000 and result.n==42)
-- Dismissal aborts the continuation, not merely its loading widget.
local continued,cancelled,cleaned=false,false,false
B.wrap(function()
    B.await(function() H.sleep(200);return 'late result' end,{cleanup=function() cleaned=true end})
    continued=true
end,{on_cancel=function() cancelled=true end})
H.tick()
local info=H.stack[#H.stack]
H.UI:close(info)
H.drain();assert(cancelled and cleaned and not continued)
-- Closing/navigating the originating screen invalidates the pending response.
B.wrap(function() B.await(function() H.sleep(100);return {} end);continued=true end)
H.tick();anchor.item_table={};H.drain();assert(not continued)
-- A new interactive request cancels the old one without cancelling itself.
local old,new=false,false
B.wrap(function() B.await(function() H.sleep(100);return {} end);old=true end)
H.tick()
B.wrap(function() B.await(function() return {} end);new=true end)
H.drain();assert(new and not old)
-- Worker failures report an error; they never rerun the task in the UI.
H.fail_fork=true
local failure
B.wrap(function() local _,err=B.await(function() error('must not execute') end);failure=err end)
H.drain();H.fail_fork=false
assert(failure:find('Could not start',1,true))
local err
B.wrap(function() local _;_,err=B.await(function() error('worker exception') end) end)
H.drain();assert(err:find('worker exception',1,true))
assert(#H.stack==1 and H.stack[1]==anchor)
print('PASS: real workers; large IPC; responsive continuations; cancellation/reaping/cleanup; stale screens; superseded requests; worker/fork failures')
