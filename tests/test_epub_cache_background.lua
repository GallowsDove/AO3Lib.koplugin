package.path='./?.lua;'..package.path
local H=dofile('tests/support/async.lua')
function H.UI:unschedule(fn)
    for i=#H.jobs,1,-1 do if H.jobs[i]==fn then table.remove(H.jobs,i) end end
end
local root=os.tmpname();os.remove(root);assert(os.execute('mkdir '..root)==0)
local filename=root..'/ao3_epubs.lua'
local persistent={}
local settings={file=filename,data={preface_v1=persistent}}
function settings:readSetting(key,default) return self.data[key] or default end
function settings:saveSetting(key,value) self.data[key]=value end
function settings:flush()
    local file=assert(io.open(self.file,'wb'))
    file:write('return '..require('dump')(self.data)..'\n');file:close()
end
package.loaded.luasettings={open=function() return settings end}
package.loaded.datastorage={getDataDir=function() return root end}
local stats={['/books/1.epub']={mode='file',size=1,modification=1,change=1},
    ['/books/2.epub']={mode='file',size=2,modification=2,change=2}}
package.loaded['libs/libkoreader-lfs']={attributes=function(path,key)
    local item=stats[path];return key and item and item[key] or item
end}
package.loaded.util={trim=function(s) return s:match('^%s*(.-)%s*$') end,
    tableDeepCopy=function(t) local out={};for k,v in pairs(t) do out[k]=v end;return out end}
-- Check that normal cache serialization never occurs on the UI thread.
local allow_parent=false
package.loaded.dump=function(data)
    assert(H.inChild() or allow_parent,'Scheduled cache serialization blocked the UI')
    if H.inChild() then H.sleep(50) end
    local keys={};for key in pairs(data.preface_v1) do keys[#keys+1]=key end;table.sort(keys)
    local out={'{preface_v1={'}
    for _,key in ipairs(keys) do out[#out+1]='['..string.format('%q',key)..']={size=1},' end
    out[#out+1]='}}';return table.concat(out)
end
local Epub=require('ao3lib.library.epub')
local function accept(path,id)
    local stat=stats[path]
    assert(Epub.accept{path=path,size=stat.size,mtime=stat.modification,change=stat.change,
        metadata_version=4,work={id=id,title='Work'}})
end
accept('/books/1.epub','1')
H.tick() -- start first serialization worker
assert(H.forks==1 and not io.open(filename,'r'))
accept('/books/2.epub','2') -- supersede the in-flight snapshot
H.drain()
local saved=assert(dofile(filename)).preface_v1
assert(saved['/books/1.epub'] and saved['/books/2.epub'] and H.forks==2,
    'A changed cache must discard stale output and publish a fresh snapshot')
-- A synchronous checkpoint supersedes any already-running worker.
Epub.invalidate('/books/1.epub',true);H.tick()
accept('/books/1.epub','1')
allow_parent=true;Epub.flush();allow_parent=false
H.drain()
saved=assert(dofile(filename)).preface_v1
assert(saved['/books/1.epub'] and saved['/books/2.epub'],'Stale worker overwrote an explicit checkpoint')
os.remove(filename);assert(os.execute('rmdir '..root)==0,'Temporary cache files leaked')
print('PASS: background cache serialization; stale snapshot protection; explicit checkpoint; cleanup')
