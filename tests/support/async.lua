-- Real OS workers with a minimal deterministic UI adapter for host tests.
local ffi=require('ffi')
ffi.cdef[[int fork(void);int getpid(void);int waitpid(int,int*,int);int kill(int,int);void _exit(int);int usleep(unsigned int);]]
local H={jobs={},stack={},warnings={},children={},forks=0}
H.parent=tonumber(ffi.C.getpid())
H.ffi={template=function(s,...) local a={...};return (s:gsub('%%(%d)',function(i) return tostring(a[tonumber(i)]) end)) end,
runInSubProcess=function(fn)
    H.forks=H.forks+1
    if H.fail_fork then return nil,'simulated fork failure' end
    local pid=ffi.C.fork()
    if pid==0 then local ok,done=pcall(fn,tonumber(ffi.C.getpid()));ffi.C._exit(ok and done and 0 or 1) end
    if pid<0 then return nil,'fork failed' end
    H.children[tonumber(pid)]=true
    return tonumber(pid)
end,
isSubProcessDone=function(pid)
    if not H.children[pid] then return true end
    local status=ffi.new('int[1]')
    if ffi.C.waitpid(pid,status,1)==pid then H.children[pid]=nil;return true end
    return false
end,
terminateSubProcess=function(pid) ffi.C.kill(pid,15) end}
H.UI={nextTick=function(_,fn) H.jobs[#H.jobs+1]=fn end,
scheduleIn=function(_,_,fn) H.jobs[#H.jobs+1]=fn end,
setDirty=function() end,
show=function(_,w) H.stack[#H.stack+1]=w end,
close=function(_,w)
    for i=#H.stack,1,-1 do if H.stack[i]==w then table.remove(H.stack,i);break end end
    if w.dismiss_callback then w.dismiss_callback() end
end,
getTopmostVisibleWidget=function() return H.stack[#H.stack] end,
getNthTopWidget=function(_,n) return H.stack[#H.stack-n+1] end,
isWidgetShown=function(_,w) for _,v in ipairs(H.stack) do if v==w then return true end end;return false end}
function H.tick() assert(#H.jobs>0,'No scheduled job');table.remove(H.jobs,1)();ffi.C.usleep(1000) end
function H.drain()
    local deadline=os.time()+10
    while #H.jobs>0 do assert(os.time()<deadline,'Worker timed out');H.tick() end
    assert(not next(H.children),'A worker was not reaped')
end
function H.sleep(ms) ffi.C.usleep(ms*1000) end
function H.inChild() return tonumber(ffi.C.getpid())~=H.parent end
function H.read(p) local f=assert(io.open(p,'rb'));local s=f:read('*a');f:close();return s end
package.loaded['ffi/util']=H.ffi
package.loaded['ui/uimanager']=H.UI
package.loaded['ui/widget/infomessage']={new=function(_,t) return t end}
package.loaded.logger={warn=function(...) H.warnings[#H.warnings+1]={...} end,dbg=function() end,err=function() end}
return H
