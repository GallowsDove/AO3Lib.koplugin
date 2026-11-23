-- Run from the plugin directory: luajit tests/test_history_background.lua
package.path='./?.lua;'..package.path
local function copy(t) if type(t)~='table' then return t end;local o={};for k,v in pairs(t) do o[k]=copy(v) end;return o end
local function stub(n,v) package.loaded[n]=v end
local fs,encoded,tasks,children={}, {},{},{}
local encodes,reads,forks=0,0,0
local encoding_context={}
local in_page,in_child,fail_encode,fail_fork=false,false,false,false
local real_io,real_os=io,os
local serial=0
io={open=function(path,mode)
    assert(not in_page,'Page-turn handlers must not access history files')
    if mode=='r' then
        reads=reads+1;if not fs[path] then return nil,'missing' end
        return {read=function() return fs[path] end,close=function() return true end}
    end
    fs[path]=''
    return {write=function(_,s) fs[path]=fs[path]..s;return true end,close=function() return true end}
end}
os={tmpname=function() serial=serial+1;return '/tmp/progress-'..serial end,
    remove=function(p) fs[p]=nil end,
    rename=function(a,b) if not fs[a] then return nil,'missing temporary' end;fs[b]=fs[a];fs[a]=nil;return true end}
stub('dkjson',{encode=function(data)
    assert(not in_page,'Page-turn handlers must not serialize history')
    encodes=encodes+1
    encoding_context[encodes]=in_child and 'child' or 'parent'
    if fail_encode then return nil,'simulated encoding failure' end
    local key='snapshot-'..encodes;encoded[key]=copy(data);return key
end,decode=function(key) return copy(encoded[key]) end})
local temp_sequence=0
stub('ao3lib.core.tempfile',{reserve=function(prefix)
    temp_sequence=temp_sequence+1
    local name=prefix..temp_sequence;fs[name]='';return name
end})
stub('ao3lib.core.persistent',{path=function(name) return '/history/'..name end})
stub('libs/libkoreader-lfs',{attributes=function(path)
    if fs[path] then return {size=#fs[path],modification=fs[path]} end
end})
stub('logger',{dbg=function() end,err=function() end,warn=function() end})
stub('ui/uimanager',{
    scheduleIn=function(_,delay,fn) tasks[#tasks+1]={delay=delay,fn=fn} end,
    unschedule=function(_,fn) for i=#tasks,1,-1 do if tasks[i].fn==fn then table.remove(tasks,i) end end end,
})
stub('ffi/util',{
    runInSubProcess=function(fn)
        forks=forks+1;if fail_fork then return nil,'no fork' end
        -- Model the child's snapshot being written while the parent keeps reading.
        in_child=true;fn();in_child=false
        children[forks]={done=false};return forks
    end,
    isSubProcessDone=function(pid) return children[pid].done end,
})
local function tick() assert(#tasks>0);table.remove(tasks,1).fn() end
local function finish() children[forks].done=true;tick() end
local path='/history/fanfic_history.json'
local History=require('ao3lib.library.history')
History.load()
local missing_reads=reads
History.load()
assert(reads==missing_reads,'An unchanged missing history file should not be reopened')
History.add{id='1',path='/book.epub',chapter_data={{id='a'},{id='b'},{id='c'}}}
local baseline=encodes
local original=fs[path]
local rev=History.revision()
in_page=true
assert(History.markChapterAsRead('1',1)==true)
assert(History.markChapterAsRead('1',1)==true)
in_page=false
assert(encodes==baseline and History.revision()==rev+1 and #tasks==1)
assert(History.get('1').chapter_data[1].read and fs[path]==original)
tick() -- starts the worker; canonical history is still unchanged
assert(encodes==baseline+1 and fs[path]==original and forks==1)
assert(encoding_context[encodes]=='child','Serialization must run in the child, not a delayed UI callback')
in_page=true;History.markChapterAsRead('1',2);in_page=false
local before_reads=reads;History.load();assert(reads==before_reads,'Pending progress must survive ReaderUI reinitialization')
finish() -- stale snapshot must be discarded, then rescheduled
assert(fs[path]==original and #tasks==1)
tick();finish()
local persisted=encoded[fs[path]]
assert(persisted['1'].chapter_data[1].read and persisted['1'].chapter_data[2].read)
local warm_reads,warm_revision=reads,History.revision()
History.load();History.load()
assert(reads==warm_reads and History.revision()==warm_revision,'Reader initialization must reuse freshly saved history')
baseline=encodes;assert(History.flushPending());assert(encodes==baseline)
-- A deletion supersedes an older worker and is itself saved in the background.
History.markChapterAsRead('1',3);tick()
assert(History.delete('1'));local deleted=fs[path]
finish();assert(fs[path]==deleted and not History.get('1') and #tasks==1)
tick();finish();assert(not encoded[fs[path]]['1'] and #tasks==0)
-- Child failure retains the in-memory flag for a shutdown checkpoint.
History.add{id='2',chapter_data={{id='x'}}}
assert(History.flushPending())
History.markChapterAsRead('2',1);fail_encode=true;tick();finish();fail_encode=false
assert(History.get('2').chapter_data[1].read and not encoded[fs[path]]['2'].chapter_data[1].read)
assert(History.flushPending());assert(encoded[fs[path]]['2'].chapter_data[1].read)
-- A scheduled write is cancelled by a synchronous close/suspend checkpoint.
History.add{id='3',chapter_data={{id='x'}}}
History.markWorkAsRead('3');assert(#tasks==1)
assert(History.flushPending());assert(#tasks==0 and encoded[fs[path]]['3'].read)
-- Fork failure does not lose progress or move serialization into page turning.
History.add{id='4',chapter_data={{id='x'}}}
History.markChapterAsRead('4',1);fail_fork=true;tick();fail_fork=false
assert(History.flushPending() and encoded[fs[path]]['4'].chapter_data[1].read)
local external=copy(encoded[fs[path]])
external['4'].chapter_data[1].read=false
encoded.external=external;fs[path]='external'
warm_reads=reads
History.load()
assert(reads==warm_reads+1 and not History.get('4').chapter_data[1].read,'External file changes must still reload history')
History.load();assert(reads==warm_reads+1)
-- Updates wait without blocking and only resume after the newest snapshot wins.
local resumed
local work=History.get('4')
work.title='Updated title'
local before_update=encodes
History.update(work,true)
local co=coroutine.create(function() resumed={History.awaitSave()} end)
assert(coroutine.resume(co) and coroutine.status(co)=='suspended')
assert(encodes==before_update and #tasks==1)
tick()
History.add{id='5',title='Added during save'}
finish()
assert(not resumed and coroutine.status(co)=='suspended' and #tasks==1)
tick();finish()
assert(resumed and resumed[1] and coroutine.status(co)=='dead')
assert(encoded[fs[path]]['4'].title=='Updated title' and encoded[fs[path]]['5'])
assert(encoding_context[encodes]=='child')
io,os=real_io,real_os
print('PASS: zero page-turn serialization/I/O; immediate progress/revision; coalescing; stale worker/delete protection; reload safety; failed child/fork; close/suspend checkpoint')
print('PASS: warm reader opens avoid history parsing; cache tracks background saves and external changes')
