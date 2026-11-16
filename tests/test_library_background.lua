package.path='./?.lua;'..package.path
local H=dofile('tests/support/async.lua')
H.ffi.realpath=function(p) return p end
local function copy(t) if type(t)~='table' then return t end;local o={};for k,v in pairs(t) do o[k]=copy(v) end;return o end
local fs,names={},{}
for i=1,30 do
    names[i]=i..'.epub';fs['/books/'..names[i]]={mode='file',size=100,modification=1,change=1}
end
fs['/books']={mode='directory'}
local closed=0
package.loaded['libs/libkoreader-lfs']={attributes=function(p,key) local s=fs[p];return key and s and s[key] or s end,
symlinkattributes=function(p) return fs[p] end,
dir=function()
    local i=0;local handle={close=function() closed=closed+1 end}
    return function() i=i+1;if names[i] then return names[i] end;handle:close() end,handle
end}
local cache,flushes={},0
package.loaded.luasettings={open=function() return {
    readSetting=function(_,_,default) return cache end,
    saveSetting=function(_,_,v) assert(not H.inChild());cache=v end,
    flush=function() assert(not H.inChild(),'Worker flushed the metadata cache');flushes=flushes+1 end,
} end}
package.loaded.datastorage={getDataDir=function() return '/data' end}
package.loaded.util={tableDeepCopy=copy,trim=function(s) return s:match('^%s*(.-)%s*$') end,unicodeCodepointToUtf8=string.char}
package.loaded.downloaded_fanfics={rememberLocal=function() error('Read-only discovery wrote history') end,save=function() error('Read-only discovery saved history') end}
local Reader={}
function Reader:new() return setmetatable({}, {__index=self}) end
function Reader:open(path)
    assert(H.inChild(),'Uncached EPUB opened in UI process')
    H.sleep(2)
    local id=path:match('/(%d+)%.epub$')
    self.bytes={
        ['META-INF/container.xml']='<container><rootfile full-path="content.opf"/></container>',
        ['content.opf']='<package><dc:title>Work '..id..'</dc:title><dc:creator>Writer</dc:creator><manifest><item id="p" href="preface.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="p"/></spine></package>',
        ['preface.xhtml']='<div id="preface"><p class="message"><a href="https://archiveofourown.org/works/'..id..'">Original</a></p></div>',
    }
    self.entries={}
    for p,s in pairs(self.bytes) do local e={path=p,size=#s,mode='file'};self.entries[p]=e;self.entries[#self.entries+1]=e end
    return true
end
function Reader:iterate() local i=0;return function() i=i+1;return self.entries[i] end end
function Reader:extractToMemory(p) return self.bytes[p] end
function Reader:close() end
package.loaded['ffi/archiver']={Reader=Reader}
local Epub=require('fanfic_epub')
local Library=require('fanfic_library')
local final,progress,error
local partials={}
Library.scan({'/books'},function(works,err) final=works;error=err end,nil,{read_only=true,progress=function(works)
    local n=0;for _ in pairs(works) do n=n+1 end;partials[#partials+1]=n
end})
H.tick() -- directory walk starts its first worker and returns immediately
assert(not final and H.forks==1)
fs['/books/1.epub'].size=200 -- reject the old worker fingerprint
H.drain()
assert(final and not error and not final['1'])
local n=0;for _ in pairs(final) do n=n+1 end;assert(n==29 and H.forks==2)
local incremental=false
for _,count in ipairs(partials) do if count>0 and count<29 then incremental=true end end
assert(incremental,'Discovery did not publish intermediate results')
local before=H.forks
Library.scan({'/books'},function(works) final=works end,nil,{read_only=true});H.drain()
assert(final['1'] and H.forks==before+1,'Only the changed/unaccepted EPUB should be parsed again')
before=H.forks
Library.scan({'/books'},function(works) final=works end,nil,{read_only=true});H.drain()
assert(H.forks==before,'Warm scans must not spawn an EPUB parser')
-- Cancellation during a batch cannot import results into the parent cache.
for _,s in pairs(fs) do if s.mode=='file' then s.modification=2 end end
local completed=false
local scan=Library.scan({'/books'},function() completed=true end,nil,{read_only=true})
H.tick();scan.cancel();H.drain()
assert(not completed)
local _,known=Epub.cached('/books/2.epub');assert(not known)
-- Worker startup failure reports a retryable scan failure, not a negative cache.
H.fail_fork=true
Library.scan({'/books'},function(_,err) error=err end,nil,{read_only=true});H.drain();H.fail_fork=false
assert(error and error:find('Could not start',1,true))
_,known=Epub.cached('/books/2.epub');assert(not known)
assert(closed>0)
print('PASS: real batched EPUB workers; progressive discovery; parent-only cache writes; warm cache fast path; changed-file rejection; cancellation; worker failure without negative caching')
