local Updates=require("ao3lib.updates.checks")
local Store=require("ao3lib.updates.store")
local M={}
local UI=require("ui/uimanager")
local session,queue={},{}
local batch={}
local subscribers={}
local running,suspended,explicit_stop=false,false,false
local active_entry
local parked
local generation=0
local notification_sent=true
local function notify()
    for callback in pairs(subscribers) do pcall(callback,session) end
end
local function id(entry) return tostring(entry.work.id) .. "\n" .. tostring(entry.work.path) end
local function pendingIds()
    local out={}
    if active_entry then out[#out+1]=id(active_entry) end
    for _,entry in ipairs(queue) do out[#out+1]=id(entry) end;return out
end
local function requeueActive()
    if active_entry then table.insert(queue,1,active_entry);active_entry=nil end
    session.active_entry=nil
end
local function keys(set)
    local out={};for key in pairs(set) do out[#out+1]=key end;return out
end
local function parkedState()
    if not parked then return end
    local pending={};for _,entry in ipairs(parked.queue) do pending[#pending+1]=id(entry) end
    return {pending=pending,batch=keys(parked.batch),done=parked.done,total=parked.total,
        pause_reason=parked.pause_reason,retry_at=parked.retry_at,notification_sent=parked.notification_sent}
end
local function checkpoint()
    if not session or #session.entries==0 then return end
    local batch_ids={};for key in pairs(batch) do batch_ids[#batch_ids+1]=key end
    Store.save({version=1,entries=session.entries,pending=pendingIds(),busy=running,
        operation=session.operation,pause_reason=session.pause_reason,retry_at=session.retry_at,
        explicit_stop=explicit_stop,done=session.done or 0,total=session.total or 0,batch=batch_ids,parked=parkedState()})
end
local function showComplete()
    if notification_sent then return end
    notification_sent=true
    local changed,failed=0,0
    for _,entry in ipairs(session.entries) do
        if batch[id(entry)] then
            if entry.status=="update" or entry.status=="updated" or entry.status=="review" then changed=changed+1 end
            if entry.status=="error" or entry.status=="unavailable" then failed=failed+1 end
        end
    end
    local _=require("gettext")
    local text=string.format(_("%d changed works; %d checks failed"),changed,failed)
    local Notice=require("ui/widget/notification")
    UI:show(Notice:new{text=text,timeout=3})
end
local function connected()
    local ok,Network=pcall(require,"ui/network/manager")
    return not ok or not Network.isConnected or Network:isConnected()
end
local schedule=function(delay,fn) UI:scheduleIn(delay,fn) end
local function persistResumeState()
    local state=Store.load()
    if type(state)~="table" then return end
    local works={}
    for _,entry in ipairs(state.entries or {}) do
        entry.selected=false
        if entry.work then works[#works+1]=entry.work end
    end
    session=Updates.new(works,{entries=state.entries})
    local byid={};for _,entry in ipairs(session.entries) do byid[id(entry)]=entry end
    queue={}
    for _,key in ipairs(state.pending or {}) do if byid[key] then queue[#queue+1]=byid[key] end end
    for _,key in ipairs(state.batch or state.pending or {}) do batch[key]=true end
    if type(state.parked)=='table' then
        local saved=state.parked
        parked={queue={},batch={},done=saved.done,total=saved.total,pause_reason=saved.pause_reason,
            retry_at=saved.retry_at,notification_sent=saved.notification_sent}
        for _,key in ipairs(saved.pending or {}) do if byid[key] then parked.queue[#parked.queue+1]=byid[key] end end
        for _,key in ipairs(saved.batch or {}) do parked.batch[key]=true end
    end
    if #queue>0 then session.pause_reason="Update checks were interrupted and are ready to resume." end
    session.retry_at=state.retry_at
    explicit_stop=state.explicit_stop or false
    session.done=state.done or 0;session.total=state.total or 0
    notification_sent=#queue==0
end
persistResumeState()
local function startNext()
    if running or suspended or explicit_stop or session.closed then return end
    if #queue==0 then
        showComplete()
        if parked then
            local retry_at=session.retry_at
            queue,batch=parked.queue,parked.batch
            session.done,session.total=parked.done,parked.total
            session.pause_reason=parked.pause_reason or "Stopped by user."
            session.retry_at=math.max(retry_at or 0,parked.retry_at or 0)
            if session.retry_at==0 then session.retry_at=nil end
            notification_sent=parked.notification_sent
            explicit_stop=true;parked=nil
        end
        checkpoint();notify();return
    end
    if session.retry_at and os.time()<session.retry_at then return end
    if not connected() then
        session.pause_reason="AO3 update checks paused because Wi-Fi is disconnected."
        if session.done==0 then
            running=true;session.busy=true
            local token=generation
            local manager=require("ui/network/manager")
            if manager.runWhenConnected then
                manager:runWhenConnected(function()
                    if token~=generation or suspended or explicit_stop then return end
                    running=false;session.busy=false;session.pause_reason=nil;startNext()
                end)
            else running=false;session.busy=false end
        else running=false;session.busy=false end
        checkpoint();notify();return
    end
    local Network=require("ui/network/manager")
    if Network.runWhenConnected and not connected() then return end
    running=true;session.busy=true
    local token=generation
    local entry=table.remove(queue,1)
    active_entry=entry;session.active_entry=entry
    session.operation=session.operation or "check"
    checkpoint();notify()
    schedule(0,function()
        if token~=generation or suspended or session.closed then return end
        local operation=session.operation
        require("ao3lib.ao3.background").wrap(function()
            local ok,result=pcall(operation=="update" and Updates.apply or Updates.check,
                operation=="update" and entry or entry.work)
            if token~=generation or suspended or session.closed then return end
            if not ok and require("ao3lib.ao3.background").isCancelled(result) then
                requeueActive()
                running=false;session.busy=false;checkpoint();notify();return
            end
            if (not ok or not result or result.status=='error') and not connected() then
                requeueActive();running=false;session.busy=false
                session.pause_reason="AO3 update checks paused because Wi-Fi is disconnected."
                checkpoint();notify();return
            end
            active_entry=nil;session.active_entry=nil
            session.done=(session.done or 0)+1
            if not ok then result={status="error",error=tostring(result),failure={error=tostring(result)}} end
            if operation=="check" and ok then
                for k in pairs(entry) do entry[k]=nil end
                for k,v in pairs(result) do entry[k]=v end
            elseif operation=="update" and ok and result.success then
                entry.work=result.work;entry.status="updated";entry.selected=false;entry.error=nil;entry.failure=nil
                entry.missing_images=result.missing_images;entry.move_error=result.move_error
            else
                entry.status=result.status or "error";entry.error=result.error
                entry.failure=result.failure or {error=result.error,status=result.status,retry_later=result.retry_later,
                    unexpected_response=result.unexpected_response,response_headers=result.response_headers}
            end
            if entry.failure and entry.failure.status==404 then entry.status="unavailable" end
            if entry.failure and entry.failure.retry_later then
                session.pause_reason=entry.error or "AO3 asked us to retry later."
                local headers=entry.failure.response_headers or {}
                session.retry_at=os.time()+tonumber(headers["retry-after"] or headers["Retry-After"] or 60)
            end
            checkpoint();notify()
            if #queue>0 and not session.pause_reason then
                schedule(require("ao3lib.updates.pacing").delay(operation),function()
                    running=false;session.busy=false;startNext()
                end)
            else
                running=false;session.busy=false;startNext()
            end
        end,{silent=true,detached=true,valid=function()
            return token==generation and not suspended and not session.closed
        end})
    end)
end
function M.add(works)
    if not session or not session.entries then session=Updates.new({}) end
    local index={};for _,entry in ipairs(session.entries) do index[id(entry)]=entry end
    for _,work in pairs(works or {}) do
        local key=tostring(work.id).."\n"..tostring(work.path)
        if not index[key] then
            local entry={work=work,status="unchecked",selected=false}
            session.entries[#session.entries+1]=entry;index[key]=entry
        elseif not running and index[key].status~='unchecked' then
            -- A comparison is only valid for the EPUB fingerprint it checked.
            -- Keep the entry identity so any paused queue still refers to it.
            local entry=index[key]
            local checked=Updates.new({work},{entries={entry}}).entries[1]
            if checked~=entry then
                for field in pairs(entry) do entry[field]=nil end
                for field,value in pairs(checked) do entry[field]=value end
            end
        end
    end
    checkpoint();notify();return session
end
function M.check(targets)
    if not session or not session.entries then M.add(targets or {}) end
    if session.retry_at and os.time()<session.retry_at then
        local _=require('gettext')
        return nil,string.format(_('AO3 requested a pause. Try again in %d seconds.'),math.ceil(session.retry_at-os.time()))
    end
    if not running and #queue==0 and not active_entry then batch={} end
    if not running then session.pause_reason=nil;session.retry_at=nil;session.operation="check" end
    explicit_stop=false;notification_sent=false
    local seen={};if active_entry then seen[id(active_entry)]=true end
    for _,e in ipairs(queue) do seen[id(e)]=true end
    for _,entry in ipairs(targets or {}) do
        local matched
        for _,candidate in ipairs(session.entries) do if candidate==entry or id(candidate)==id(entry) then matched=candidate;break end end
        matched=matched or entry
        batch[id(matched)]=true
        if not seen[id(matched)] then queue[#queue+1]=matched;seen[id(matched)]=true end
    end
    if not running then session.done=0 end
    session.total=(session.done or 0)+#queue+(active_entry and 1 or 0);checkpoint();startNext();return true
end
-- Retry a subset without consuming the paused batch. Both queues are saved,
-- so suspend or exit during a retry cannot discard the original work list.
function M.retry(targets)
    if running or session.busy then return nil,'An update check is already running.' end
    if session.retry_at and os.time()<session.retry_at then
        local _=require('gettext')
        return nil,string.format(_('AO3 requested a pause. Try again in %d seconds.'),math.ceil(session.retry_at-os.time()))
    end
    if parked then return nil,'Continue the paused retry before starting another.' end
    if #queue>0 then
        parked={queue=queue,batch=batch,done=session.done,total=session.total,
            pause_reason=session.pause_reason,retry_at=session.retry_at,notification_sent=notification_sent}
        queue={};batch={}
    end
    return M.check(targets)
end
function M.update(targets)
    if running then return nil,"An update is already running." end
    session.operation="update";session.pause_reason=nil;explicit_stop=false
    local seen={};for _,entry in ipairs(targets or {}) do if not seen[id(entry)] then queue[#queue+1]=entry;seen[id(entry)]=true end end
    session.done=0;session.total=#queue;notification_sent=false;startNext();return true
end
function M.pending() return queue end
function M.get() return session end
function M.busy() return running end
function M.overlayState()
    if suspended or session.operation~='check' then return end
    if not explicit_stop and #queue>0 and session.pause_reason
            and session.pause_reason:find('disconnected',1,true) then
        return session.done or 0,session.total or 0,true
    end
    if session.busy then return session.done or 0,session.total or 0,false end
end
function M.subscribe(callback) subscribers[callback]=true;return function() subscribers[callback]=nil end end
function M.stop()
    generation=generation+1;requeueActive();running=false;session.busy=false;explicit_stop=true
    session.pause_reason="Stopped by user.";checkpoint();notify()
end
function M.suspend()
    suspended=true;generation=generation+1;requeueActive();running=false;session.busy=false;checkpoint();notify()
end
function M.resume()
    suspended=false
    if not explicit_stop then
        if session.pause_reason and session.pause_reason:find("disconnected",1,true) then session.pause_reason=nil end
        startNext()
    end
end
function M.flush() checkpoint();return Store.flush({version=1,entries=session.entries,pending=pendingIds(),busy=running,
    operation=session.operation,pause_reason=session.pause_reason,retry_at=session.retry_at,
    explicit_stop=explicit_stop,done=session.done or 0,total=session.total or 0,parked=parkedState(),batch=(function()
        local ids={};for key in pairs(batch) do ids[#ids+1]=key end;return ids
    end)()}) end
local overlay_ok,overlay_err=pcall(function() require('ao3lib.ui.update_overlay').attach(M) end)
if not overlay_ok then pcall(function() require('logger').warn('AO3 update overlay unavailable:',overlay_err) end) end
return M
