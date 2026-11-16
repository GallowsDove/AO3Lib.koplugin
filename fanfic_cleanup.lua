-- Manual EPUB cleanup transactions. The reader must close before commit().
local Archiver = require('ffi/archiver')
local MD5 = require('ffi/MD5')
local sha256 = require('ffi/sha2').sha256
local lfs = require('libs/libkoreader-lfs')
local json = require('dkjson')
local util = require('util')
local XML = require('fanfic_cleanup_xml')
local M = {}
local function hash(path) return assert(MD5.sumFile(path), 'Cannot read EPUB fingerprint') end
local function read(path)
    local f=assert(io.open(path,'rb'));local s=assert(f:read('*a'));f:close();return s
end
local function write(path,s)
    local f=assert(io.open(path,'wb'))
    local ok,err=f:write(s);local closed,cerr=f:close();assert(ok and closed,err or cerr)
end
local function copy(from,to)
    local src=assert(io.open(from,'rb'));local dst,err=io.open(to,'wb')
    if not dst then src:close();error(err) end
    local ok,message=pcall(function()
        while true do local bytes=src:read(65536);if not bytes then break end;assert(dst:write(bytes)) end
    end)
    src:close();local closed,cerr=dst:close();assert(ok and closed,message or cerr)
    assert(hash(from)==hash(to),'Backup verification failed')
end
local function root(id)
    assert(tostring(id):match('^%d+$'),'Invalid AO3 work ID')
    return require('datastorage'):getSettingsDir()..'/ao3_formatting/'..id
