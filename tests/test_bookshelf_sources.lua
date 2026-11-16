-- Reuse metadata/filter/detail fixtures, then exercise the real source registry
-- and sorting engine with an asynchronous, read-only discovery boundary.
dofile('tests/test_bookshelf.lua')
local Repo=package.loaded['lib/bookshelf_book_repository']
local Widget=package.loaded['lib/bookshelf_widget']
local Sources=dofile('../bookshelf.koplugin/lib/bookshelf_sources.lua')
package.loaded['lib/bookshelf_sources']=Sources
package.loaded['lib/bookshelf_settings_store'].generation=function() return 1 end
local Sort=require('lib/bookshelf_sort_engine')
local folder,home='/downloads','/home'
package.loaded.fanfic_config={readSetting=function() return folder end}
package.loaded['apps/filemanager/filemanagerutil']={getHomeFolder=function() return home end}
local works={
    ['/downloads/one.epub']={id='1',path='/downloads/one.epub',title='Beta',authors={'Writer','Coauthor'},
        fandoms={'A','B'},categories={'M/M'},chapters='2/?'},
    ['/home/two.epub']={id='2',path='/home/two.epub',title='Alpha',author='Writer',fandoms={'B'},chapters='1/1'},
    ['/home/unknown.epub']={id='3',path='/home/unknown.epub',title='Untitled'},
    ['/home/duplicate.epub']={id='1',path='/home/duplicate.epub',title='Duplicate'},
}
package.loaded.fanfic_epub.read=function(path)
    if path=='/broken.epub' then error('corrupt EPUB') end
    return works[path]
