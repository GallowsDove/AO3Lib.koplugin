-- Local AO3 shelves. Discovery is incremental and read-only; Bookshelf keeps
-- ownership of filtering, sorting, cover loading and opening local files.
local _ = require("gettext")
local Epub = require("ao3lib.library.epub")
local Metadata = require("ao3lib.bookshelf.metadata")
local M = {}
local ids = {"ao3_downloaded", "ao3_authors", "ao3_fandoms"}
local groups = {ao3_authors={key="ao3_authors", kind="author"},
    ao3_fandoms={key="ao3_fandoms", kind="genre"}}
local state = {paths={}, generation=0, dirty=true, completed=0}
local Sources, Repo, cache
local revision=0
local published_epochs=0
local warmCache, scheduleWarm
local copy = require("ao3lib.core.table").shallowCopy
local function trace(...)
    local ok,logger=pcall(require,"logger")
    if ok and logger.info then logger.info("AO3 shelf:",...) end
end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not same(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function roots()
    local paths={}
    local function add(path) if type(path)=="string" and path~="" then paths[#paths+1]=path end end
    add(require("ao3lib.core.config"):readSetting("fanfic_folder_path"))
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
        state.signature, state.paths, state.busy, state.dirty, state.works=signature, {}, false, true, nil
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
    trace("discovery started", "forced", tostring(not not force))
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
        local changed=force or not same(state.works,works)
        local count=0
        for _ in pairs(works or {}) do count=count+1 end
        trace("discovery finished", "works", count, "changed", tostring(not not changed),
            "error", tostring(err or "none"))
        state.works=works
        publish(works)
        if changed then revision=revision+1 end
        if err then state.dirty=true;require("logger").warn("AO3 shelf discovery:",err) end
        state.busy, state.completed=false, os.time()
        local waiters=state.waiters or {}; state.waiters=nil
        for __,fn in ipairs(waiters) do pcall(fn) end
        -- An invalidation may have arrived during the scan. Even an unchanged
        -- scan must restart any warmup that was deferred while it was busy.
        if warmCache then warmCache() end
        if changed then notify() end
    end
    local ok,err=pcall(function()
        require("ao3lib.library.discovery").scan(paths, finish,
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

local function buildRecords(bootstrap_paths)
    local out, seen, paths={}, {}, {}
    for i,path in ipairs(bootstrap_paths or state.paths) do paths[i]=path end
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
    local background_ok,background=pcall(require,"ao3lib.ao3.background")
    local default_priority={{key="series_name",reverse=false}}
    if background_ok and background.available() then
        cache=require("ao3lib.bookshelf.source_cache").new{
            stamp=function()
                local history=require("ao3lib.library.history")
                return table.concat({state.generation,revision,
                    Repo.dataGeneration and Repo.dataGeneration() or 0,
                    Repo.cacheEpoch and Repo.cacheEpoch()-published_epochs or 0,
                    history.revision and history.revision() or 0},":")
            end,
            busy=function() return state.busy end,
            bootstrap=function()
                if type(Epub.cachedPaths)~="function" then return {} end
                local paths=roots()
                return Epub.cachedPaths(paths)
            end,
            build=buildRecords,groupAll=grouped,specs={groups.ao3_authors,groups.ao3_fandoms},
            group=function(query) return calculate(query.source,query.filter,query.priority) end,
            default_queries=function()
                local queries={
                    {kind="ao3_authors",source={kind="ao3_authors"},priority=default_priority},
                    {kind="ao3_fandoms",source={kind="ao3_fandoms"},priority=default_priority},
                }
                local ok, settings=pcall(require,"lib/bookshelf_settings_store")
                local read, tabs=false,nil
                if ok and type(settings.read)=="function" then read,tabs=pcall(settings.read,"tabs",{}) end
                if read and type(tabs)=="table" then
                    for _,tab in ipairs(tabs) do
                        local source=type(tab)=="table" and tab.source
                        if type(source)=="table" and groups[source.kind] then
                            local filter=tab.filter
                            if type(filter)=="table" and next(filter)==nil then filter=nil end
                            queries[#queries+1]={kind=source.kind,source=source,filter=filter,
                                priority=tab.sort_priority or default_priority}
                        end
                    end
                end
                trace("startup queries", #queries, "saved settings available", tostring(read))
                return queries
            end,
            changed=notify,
        }
        warmCache=function()
            -- The worker prepares the saved grouped shelves as well as the
            -- defaults, using the same EPUB catalog for all of them.
            if state.busy then cache:bootstrap({kind="ao3_authors"},default_priority)
            else cache:groups({kind="ao3_authors"},nil,default_priority,0,1) end
        end
        local scheduled=false
        scheduleWarm=function()
            if scheduled then return end
            scheduled=true
            require("ui/uimanager"):scheduleIn(1,function()
                scheduled=false
                ensureScan()
                warmCache()
            end)
        end
        -- Bookshelf changes its generations after startup (e.g. when its
        -- initial metadata sweep completes). Rebuild before a shelf is opened,
        -- including invalidations that only bump the wider cache epoch.
        if type(Repo.onDataGeneration)=="function" then
            Repo.onDataGeneration(M,function() scheduleWarm() end)
        end
        for name,fn in pairs(Repo) do
            if type(fn)=="function" and (name:match("^invalidate") or name=="forgetBook") then
                local original_invalidate,method=fn,name
                Repo[name]=function(...)
                    -- Keep the original arguments separate from its return values.
                    local own=method=="invalidateBookCache" and select(1,...)=="ao3-source"
                    local function done(...)
                        if not own then scheduleWarm() end
                        return ...
                    end
                    return done(original_invalidate(...))
                end
            end
        end
    end
    Repo.getBySource=function(source, filter, priority, offset, limit, opts)
        local spec=groups[type(source)=="table" and source.kind]
        if not spec then return original(source,filter,priority,offset,limit,opts) end
        if cache then
            ensureScan()
            if type(filter)=="table" and next(filter)==nil then filter=nil end
            priority=priority or default_priority
            return cache:groups(source,filter,priority,offset,limit)
        end
        local list=calculate(source,filter,priority)
        local page,total={},#list
        for i=(offset or 0)+1,math.min((offset or 0)+(limit or total),total) do page[#page+1]=list[i] end
        return page,total
    end
    Repo._fanfic_sources_installed=true
    if cache then ensureScan(false); if state.busy then warmCache() end end
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
