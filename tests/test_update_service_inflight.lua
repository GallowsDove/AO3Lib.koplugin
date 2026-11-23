-- In-flight checks must survive suspend and stale worker completions.
package.path='./?.lua;'..package.path
local copy=require('ao3lib.core.table').deepCopy
local jobs,workers,saved,notifications={},{},nil,{}
local connected,fail_offline=true,false
package.loaded['ui/uimanager']={scheduleIn=function(_,_,fn) jobs[#jobs+1]=fn end,
    show=function(_,widget) notifications[#notifications+1]=widget end}
package.loaded['ui/widget/notification']={new=function(_,v) return v end}
package.loaded['ui/network/manager']={isConnected=function() return connected end}
package.loaded.gettext=function(s) return s end
package.loaded['ao3lib.core.config']={readSetting=function(_,_,default) return default end}
package.loaded['ao3lib.updates.store']={load=function() return nil end,
    save=function(value) saved=copy(value) end,flush=function(value) saved=copy(value);return true end}
package.loaded['ao3lib.updates.checks']={new=function(works)
    local entries={};for _,work in ipairs(works) do entries[#entries+1]={work=work,status='unchecked'} end
    return {entries=entries}
end,check=function(work)
    coroutine.yield()
    if fail_offline then return {work=work,status='error',error='Disconnected'} end
    return {work=work,status='current'}
end}
package.loaded['ao3lib.ao3.background']={wrap=function(fn,options)
    local co=coroutine.create(fn);workers[#workers+1]=co;assert(coroutine.resume(co))
end,isCancelled=function() return false end}
local function tick() assert(#jobs>0);table.remove(jobs,1)() end
local S=require('ao3lib.updates.service')
local session=S.add({{id='a',path='/a.epub'}})
assert(S.check(session.entries));tick()
assert(#workers==1 and session.busy and #saved.pending==1 and session.done==0,
    'The active request must be included in the checkpoint')
S.suspend();assert(#S.pending()==1 and not session.busy and #saved.pending==1)
assert(S.overlayState()==nil,'Suspending must hide the overlay')
assert(coroutine.resume(workers[1]))
assert(session.entries[1].status=='unchecked' and #S.pending()==1,'A stale request must not publish')
S.resume();tick();assert(#workers==2 and session.busy)
assert(coroutine.resume(workers[2]))
assert(session.entries[1].status=='current' and session.done==1 and #S.pending()==0)
assert(#notifications==1 and notifications[1].text:find('0 changed works',1,true),
    'A completed check should report even when no works changed')
assert(S.check(session.entries));tick()
connected=false;fail_offline=true
assert(coroutine.resume(workers[3]))
assert(#S.pending()==1 and not session.busy and session.pause_reason:find('disconnected',1,true),
    'Connection loss during a request must leave the work queued')
local _,_,paused=S.overlayState();assert(paused,'Connection loss must display paused progress')
connected=true;fail_offline=false;S.resume();tick()
assert(coroutine.resume(workers[4]))
assert(#S.pending()==0 and session.entries[1].status=='current' and #notifications==2)
print('PASS: in-flight checkpoint, suspend/requeue, stale worker cancellation, resume and completion notification')