end
package.loaded.downloaded_fanfics.get=function() error('Source identity must never use history') end
local scans={}
package.loaded.fanfic_library={scan=function(roots,done,cancelled,options)
    assert(options.read_only)
    scans[#scans+1]={roots=roots,done=done,cancelled=cancelled,progress=options.progress}
end}
Repo.lightMetaFor=function(path)
    if path=='/downloads/one.epub' then return {title='Beta',_status='reading'} end
    if path=='/home/two.epub' then return {title='Alpha',_status='finished'} end
end
-- Same registered-list pipeline as Bookshelf: source -> filter -> sort -> page.
local native_calls=0
Repo.getBySource=function(source,filter,priority,offset,limit,opts)
    native_calls=native_calls+1
    if not Sources.get(source.kind) then return {{native=true}},1 end
    local list=Sources.list(source.kind,source) or {}
    if filter then list=Repo.applyFilter(list,filter) end
    if priority then table.sort(list,Sort.chainedComparator(priority)) end
    local page={}
    for i=(offset or 0)+1,math.min((offset or 0)+(limit or #list),#list) do page[#page+1]=list[i] end
    return page,#list
end
local Extension=require('fanfic_bookshelf_sources')
assert(Extension.install(Repo));local wrapped=Repo.getBySource
assert(Extension.install(Repo) and Repo.getBySource==wrapped)
local expected={'AO3 downloaded works','AO3 authors','AO3 fandoms'}
for i,id in ipairs(Sources.pickerIds()) do
    assert(Sources.label(id)==expected[i])
    assert(not Sources.isPaged(id), 'local shelves must retain native filters and spines view')
end
assert(#Sources.pickerIds()==3)
local notices={}
Sources.onChanged('test',function(id) notices[id]=(notices[id] or 0)+1 end)
assert(#Sources.list('ao3_downloaded')==0)
assert(#scans==1 and scans[1].roots[1]==folder and scans[1].roots[2]==home)
Sources.list('ao3_authors');Sources.list('ao3_fandoms');assert(#scans==1)
local function complete(index,found)
    scans[index].done(found or {one=works['/downloads/one.epub'],two=works['/home/two.epub'],
        unknown=works['/home/unknown.epub'],broken={path='/broken.epub'}})
end
scans[1].progress({one=works['/downloads/one.epub']})
assert(#Sources.list('ao3_downloaded')==1,'Partial discovery must appear before scan completion')
complete(1)
for _,id in ipairs(Sources.pickerIds()) do assert(notices[id]==2) end
local flat=Sources.list('ao3_downloaded')
assert(#flat==3 and flat[1].title=='Alpha' and flat[2].title=='Beta')
assert(flat[2].filepath=='/downloads/one.epub' and flat[2].source_kind=='ao3_downloaded')
assert(Repo.getBySource({kind='native'})[1].native)
local authors,total=Repo.getBySource({kind='ao3_authors'},nil,{{key='series_name'}},0,10)
assert(total==3 and authors[1].series_name=='Anonymous' and authors[2].series_name=='Coauthor')
assert(authors[3].series_name=='Writer' and #authors[3].books==2 and authors[3].kind=='author')
local page,count=Repo.getBySource({kind='ao3_authors'},nil,{{key='book_count',reverse=true}},0,1)
assert(count==3 and #page==1 and page[1].series_name=='Writer')
local filtered,n=Repo.getBySource({kind='ao3_authors'},{ao3_categories={['M/M']=true}},nil,0,10)
assert(n==2 and #filtered[1].books==1)
local finished=Repo.getBySource({kind='ao3_authors'},{statuses={finished=true}},nil,0,10)
assert(#finished==1 and finished[1].series_name=='Writer' and #finished[1].books==1)
local fandoms=Repo.getBySource({kind='ao3_fandoms'},nil,nil,0,10)
assert(#fandoms==3 and fandoms[1].series_name=='A' and fandoms[2].book_count==2)
assert(fandoms[3].series_name=='Unknown fandom' and fandoms[3].kind=='genre')
local choices=Repo.distinctFilterValues('ao3_categories',{kind='ao3_authors'})
assert(#choices==1 and choices[1].value=='M/M' and choices[1].count==1)
-- Native author/genre drill frames must restore the AO3 scope, not a native
-- author/genre group with the same label and unrelated library members.
local bw=setmetatable({_drilldown_path={{kind='author',label='Writer',payload=authors[3]}}},{__index=Widget})
local snapshot=bw:_serializeDrillPath()
assert(snapshot[1]._fanfic_ao3.source=='ao3_downloaded')
local restored=setmetatable({_drilldown_path={}},{__index=Widget})
restored:_restoreDrillPath(snapshot)
assert(restored._drilldown_path[1].kind=='author' and restored._drilldown_path[1].label=='Writer')
assert(#restored:_fetchChipItems()==2 and not restored._drilldown_path[1].whole)
assert(restored:_currentRegisteredSource().kind=='ao3_downloaded')
local unknown=setmetatable({_drilldown_path={{kind='genre',label='Unknown fandom',payload=fandoms[3]}}},{__index=Widget})
local unknown_snapshot=unknown:_serializeDrillPath()
local unknown_restored=setmetatable({_drilldown_path={}},{__index=Widget})
unknown_restored:_restoreDrillPath(unknown_snapshot)
assert(#unknown_restored:_fetchChipItems()==1)
assert(unknown_restored:_fetchChipItems()[1].filepath=='/home/unknown.epub')
-- Deletions and metadata changes are reflected even before another directory scan.
works['/home/two.epub']=nil
assert(#restored:_fetchChipItems()==1)
works['/downloads/one.epub'].authors={'New writer'}
assert(#restored:_fetchChipItems()==0)
local refreshed=false
Sources.get('ao3_downloaded').refresh({},nil,function() refreshed=true end)
assert(not refreshed and #scans==2)
complete(2,{one=works['/downloads/one.epub']})
assert(refreshed and #Sources.list('ao3_downloaded')==1)
-- Changing roots cancels an in-flight scan and rejects its stale completion.
Sources.invalidate();Sources.list('ao3_downloaded');assert(#scans==3)
folder='/different';Sources.list('ao3_downloaded');assert(#scans==4 and scans[3].cancelled())
assert(#Sources.list('ao3_downloaded')==0)
complete(3,{one=works['/downloads/one.epub']})
assert(#Sources.list('ao3_downloaded')==0)
complete(4,{})
assert(#Sources.list('ao3_downloaded')==0)
assert(not Extension.install({}), 'older Bookshelf must remain usable')
print('PASS: source picker; asynchronous read-only roots scan; coauthors/multiple fandoms/unknown metadata; native filters/sort/page; offline local records; saved group scope; refresh/deletion/root changes; idempotence/older API')
