package.path='./?.lua;'..package.path
local copy=require('ao3lib.core.table').deepCopy
local jobs,notifications={},{}
local configured_delay,scheduled_delays=7,{}
package.loaded["ao3lib.core.config"]={readSetting=function(_,key,default) if key=="update_check_delay_seconds" then return configured_delay end;return default end}
local connected,pending_connection=true,nil
local persisted,check_count,download_count=nil,0,0
local fs,local_works={},{}
local fail_id
package.loaded.gettext=function(s) return s end
package.loaded.logger={warn=function() end}
package.loaded.util={tableDeepCopy=copy}
package.loaded['ffi/util']={}
package.loaded['ui/uimanager']={scheduleIn=function(_,delay,callback) jobs[#jobs+1]=callback;scheduled_delays[#scheduled_delays+1]=delay end,
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
assert(scheduled_delays[#scheduled_delays]==7,'Background checks must use the configured delay')
configured_delay=11
unsubscribe();local updates_at_close=updates
fail_id='b'
drain()
assert(scheduled_delays[4]==11,'Changed delay applies to the next gap')
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
connected=true;S.resume();obsolete()
local _,_,is_paused=S.overlayState()
assert(not is_paused and not session.pause_reason,'Wi-Fi continuation must show active progress when checking starts')
drain()
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
-- Retrying a subset must not consume or restart a stopped library queue.
fail_id='a';S.check(session.entries);tick();S.stop();drain()
local stopped_done,stopped_total=session.done,session.total
local function ids(entries)
    local values={};for _,entry in ipairs(entries) do values[#values+1]=entry.work.id end
    return table.concat(values,',')
end
local original_queue=ids(S.pending())
local entry_a,entry_b,entry_c
for _,entry in ipairs(session.entries) do
    if entry.work.id=='a' then entry_a=entry elseif entry.work.id=='b' then entry_b=entry elseif entry.work.id=='c' then entry_c=entry end
end
assert(entry_a.status=='unavailable' and original_queue~='')
fail_id=nil;local retry_start=check_count
assert(S.retry({entry_a}));drain()
assert(check_count==retry_start+1 and entry_a.status=='update')
assert(ids(S.pending())==original_queue and session.done==stopped_done and session.total==stopped_total)
S.resume();drain();assert(check_count==retry_start+1,'A retry must leave the original batch paused')
-- Failed works can also be members of the paused batch. Retry them without
-- changing that batch's order or progress, even across a KOReader restart.
entry_b.status='error';entry_c.status='error'
retry_start=check_count
assert(S.retry({entry_b,entry_c}));S.flush()
assert(persisted.parked and #persisted.parked.pending>0 and #persisted.pending==2)
jobs={};package.loaded['ao3lib.updates.service']=nil
S=require('ao3lib.updates.service');session=S.get()
assert(S.check(S.pending()));drain()
assert(check_count==retry_start+2 and ids(S.pending())==original_queue)
assert(session.done==stopped_done and session.total==stopped_total)
retry_start=check_count;S.resume();drain();assert(check_count==retry_start)
assert(S.check(S.pending()));drain()
assert(check_count==retry_start+3 and #S.pending()==0,'Continue must resume only the original batch')
-- Retry-After applies to retry controls as well as the main check button.
persisted.retry_at=os.time()+60;persisted.pause_reason='Rate limited';persisted.pending={}
package.loaded['ao3lib.updates.service']=nil
S=require('ao3lib.updates.service');local ok,why=S.retry({S.get().entries[1]})
assert(not ok and why:find('seconds',1,true),'Retry must explain the remaining wait')
print('PASS: single and multiple retries isolate the paused queue, preserve progress through restart, and honor Retry-After')
