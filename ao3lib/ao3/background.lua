-- Fork CPU/network work; only the parent may publish results or update widgets.
local ffiutil = require('ffi/util')
local M = {}
local CANCELLED = {}
local scopes = setmetatable({}, {__mode='k'})
local request_revision=0
function M.isCancelled(err) return err == CANCELLED end
function M.isDetached()
    local co=coroutine.running()
    local scope=co and scopes[co]
    return scope and scope.detached or false
end
function M.available()
    return type(ffiutil.runInSubProcess)=='function' and type(ffiutil.isSubProcessDone)=='function'
        and type(ffiutil.terminateSubProcess)=='function'
end
local function readResult(path)
    local f=assert(io.open(path,'rb'))
    local size=f:seek('end');f:seek('set',0)
    if not size or size>64*1024*1024 then f:close();error('Background result exceeds size limit') end
    local bytes=f:read('*a');f:close()
    return require('string.buffer').decode(bytes)
end
function M.run(task,done,options)
    options=options or {}
    local UI=require('ui/uimanager')
    local job={}
    local named,path=pcall(os.tmpname)
    if not named then UI:nextTick(function() done(nil,'Cannot create background result file') end);return job end
    local result_path=path..'.result'
    local writing_path=path..'.writing'
    local progress_path=path..'.progress'
    local progress_writing=path..'.progress-writing'
    os.remove(path);os.remove(result_path);os.remove(writing_path)
    local function clean()
        os.remove(result_path);os.remove(writing_path);os.remove(progress_path);os.remove(progress_writing)
        if options.cleanup then pcall(options.cleanup) end
    end
    local function deliver(value,err)
        if job.delivered then return end
        job.delivered=true
        local ok,why=pcall(done,value,err)
        if not ok then require('logger').warn('AO3 background completion failed:',why) end
    end
    local poll
    function job:cancel()
        if self.finished or self.cancelled then return end
        self.cancelled=true
        if self.pid then pcall(ffiutil.terminateSubProcess,self.pid) end
        deliver(nil,CANCELLED)
    end
    local spawned,pid=pcall(ffiutil.runInSubProcess,function()
        local function report(value)
            if not options.on_progress or type(value)~='string' then return end
            local file=io.open(progress_writing,'wb')
            if file then
                local ok=file:write(value:sub(1,512));local closed=file:close()
                if ok and closed then os.rename(progress_writing,progress_path) else os.remove(progress_writing) end
            end
        end
        local ok,value=pcall(task,report)
        local packet={ok=ok}
        if ok then packet.value=value else packet.error=tostring(value) end
        local encoded=require('string.buffer').encode(packet)
        local file=assert(io.open(writing_path,'wb'))
        assert(file:write(encoded));assert(file:close())
        assert(os.rename(writing_path,result_path))
        return true
    end)
    if not spawned or not pid then
        clean();job.finished=true
        UI:nextTick(function() deliver(nil,'Could not start the background worker. Please try again.') end)
        return job
    end
    job.pid=pid
    local last_progress
    poll=function()
        if not job.cancelled and options.valid and not options.valid() then job:cancel() end
        if not job.cancelled and options.on_progress then
            local file=io.open(progress_path,'rb')
            if file then
                local value=file:read('*a');file:close()
                if value and value~=last_progress then last_progress=value;options.on_progress(value) end
            end
        end
        if not ffiutil.isSubProcessDone(pid) then UI:scheduleIn(0.1,poll);return end
        job.finished=true
        if job.cancelled then clean();return end
        local ok,result=pcall(readResult,result_path)
        -- Consumers may atomically move a staged download before cleanup.
        if ok and type(result)=='table' and result.ok then deliver(result.value)
        else deliver(nil,ok and type(result)=='table' and result.error or 'The background worker did not return a valid result.') end
        clean()
    end
    UI:scheduleIn(0.1,poll)
    return job
end
function M.wrap(callback,options)
    options=options or {}
    if not M.available() or coroutine.running() then return callback() end
    local UI=require('ui/uimanager')
    local co
    co=coroutine.create(function()
        local ok,err=pcall(callback)
        scopes[co]=nil
        if not ok then
            if M.isCancelled(err) then if options.on_cancel then options.on_cancel() end
            else require('logger').warn('AO3 background operation failed:',err)
                UI:show(require('ui/widget/infomessage'):new{text='AO3 operation failed. Please try again.'}) end
        end
    end)
    scopes[co]=options
    UI:nextTick(function() assert(coroutine.resume(co)) end)
end
function M.await(task,options)
    options=options or {}
    local co=coroutine.running()
    assert(co,'Background requests must run inside a continuation')
    local scope=scopes[co] or {}
    local detached=scope.detached or options.detached
    if not detached then request_revision=request_revision+1 end
    local request=request_revision
    local UI=require('ui/uimanager')
    local anchor=not detached and UI.getTopmostVisibleWidget and UI:getTopmostVisibleWidget()
    local depth=1
    while anchor and (anchor._ao3_background_info or anchor.timeout) do
        depth=depth+1
        anchor=UI.getNthTopWidget and UI:getNthTopWidget(depth)
    end
    local items=anchor and anchor.item_table
    local function valid()
        return (detached or request==request_revision) and (not scope.valid or scope.valid()) and (not options.valid or options.valid())
            and (not anchor or not UI.isWidgetShown or UI:isWidgetShown(anchor))
            and (not items or anchor.item_table==items)
    end
    local info
    local job
    local function showInfo(message)
        if info then info.dismiss_callback=nil;UI:close(info) end
        info=require('ui/widget/infomessage'):new{modal=true,_ao3_background_info=true,
            text=message..'\n\nTap or press Back to cancel.'}
        info.dismiss_callback=function() if job then job:cancel() end end
        UI:show(info)
    end
    if not (scope.silent or options.silent) then
        if options.progress then showInfo(options.progress_text or 'Preparing download…')
        else
            info=require('ui/widget/infomessage'):new{modal=true,_ao3_background_info=true,
                text=options.text or 'Contacting AO3…\n\nTap or press Back to cancel.'}
            info.dismiss_callback=function() if job then job:cancel() end end;UI:show(info)
        end
    end
    local waiting=true
    job=M.run(task,function(value,err)
        if info then info.dismiss_callback=nil;UI:close(info) end
        if waiting then
            local ok,why=coroutine.resume(co,value,err)
            if not ok then require('logger').warn('AO3 continuation failed:',why) end
        end
    end,{valid=valid,cleanup=options.cleanup,on_progress=options.progress and function(message)
        if info and valid() then showInfo(message) end
    end or nil})
    local value,err=coroutine.yield()
    waiting=false
    if M.isCancelled(err) or not valid() then error(CANCELLED,0) end
    return value,err
end
return M
