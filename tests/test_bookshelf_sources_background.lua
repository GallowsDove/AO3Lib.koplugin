package.path='./?.lua;'..package.path
local H=dofile('tests/support/async.lua')
package.loaded.gettext=function(s) return s end
local folder='/books'
package.loaded["ao3lib.core.config"]={readSetting=function() return folder end}
package.loaded['apps/filemanager/filemanagerutil']={getHomeFolder=function() return '/home' end}
package.loaded["ao3lib.library.history"]={revision=function() return 0 end}
local works={}
for i=1,200 do works['/books/'..i..'.epub']={id=i,title='Book '..i,authors={'Author '..i%5},fandoms=i%2==0 and {'Fandom'} or {}} end
package.loaded["ao3lib.library.epub"]={read=function(path)
    assert(H.inChild(),'EPUB metadata read on UI thread')
    return works[path]
end}
package.loaded["ao3lib.library.discovery"]={scan=function(_,done)
    local found={};for path,work in pairs(works) do found[#found+1]={path=path} end
    done(found)
end}
local specs,notices={},0
local on_changed
local Sources={API=1,register=function(id,spec) specs[id]=spec;return true end,
    changed=function(id) notices=notices+1;if on_changed then on_changed(id) end end,
    list=function(id) return specs[id].list() end}
package.loaded['lib/bookshelf_sources']=Sources
package.loaded['lib/bookshelf_sort_engine']={chainedComparator=function(priority)
    assert(H.inChild(),'Sorting on UI thread')
    return function(a,b) if priority[1].reverse then return a.title>b.title end;return a.title<b.title end
end}
local generation,repo_epoch=0,0
local publication_invalidations=0
local favorite=false
local Repo={dataGeneration=function() return generation end,
    cacheEpoch=function() return repo_epoch end,
    invalidateBookCache=function(reason)
        assert(not H.inChild(),'Shelf publication must happen in the parent')
        assert(reason=='ao3-source');publication_invalidations=publication_invalidations+1
        repo_epoch=repo_epoch+1
    end,
    invalidateFavoritesCache=function() repo_epoch=repo_epoch+1 end,
    lightMetaFor=function(path)
        assert(H.inChild(),'Library metadata built on UI thread')
        if path=='/books/1.epub' then H.sleep(80) end
        return {}
    end,
    getBySource=function(source,filter)
        assert(H.inChild(),'Whole-library filtering on UI thread')
        local all=Sources.list(source.kind)
        if not filter then return all end
        if filter.favorite then return favorite and all or {} end
        local out={};for _,book in ipairs(all) do if book._ao3_fields.ao3_authors[1]==filter.author then out[#out+1]=book end end
        return out
    end}
local Extension=require('ao3lib.bookshelf.sources')
assert(Extension.install(Repo))
assert(H.forks==1,'AO3 grouped-shelf metadata should preload in a background worker at plugin startup')
local source={kind='ao3_authors'}
-- Use v6.5's actual subshelf memo and source-change handler: publishing a
-- worker result must evict the initially empty preview, not merely redraw it.
local file=assert(io.open('../bookshelf.koplugin/lib/bookshelf_widget.lua'))
local widget_source=file:read('*a');file:close()
local memo_body=widget_source:match('\nfunction BookshelfWidget:_subShelfMemo%(slot, tab, compute%)\n(.-)\nend\n')
local preview
if memo_body then
    local env=setmetatable({Repo=Repo,require=function(name)
        assert(name=='lib/bookshelf_tab_model');return {generation=function() return 1 end}
    end},{__index=_G})
    local load=assert(loadstring('return function(self,slot,tab,compute)\n'..memo_body..'\nend'))
    setfenv(load,env)
    preview={_subShelfMemo=load(),_currentRegisteredSource=function() return {kind='ao3_authors'} end,
        _shelvesHoldSource=function() return false end}
    function preview:_rebuild()
        self.items=self:_subShelfMemo('members',{id='authors'},function()
            return Repo.getBySource(source,nil,nil,0,10)
        end)
        self.covers=self:_subShelfMemo('covers4',{id='authors'},function()
            return Repo.getBySource(source,nil,nil,0,4)
        end)
    end
    local body=assert(widget_source:match('    self%._on_source_changed = function%(id%)(.-)\n    end\n    require%("lib/bookshelf_sources"%)'))
    assert(loadstring('return function(self,UIManager) self._on_source_changed=function(id)'..body..'\nend end'))()(preview,H.UI)
    on_changed=function(id) preview._on_source_changed(id) end
end
local page,total=Repo.getBySource(source,nil,nil,0,2)
assert(#page==0 and total==0)
local forks=H.forks
assert(forks==1)
if preview then
    preview:_rebuild()
    assert(#preview.items==0 and #preview.covers==0)
end
-- Several shelves may request different predicates during the same redraw.
Repo.getBySource(source,{author='Author 1'},nil,0,2)
local responsive=false
H.UI:nextTick(function() responsive=true end)
local queued=#H.jobs
for i=1,queued do H.tick() end
assert(responsive,'UI event was blocked behind the calculation')
H.drain()
page,total=Repo.getBySource(source,nil,nil,0,2)
assert(total==5 and #page==2 and page[1].book_count==40)
assert(H.forks==2,'Repeated queries should share a catalog and queue distinct filters')
assert(publication_invalidations>=3,'Scan and worker publications must invalidate native previews')
if preview then
    assert(#preview.items==5 and #preview.covers==4,'The empty subshelf count/cover snapshots survived publication')
end
page,total=Repo.getBySource(source,nil,nil,2,2)
assert(total==5 and #page==2 and H.forks==2,'Paging recalculated the library')
page,total=Repo.getBySource(source,{author='Author 1'},nil,0,10)
assert(total==1 and page[1].title=='Author 1' and page[1].book_count==40)
assert(#Extension.members('ao3_authors','Author 1')==40)
assert(#Extension.members('ao3_fandoms','unused',true)==100)
assert(H.forks==2,'Opening a group recalculated all members')
-- Caller annotations on group rows must not pollute cached groups.
page[1].title='mutated';page[1].books[1].title='mutated'
page=Repo.getBySource(source,{author='Author 1'},nil,0,10)
assert(page[1].title=='Author 1' and page[1].books[1].title~='mutated')
-- A native invalidation with no data-generation change must refresh AO3
-- results too. Worker publications must not restart other queued queries.
Repo.getBySource(source,{favorite=true},nil,0,10);H.drain()
page,total=Repo.getBySource(source,{favorite=true},nil,0,10)
assert(total==0)
local unchanged_generation=generation
favorite=true;Repo.invalidateFavoritesCache()
Repo.getBySource(source,{favorite=true},nil,0,10);H.drain()
page,total=Repo.getBySource(source,{favorite=true},nil,0,10)
assert(total==5 and generation==unchanged_generation,'Native cache-only invalidation was ignored')
local warmed_forks=H.forks
Repo.getBySource(source,nil,nil,0,10)
Repo.getBySource(source,{favorite=true},nil,0,10)
H.drain()
assert(H.forks==warmed_forks,'Publishing results started an invalidation loop')
-- An external invalidation during a worker run must reject its stale answer.
favorite=false;Repo.invalidateFavoritesCache()
Repo.getBySource(source,{favorite=true},nil,0,10)
favorite=true;Repo.invalidateFavoritesCache()
Repo.getBySource(source,{favorite=true},nil,0,10);H.drain()
page,total=Repo.getBySource(source,{favorite=true},nil,0,10)
assert(total==5)
-- Metadata/progress changes reject in-flight results and rebuild on demand.
generation=generation+1
page,total=Repo.getBySource(source,nil,nil,0,2)
assert(total==5 and #page==2,'Refresh should keep the previous snapshot visible')
generation=generation+1
Repo.getBySource(source,nil,nil,0,2)
H.drain()
page,total=Repo.getBySource(source,nil,nil,0,10)
assert(total==5)
-- A failed worker must not fall back to synchronous metadata reads or retry-loop.
generation=generation+1;H.fail_fork=true
Repo.getBySource(source,nil,nil,0,2);H.drain()
local failed_forks=H.forks
Repo.getBySource(source,nil,nil,0,2)
assert(H.forks==failed_forks and #H.stack==1)
H.fail_fork=false
specs.ao3_authors.refresh(nil,nil,function() end)
Repo.getBySource(source,nil,nil,0,2);H.drain()
page,total=Repo.getBySource(source,nil,nil,0,10)
assert(total==5 and notices>0 and #H.warnings==1)
-- Changing roots must clear the snapshot immediately, even with a worker pending.
generation=generation+1
Repo.getBySource(source,nil,nil,0,2)
folder='/different';works={}
page,total=Repo.getBySource(source,nil,nil,0,2)
assert(total==0 and #page==0,'Old-root books leaked into a new source')
H.drain()
page,total=Repo.getBySource(source,nil,nil,0,10)
assert(total==0)
print('PASS: real-process AO3 shelf metadata/filter/group/sort; responsive UI; cached paging/member drilldown; queued filters; stale results; worker failure and refresh')
