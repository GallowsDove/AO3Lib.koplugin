-- Session snapshot shared by local-library screens. The persistent EPUB cache
-- is loaded in a worker so opening a screen never parses it on the UI thread.
local M={}
local snapshot,signature
local revision=0
local function key(roots)
    local parts={}
    for _,root in ipairs(roots or {}) do
        if type(root)=='string' then parts[#parts+1]=#root..':'..root end
    end
    return table.concat(parts,'|')
end
local function copy(works)
    local out={}
    for id,work in pairs(works or {}) do
        out[tostring(type(work)=='table' and work.id or id)]=work
    end
    return out
end
function M.get(roots)
    if snapshot and signature==key(roots) then return copy(snapshot) end
end
function M.put(roots,works)
    signature,snapshot=key(roots),copy(works)
    M.active_roots={};for i,root in ipairs(roots or {}) do M.active_roots[i]=root end
    revision=revision+1
end
function M.remove(roots,id)
    if signature==key(roots) and snapshot then snapshot[tostring(id)]=nil;revision=revision+1 end
end
function M.removePath(path)
    if snapshot then
        for id,work in pairs(snapshot) do if work.path==path then snapshot[id]=nil end end
    end
    revision=revision+1
    require('ao3lib.library.epub').invalidate(path,true)
end
-- A folder-delete notification can contain books absent from the session
-- snapshot. Consult the persistent EPUB index too, and verify each file.
function M.removeMissingUnder(folder)
    if type(folder)~='string' or folder=='' then return end
    local prefix=folder:gsub('/+$','')..'/'
    local candidates={}
    if snapshot then
        for _,work in pairs(snapshot) do
            if type(work.path)=='string' and work.path:sub(1,#prefix)==prefix then candidates[work.path]=true end
        end
    end
    local Epub=require('ao3lib.library.epub')
    for _,work in pairs(Epub.indexWorks({folder})) do candidates[work.path]=true end
    local lfs=require('libs/libkoreader-lfs')
    for path in pairs(candidates) do
        local stat,err,code=lfs.attributes(path)
        if not stat and (code==2 or (type(err)=='string' and err:find('No such file',1,true))) then
            M.removePath(path)
        end
    end
end
function M.merge(roots,works)
    if not snapshot then M.put(roots,works);return end
    if signature~=key(roots) then return end
    for id,work in pairs(copy(works)) do snapshot[id]=work end
    revision=revision+1
end
function M.index(path)
    local Background=require('ao3lib.ao3.background')
    if not Background.available() then return end
    return Background.run(function() return require('ao3lib.library.epub').inspect(path) end,
        function(entry,err)
            if not entry then
                local ok,logger=pcall(require,'logger')
                if ok and logger.warn then logger.warn('AO3 index could not read downloaded EPUB:',tostring(err or path)) end
                return
            end
            local work=require('ao3lib.library.epub').accept(entry)
            if not work then return end
            if snapshot then
                for id,old in pairs(snapshot) do if old.path==path then snapshot[id]=nil end end
                -- Only update an already-loaded index whose roots contain it.
                local roots=M.active_roots or {}
                for _,root in ipairs(roots) do
                    root=root:gsub('/+$','')
                    if path:sub(1,#root+1)==root..'/' then snapshot[tostring(work.id)]=work;break end
                end
            end
            revision=revision+1
        end)
end
function M.load(roots,done,valid)
    local Background=require('ao3lib.ao3.background')
    if not Background.available() then return end
    local started=revision
    local initial=M.get(roots)
    return Background.run(function()
        local Epub=require('ao3lib.library.epub')
        local lfs=require('libs/libkoreader-lfs')
        local found=initial or Epub.indexWorks(roots)
        local changed,missing={},{}
        for id,work in pairs(found) do
            local stat,err,code=lfs.attributes(work.path)
            if stat and stat.mode=='file' then
                local current=Epub.cached(work.path)
                if current then found[id]=current
                else
                    local entry=Epub.inspect(work.path)
                    if entry and entry.work then
                        changed[#changed+1]=entry
                        local fresh=require('ao3lib.core.table').deepCopy(entry.work)
                        fresh.path=work.path;found[id]=nil;found[tostring(fresh.id)]=fresh
                    end
                end
            elseif not stat and (code==2 or (type(err)=='string' and err:find('No such file',1,true))) then
                local accessible=false
                for _,root in ipairs(roots) do
                    local clean=root:gsub('/+$','')
                    if work.path:sub(1,#clean+1)==clean..'/' and lfs.attributes(root,'mode')=='directory' then accessible=true;break end
                end
                if accessible then found[id]=nil;missing[#missing+1]={id=id,work=work} end
            end
        end
        return {found=found,changed=changed,missing=missing}
    end,function(result,err)
        if not result or (valid and not valid()) then done(nil,err);return end
        if revision~=started then
            local current=M.get(roots)
            if current then done(current,nil) else M.load(roots,done,valid) end
            return
        end
        local Epub=require('ao3lib.library.epub')
        for _,entry in ipairs(result.changed) do Epub.accept(entry) end
        for _,item in ipairs(result.missing) do
            local path=item.work.path
            local lfs=require('libs/libkoreader-lfs')
            local stat,why,code=lfs.attributes(path)
            local accessible=false
            for _,root in ipairs(roots) do
                local clean=root:gsub('/+$','')
                if path:sub(1,#clean+1)==clean..'/' and lfs.attributes(root,'mode')=='directory' then accessible=true;break end
            end
            if accessible and not stat and (code==2 or (type(why)=='string' and why:find('No such file',1,true))) then
                Epub.invalidate(path,true)
            else result.found[item.id]=item.work end
        end
        M.put(roots,result.found);M.active_roots=roots
        done(result.found,nil)
    end,{valid=valid})
end
return M
