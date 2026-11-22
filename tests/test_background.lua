package.path='./?.lua;'..package.path
local H=dofile('tests/support/async.lua')
local B=require('ao3lib.ao3.background')
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
local progress_result
B.wrap(function()
    progress_result=B.await(function(report)
        report('Converting the book…');H.sleep(100);return 'done'
    end,{progress=true})
end)
H.tick()
local saw_progress=false
while #H.jobs>0 do
    H.tick()
    local top=H.stack[#H.stack]
    if top and top.text and top.text:find('Converting the book',1,true) then saw_progress=true end
end
assert(saw_progress and progress_result=='done','Worker progress must update the visible dialog')
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
