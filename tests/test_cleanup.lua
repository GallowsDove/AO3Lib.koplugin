-- Transaction tests with an in-memory filesystem and archive adapter.
-- Run from the plugin directory: luajit tests/test_cleanup.lua
package.path='./?.lua;'..package.path
local fs,archives,json={}, {},{}
local function digest(s) return (s:gsub('.',function(c) return string.format('%02x',c:byte()) end)) end
local function file(s) return {mode='file',bytes=s} end
local function archive(entries)
    local chunks={}
    for _,e in ipairs(entries) do chunks[#chunks+1]=e.path..':'..#e.data..':'..e.data end
    local bytes=table.concat(chunks,'|');archives[bytes]=entries;return bytes
end
local real_io,real_os=io,os
io={open=function(path,mode)
    if mode=='rb' then
        if not fs[path] then return nil,'missing file' end
        local bytes,pos=fs[path].bytes,1
        return {read=function(_,n)
            if n=='*a' then return bytes end
            if pos>#bytes then return nil end
            local chunk=bytes:sub(pos,pos+n-1);pos=pos+#chunk;return chunk
        end,close=function() return true end}
    end
    fs[path]=file('')
    return {write=function(_,s) fs[path].bytes=fs[path].bytes..s;return true end,close=function() return true end}
end}
local rename_error
os={time=real_os.time,remove=function(path) fs[path]=nil;return true end,rename=function(from,to)
    if rename_error and to=='/book.epub' then return nil,'simulated rename failure' end
    assert(fs[from]);fs[to]=fs[from];fs[from]=nil;return true
end}
local function stub(n,v) package.loaded[n]=v end
stub('ffi/MD5',{sumFile=function(path) return fs[path] and digest(fs[path].bytes) end})
stub('ffi/sha2',{sha256=function(s) return s end})
stub('libs/libkoreader-lfs',{attributes=function(p) return fs[p] end,symlinkattributes=function(p) return fs[p] end})
stub('datastorage',{getSettingsDir=function() return '/settings' end})
stub('util',{makePath=function(p) for d in p:gmatch('()/') do fs[p:sub(1,d-1)]={mode='directory'} end;fs[p]={mode='directory'};return true end})
stub('dkjson',{encode=function(m) local k='json'..(#json+1);json[#json+1]=m;json[k]=m;return k end,decode=function(k) return json[k] end})
local corrupt=false
stub('ffi/archiver',{
    Reader={new=function() return {
        open=function(self,path) self.entries=archives[fs[path] and fs[path].bytes];return self.entries~=nil end,
        iterate=function(self) local i=0;return function() i=i+1;local e=self.entries[i];if e then return {path=e.path,mode='file',size=#e.data} end end end,
        extractToMemory=function(self,path) for _,e in ipairs(self.entries) do if e.path==path then return e.data end end end,
        close=function() end,
    } end},
    Writer={new=function() return {
        open=function(self,path) self.path=path;self.entries={};fs[path]=file('');return true end,
        setZipCompression=function() return true end,
        addFileFromMemory=function(self,path,data) self.entries[#self.entries+1]={path=path,data=data};return true end,
        close=function(self) fs[self.path]=file(corrupt and 'broken' or archive(self.entries)) end,
    } end},
})
local M=require('ao3lib.library.cleanup')
local story='<html><body><div id="chapters"><div class="userstuff"><p>A<br/><br/>B</p><p> </p><p>C</p></div></div></body></html>'
local original=archive({{path='mimetype',data='application/epub+zip'},{path='story.xhtml',data=story},{path='content.opf',data='metadata unchanged'}})
fs['/book.epub']=file(original)
local plan,err=M.prepare('/book.epub','123')
assert(plan,err);assert(plan.changed==1 and plan.breaks==1 and plan.blanks==1)
assert(fs['/book.epub'].bytes==original)
assert(M.commit(plan))
local cleaned=fs['/book.epub'].bytes
assert(cleaned~=original)
local revert=assert(M.findBackup('/book.epub','123'))
assert(M.commit(revert));assert(fs['/book.epub'].bytes==original)
assert(not M.findBackup('/book.epub','123'))
-- A failed atomic rename leaves the original and its verified backup intact.
plan=assert(M.prepare('/book.epub','123'));rename_error=true
assert(not M.commit(plan));assert(fs['/book.epub'].bytes==original)
M.discard(plan);rename_error=false
-- Never overwrite or delete an existing temporary file.
fs['/book.epub.ao3lib-cleanup.tmp']=file('someone else')
assert(not M.prepare('/book.epub','123'))
assert(fs['/book.epub.ao3lib-cleanup.tmp'].bytes=='someone else')
fs['/book.epub.ao3lib-cleanup.tmp']=nil
-- Cancellation unwinds handles and removes only its own staging file.
assert(not M.prepare('/book.epub','123',function() error('cancelled') end))
assert(not fs['/book.epub.ao3lib-cleanup.tmp'] and fs['/book.epub'].bytes==original)
-- Corrupt output must be rejected before the source is touched.
corrupt=true;assert(not M.prepare('/book.epub','123'));corrupt=false
assert(fs['/book.epub'].bytes==original and not fs['/book.epub.ao3lib-cleanup.tmp'])
plan=assert(M.prepare('/book.epub','123'));assert(M.commit(plan))
revert=assert(M.findBackup('/book.epub','123'))
fs['/book.epub'].bytes=cleaned..'updated'
assert(not M.commit(revert));assert(fs['/book.epub'].bytes==cleaned..'updated')
assert(not M.findBackup('/book.epub','123'))
-- A pre-existing revert stage is never consumed or removed.
fs['/book.epub']=file(cleaned)
fs['/book.epub.ao3lib-revert.tmp']=file('keep')
revert=assert(M.findBackup('/book.epub','123'));assert(not M.commit(revert));M.discard(revert)
assert(fs['/book.epub.ao3lib-revert.tmp'].bytes=='keep')
-- A corrupted original is detected before revert is offered.
fs[revert.original].bytes='bad backup'
local backup,backup_error=M.findBackup('/book.epub','123')
assert(not backup and backup_error)
io,os=real_io,real_os
print('AO3 cleanup transaction tests passed')
