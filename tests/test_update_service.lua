package.path='./?.lua;'..package.path
local copy=require('ao3lib.core.table').deepCopy
local jobs,notifications={},{}
local connected,pending_connection=true,nil
local persisted,check_count,download_count=nil,0,0
local fs,local_works={},{}
local fail_id
package.loaded.gettext=function(s) return s end
package.loaded.logger={warn=function() end}
package.loaded.util={tableDeepCopy=copy}
package.loaded['ffi/util']={}
package.loaded['ui/uimanager']={scheduleIn=function(_,delay,callback) jobs[#jobs+1]=callback end,
    show=function(_,widget) notifications[#notifications+1]=widget end,setDirty=function() end}
package.loaded['ui/widget/notification']={new=function(_,args) return args end}
package.loaded['ui/network/manager']={isConnected=function() return connected end,
    runWhenConnected=function(_,callback) pending_connection=callback end}
package.loaded["ao3lib.ao3.background"]={available=function() return false end,
    wrap=function(callback,options)
        assert(options.silent and options.detached,'Checks must use an independent, silent worker scope')
        callback()
    end,isCancelled=function() return false end}
package.loaded['libs/libkoreader-lfs']={attributes=function(path) return copy(fs[path]) end}
package.loaded["ao3lib.library.epub"]={read=function(path) return copy(local_works[path]) end}
package.loaded["ao3lib.library.history"]={}
package.loaded["ao3lib.ao3.client"]={getWorkMetadata=function(_,id)
    check_count=check_count+1
    if id==fail_id then return {success=false,status=404,error='Removed'} end
    return {success=true,work_metadata={id=id,chapters='3/3',wordcount='2000',epub_link='https://example.test/'..id}}
end,downloadEpub=function() download_count=download_count+1;error('Background checks must never download') end}
package.loaded["ao3lib.updates.store"]={load=function() return copy(persisted) end,
    save=function(state) persisted=copy(state) end,flush=function(state) persisted=copy(state);return true end}
local function fixture(id)
    local work={id=id,path='/books/'..id..'.epub',title=id,chapters='2/3',wordcount='1000'}
    fs[work.path]={mode='file',size=100,modification=1,change=1}
    local_works[work.path]=copy(work)
    return work
end
local function tick() assert(#jobs>0);table.remove(jobs,1)() end
local function drain() local n=0;while #jobs>0 do n=n+1;assert(n<50);tick() end end
local a,b,c=fixture('a'),fixture('b'),fixture('c')
local S=require('ao3lib.updates.service')
local session=S.add({a,b,c})
local updates=0
local unsubscribe=S.subscribe(function() updates=updates+1 end)
assert(S.check(session.entries))
tick();assert(check_count==1 and S.busy() and #S.pending()==2)
unsubscribe();local updates_at_close=updates
fail_id='b'
drain()
assert(check_count==3 and download_count==0 and not S.busy() and updates==updates_at_close)
assert(#notifications==1 and notifications[1].timeout==3 and notifications[1].text:find('2 changed works; 1 checks failed',1,true))
assert(#persisted.pending==0 and persisted.entries[2].status=='unavailable')
-- Rechecking existing results is checkpointed by queue position, not merely
-- "unchecked" status. A restart does not turn selected results into updates.
S.check(session.entries);tick()
assert(check_count==4 and #persisted.pending==2)
for _,entry in ipairs(persisted.entries) do entry.selected=true end
jobs={};package.loaded["ao3lib.updates.service"]=nil
S=require('ao3lib.updates.service');session=S.get()
assert(not S.busy() and #S.pending()==2 and session.pause_reason:find('interrupted',1,true))
for _,entry in ipairs(session.entries) do assert(not entry.selected) end
assert(check_count==4 and download_count==0,'Loading a checkpoint started network activity')
fail_id=nil;S.check(S.pending());drain()
assert(check_count==6 and #notifications==2 and #S.pending()==0)
-- Suspend persists the remaining queue and resumes without rechecking work 1.
S.check(session.entries);tick();assert(check_count==7)
S.suspend();S.flush();drain();assert(check_count==7 and #S.pending()==2)
S.resume();drain();assert(check_count==9 and #notifications==3)
assert(notifications[3].text:find('3 changed works',1,true),'Completion summary lost the checks finished before suspend')
-- A lost connection pauses between requests, rather than marking every work
-- failed or repeatedly asking to turn Wi-Fi on while reading.
S.check(session.entries);tick();connected=false;tick()
assert(check_count==10 and not S.busy() and #S.pending()==2)
assert(session.pause_reason:find('disconnected',1,true) and not pending_connection)
connected=true;S.resume();drain();assert(check_count==12 and #notifications==4)
-- Explicit stop is durable and is never undone by an unrelated reconnect.
S.check(session.entries);tick();S.stop();drain();local before=check_count
S.resume();assert(check_count==before and not S.busy() and #S.pending()==2)
-- Closing/canceling the initial Wi-Fi prompt cannot strand the queue forever:
-- a later NetworkConnected event resumes it, without running the old callback twice.
connected=false;S.check(S.pending());local obsolete=pending_connection;pending_connection=nil
assert(S.busy() and check_count==before)
connected=true;S.resume();obsolete();drain()
assert(check_count==before+2 and not S.busy())
-- Adding a one-work check while a library check runs extends the same queue.
local d=fixture('d')
S.check(session.entries);S.add({d})
local extra
for _,entry in ipairs(session.entries) do if entry.work.id=='d' then extra=entry end end
S.check({extra});before=check_count;drain();assert(check_count==before+4)
assert(download_count==0)
-- Changed EPUBs invalidate persisted comparisons before explicit application.
S.flush();jobs={};fs[a.path].size=101;package.loaded["ao3lib.updates.service"]=nil
S=require('ao3lib.updates.service');session=S.get()
assert(session.entries[1].status=='unchecked' and not session.entries[1].remote)
print('PASS: detached queue; one completion notice; durable results/remaining rechecks; restart without downloads; suspend/resume; offline pause/reconnect; explicit Stop; canceled Wi-Fi prompts; shared batch queue; EPUB invalidation')
