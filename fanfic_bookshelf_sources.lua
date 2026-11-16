-- Local AO3 shelves. Discovery is incremental and read-only; Bookshelf keeps
-- ownership of filtering, sorting, cover loading and opening local files.
local _ = require("gettext")
local Epub = require("fanfic_epub")
local Metadata = require("fanfic_bookshelf")
local M = {}
local ids = {"ao3_downloaded", "ao3_authors", "ao3_fandoms"}
local groups = {ao3_authors={key="ao3_authors", kind="author"},
    ao3_fandoms={key="ao3_fandoms", kind="genre"}}
local state = {paths={}, generation=0, dirty=true, completed=0}
local Sources, Repo, cache
local revision=0
local published_epochs=0
local copy = require("fanfic_table").shallowCopy
local function roots()
    local paths={}
    local function add(path) if type(path)=="string" and path~="" then paths[#paths+1]=path end end
    add(require("fanfic_config"):readSetting("fanfic_folder_path"))
    add(require("apps/filemanager/filemanagerutil").getHomeFolder())
    local parts={}; for __,path in ipairs(paths) do parts[#parts+1]=#path .. ":" .. path end
    return paths, table.concat(parts,"|")
end
local function notify()
    if Repo and Repo.cacheEpoch and Repo.invalidateBookCache then
        -- Bookshelf 6.5 caches subshelf counts and cover previews by this
        -- epoch. Expire those snapshots before announcing the new records.
        local before=Repo.cacheEpoch()
        Repo.invalidateBookCache("ao3-source")
        -- Our publication is an output, not an input change. Exclude only
        -- its own epoch increment so queued AO3 workers keep their results;
        -- later native invalidations still change the stamp below.
        published_epochs=published_epochs+(Repo.cacheEpoch()-before)
    end
    if Sources then for __,id in ipairs(ids) do Sources.changed(id) end end
end
local function ensureScan(force, done)
    local paths, signature=roots()
    if signature~=state.signature then
        state.generation=state.generation+1
        state.signature, state.paths, state.busy, state.dirty=signature, {}, false, true
        if cache then cache:clear() end
    end
    if done then
        state.waiters=state.waiters or {}
        state.waiters[#state.waiters+1]=done
    end
    if state.busy then
        if force then state.dirty=true end
        return
    end
    if not force and not state.dirty and os.time()-state.completed<60 then return end
    state.busy, state.dirty=true, false
    local generation=state.generation
    local function publish(works)
        if generation~=state.generation then return end
        state.paths={}
        for __,work in pairs(works) do
            if type(work.path)=="string" then state.paths[#state.paths+1]=work.path end
        end
        if not cache then table.sort(state.paths) end
    end
    local function finish(works,err)
        if generation~=state.generation then return end
        publish(works)
        revision=revision+1
        if err then state.dirty=true;require("logger").warn("AO3 shelf discovery:",err) end
        state.busy, state.completed=false, os.time()
        local waiters=state.waiters or {}; state.waiters=nil
        for __,fn in ipairs(waiters) do pcall(fn) end
        notify()
    end
    local ok,err=pcall(function()
        require("fanfic_library").scan(paths, finish,
            function() return generation~=state.generation end, {read_only=true,
                progress=function(works)
                    if generation==state.generation and not cache then publish(works);notify() end
                end})
    end)
    if not ok then
        state.busy, state.dirty=false, true
        local waiters=state.waiters or {}; state.waiters=nil
        for __,fn in ipairs(waiters) do pcall(fn) end
        require("logger").warn("AO3 shelf discovery:",err)
    end
end

local function buildRecords()
    local out, seen, paths={}, {}, {}
    for i,path in ipairs(state.paths) do paths[i]=path end
    table.sort(paths)
    for __,path in ipairs(paths) do
        local ok, work=pcall(Epub.read,path)
        if ok and work and not seen[tostring(work.id)] then
            seen[tostring(work.id)]=true
            local record
            if Repo.lightMetaFor then
                local meta_ok, meta=pcall(Repo.lightMetaFor,path)
                if meta_ok then record=copy(meta) end
            end
            record=record or {}
            record._ao3_fields=Metadata.fromWork(work)
            record.filepath=path
            record.title=record.title or work.title
            record.authors=record.authors or work.authors or {work.author or _("Anonymous")}
            record.author=record.author or record.authors[1]
            record.description=record.description or work.summary
            record.lang=record.lang or work.language
            record.filename=record.filename or path:match("([^/]+)$")
            record.format=record.format or "EPUB"
            out[#out+1]=record
        end
    end
    table.sort(out,function(a,b)
        if (a.title or ""):lower()~=(b.title or ""):lower() then return (a.title or ""):lower()<(b.title or ""):lower() end
        return a.filepath<b.filepath
    end)
    return out
end

local function records()
    if cache and cache.worker then return cache:records() end
    ensureScan()
    if cache then return cache:records() end
    return buildRecords()
end

local function grouped(books, spec)
    local by_name, out={}, {}
    for __,book in ipairs(books) do
        local ok, data=true,book._ao3_fields
        if not data then ok,data=pcall(Metadata.get,book.filepath,false) end
        local values=ok and data and data[spec.key] or {}
        local unknown=#values==0 and spec.key=="ao3_fandoms"
        if unknown then values={_("Unknown fandom")} end
        for __,name in ipairs(values) do
            local group=by_name[name]
            if not group then
                group={kind=spec.kind, title=name, series_name=name, books={}, filepaths={},
                    book_count=0, latest=0,
                    _fanfic_ao3={key=spec.key,value=name,source="ao3_downloaded",unknown=unknown or nil}}
                by_name[name]=group; out[#out+1]=group
            end
            group.books[#group.books+1]=book
            group.filepaths[#group.filepaths+1]=book.filepath
            group.book_count=#group.books
            group.latest=math.max(group.latest, tonumber(book.last_opened) or 0)
        end
    end
    return out
end

function M.install(repository)
    local ok, registry=pcall(require,"lib/bookshelf_sources")
    if not ok or registry.API~=1 or type(registry.register)~="function"
        or type(repository.getBySource)~="function" then return false end
    Sources, Repo=registry, repository
    local labels={ao3_downloaded=_("AO3 downloaded works"),
        ao3_authors=_("AO3 authors"),ao3_fandoms=_("AO3 fandoms")}
    for __,id in ipairs(ids) do
        local registered=Sources.register(id,{
            api=1, label=function() return labels[id] end, available=function() return true end,
            list=records, library=id=="ao3_downloaded",
            sort_default={{key=groups[id] and "series_name" or "title",reverse=false}},
            invalidate=function() state.dirty=true;revision=revision+1 end,
            refresh=function(_,_,done) ensureScan(true,done) end,
        })
        if not registered then return false end
    end
    if Repo._fanfic_sources_installed then return true end
    local original=Repo.getBySource
    local function calculate(source,filter,priority)
        local books=original(source,filter,nil,0,nil,{light_only=true}) or {}
        local list=grouped(books,groups[source.kind])
        table.sort(list,require("lib/bookshelf_sort_engine").chainedComparator(
            priority or {{key="series_name",reverse=false}}))
        return list
    end
    local background_ok,background=pcall(require,"fanfic_background")
    if background_ok and background.available() then
        cache=require("fanfic_bookshelf_source_cache").new{
            stamp=function()
                local history=require("downloaded_fanfics")
                return table.concat({state.generation,revision,
                    Repo.dataGeneration and Repo.dataGeneration() or 0,
                    Repo.cacheEpoch and Repo.cacheEpoch()-published_epochs or 0,
                    history.revision and history.revision() or 0},":")
            end,
            busy=function() return state.busy end,
            build=buildRecords,groupAll=grouped,specs={groups.ao3_authors,groups.ao3_fandoms},
            group=function(query) return calculate(query.source,query.filter,query.priority) end,
            changed=notify,
        }
    end
    Repo.getBySource=function(source, filter, priority, offset, limit, opts)
        local spec=groups[type(source)=="table" and source.kind]
        if not spec then return original(source,filter,priority,offset,limit,opts) end
        if cache then
            ensureScan()
            return cache:groups(source,filter,priority,offset,limit)
        end
        local list=calculate(source,filter,priority)
        local page,total={},#list
        for i=(offset or 0)+1,math.min((offset or 0)+(limit or total),total) do page[#page+1]=list[i] end
        return page,total
    end
    Repo._fanfic_sources_installed=true
    return true
end

-- nil preserves the legacy synchronous path on runtimes without workers.
function M.members(key,value,unknown)
    if cache and groups[key] then
        ensureScan()
        return cache:members(key,value,unknown)
    end
end

return M