end
local function index(reader)
    local entries,seen,total={}, {},0
    for e in reader:iterate() do
        assert(#entries<4096,'Too many archive entries')
        assert(not seen[e.path],'Duplicate EPUB entry');seen[e.path]=true
        assert(e.mode=='file' or e.mode=='directory','Unsupported archive entry')
        assert(not e.path:match('^/') and not ('/'..e.path..'/'):find('/../',1,true) and not e.path:find('\\',1,true),'Unsafe EPUB entry')
        local lower=e.path:lower()
        assert(lower~='meta-inf/signatures.xml' and lower~='meta-inf/encryption.xml','Signed or encrypted EPUBs cannot be cleaned')
        assert(e.size>=0 and e.size<=16*1024*1024,'EPUB entry is too large')
        total=total+e.size;assert(total<=128*1024*1024,'Expanded EPUB is too large')
        entries[#entries+1]=e
    end
    assert(not reader.err,reader.err)
    return entries
end
local function open(path)
    local r=Archiver.Reader:new();assert(r:open(path),'Cannot open EPUB archive');return r
end
local function extract(r,path) return assert(r:extractToMemory(path),'Cannot read EPUB entry: '..path) end
-- yield_fn lets the UI process events between entries without external processes.
function M.prepare(path,id,yield_fn)
    local plan={path=path,id=tostring(id),stage=path..'.ao3lib-cleanup.tmp',changed=0,breaks=0,blanks=0}
    local reader,writer
    local owned=false
    local function progress(phase,current,total,entry)
        if yield_fn then yield_fn({phase=phase,current=current,total=total,entry=entry}) end
    end
    local ok,err=pcall(function()
        local stat=lfs.symlinkattributes(path)
        assert(stat and stat.mode=='file','The EPUB is missing or is a symbolic link')
        assert(not lfs.attributes(plan.stage),'A cleanup temporary file already exists; remove it before retrying')
        progress('Checking EPUB')
        plan.before=hash(path)
        reader=open(path);local entries=index(reader)
        assert(extract(reader,'mimetype')=='application/epub+zip','Not an EPUB archive')
        local css={}
        for i,e in ipairs(entries) do
            if e.path:lower():match('%.css$') then css[#css+1]=extract(reader,e.path) end
            progress('Reading styles',i,#entries,e.path)
        end
        local classes=XML.protectedClasses(table.concat(css,'\n'))
        writer=Archiver.Writer:new();owned=true;plan.stage_owned=true
        assert(writer:open(plan.stage,'epub'),'Cannot create temporary EPUB')
        assert(writer:setZipCompression('store'),'Cannot set EPUB compression')
        assert(writer:addFileFromMemory('mimetype','application/epub+zip',os.time()),'Cannot write EPUB mimetype')
        assert(writer:setZipCompression('deflate'),'Cannot set EPUB compression')
        local expected={mimetype=sha256('application/epub+zip')}
        for i,e in ipairs(entries) do
            if e.mode=='file' and e.path~='mimetype' then
                progress('Cleaning book',i,#entries,e.path)
                local bytes=extract(reader,e.path)
                if e.path:lower():match('%.xhtml$') or e.path:lower():match('%.html$') then
                    local cleaned,stats=XML.clean(bytes,classes,function(phase)
                        progress(phase,i,#entries,e.path)
                    end)
                    if cleaned~=bytes then plan.changed=plan.changed+1 end
                    plan.breaks=plan.breaks+stats.break_runs_converted
                    plan.blanks=plan.blanks+stats.blank_paragraphs_removed
                    bytes=cleaned
                end
                expected[e.path]=sha256(bytes)
                assert(writer:addFileFromMemory(e.path,bytes,os.time()),'Cannot write EPUB entry')
                progress('Writing EPUB',i,#entries,e.path)
            end
        end
        reader:close();reader=nil;writer:close();writer=nil
        reader=open(plan.stage)
        local written=index(reader)
        for i,e in ipairs(written) do
            progress('Verifying EPUB',i,#written,e.path)
            assert(expected[e.path] and sha256(extract(reader,e.path))==expected[e.path],'Temporary EPUB verification failed')
            expected[e.path]=nil
        end
        assert(not next(expected),'Temporary EPUB has missing entries')
        reader:close();reader=nil
        progress('Checking final EPUB')
        assert(hash(path)==plan.before,'The EPUB changed while preparing cleanup')
        plan.after=hash(plan.stage)
    end)
    if reader then pcall(function() reader:close() end) end
    if writer then pcall(function() writer:close() end) end
    if not ok then if owned then os.remove(plan.stage) end;return nil,tostring(err) end
    return plan
end
function M.discard(plan) if plan and plan.stage_owned then os.remove(plan.stage);plan.stage_owned=nil end end
function M.findBackup(path,id)
    local ok,result=pcall(function()
        local dir=root(id)
        if not lfs.attributes(dir) then return end
        local current=hash(path)
        local folder=dir..'/'..current
        if not lfs.attributes(folder..'/manifest.json') then return end
        local m=assert(json.decode(read(folder..'/manifest.json')))
        assert(m.version==1 and m.after==current and tostring(m.id)==tostring(id),'Invalid formatting backup record')
        assert(type(m.before)=='string' and m.before:match('^%x+$'),'Invalid original fingerprint')
        assert(hash(folder..'/original.epub')==m.before,'Original EPUB backup is damaged')
        return {path=path,id=tostring(id),before=current,after=m.before,original=folder..'/original.epub',revert=true}
    end)
    if not ok then return nil,tostring(result) end
    return result
end
-- All fallible preparation happens before the atomic rename over the closed book.
function M.commit(plan)
    local ok,err=pcall(function()
        local stat=lfs.symlinkattributes(plan.path)
        assert(stat and stat.mode=='file','The EPUB is missing or is a symbolic link')
        assert(hash(plan.path)==plan.before,'The EPUB changed; nothing was replaced')
        if plan.revert then
            assert(hash(plan.original)==plan.after,'The original EPUB backup is damaged')
            plan.stage=plan.path..'.ao3lib-revert.tmp'
            assert(not lfs.attributes(plan.stage),'A revert temporary file already exists')
            plan.stage_owned=true
            -- Copy, never consume the original backup.
            copy(plan.original,plan.stage)
        else
            assert(hash(plan.stage)==plan.after,'The prepared cleanup has changed')
            local folder=root(plan.id)..'/'..plan.after
            assert(util.makePath(folder),'Cannot create formatting backup folder')
            local original=folder..'/original.epub'
            if lfs.attributes(original) then
                assert(hash(original)==plan.before,'A different original backup already exists')
            else
                local pending=original..'.tmp'
                assert(not lfs.attributes(pending),'An incomplete formatting backup exists')
                copy(plan.path,pending)
                assert(os.rename(pending,original),'Cannot save original EPUB backup')
            end
            local manifest={version=1,id=plan.id,before=plan.before,after=plan.after,path=plan.path}
            write(folder..'/manifest.json.tmp',assert(json.encode(manifest)))
            assert(os.rename(folder..'/manifest.json.tmp',folder..'/manifest.json'),'Cannot save backup record')
        end
        assert(hash(plan.stage)==plan.after,'Replacement EPUB verification failed')
        assert(hash(plan.path)==plan.before,'The EPUB changed before replacement')
        assert(os.rename(plan.stage,plan.path),'Cannot replace EPUB; the original book is unchanged')
    end)
    if not ok then return nil,tostring(err) end
    return true
end
return M
