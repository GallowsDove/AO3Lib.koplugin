-- Run from the AO3 plugin directory: luajit tests/test_organizer.lua
-- Exercises the real Bookshelf move engine against an isolated virtual disk.
package.path = './?.lua;../bookshelf.koplugin/?.lua;' .. package.path
local function stub(name,value) package.loaded[name]=value end
local disk={['/']={mode='directory'}}
local clock=1
local function norm(path)
    path=path:gsub('/+$',''); return path=='' and '/' or path
end
local function parent(path) return path:match('^(.*)/[^/]+$') or '/' end
local function mkdir(path)
    path=norm(path)
    if disk[path] then return disk[path].mode=='directory' or nil, 'not a directory' end
    if path~='/' then assert(mkdir(parent(path))) end
    disk[path]={mode='directory'}; return true
end
local function put(path,data)
    assert(mkdir(parent(path)))
    clock=clock+1; disk[path]={mode='file',data=data,size=#data,modification=clock}
end
local lfs={currentdir=function() return '/cwd' end, mkdir=mkdir}
function lfs.attributes(path,key)
    local entry=disk[norm(path)]
    if key then return entry and entry[key] end
    return entry
end
lfs.symlinkattributes=lfs.attributes
function lfs.dir(path)
    path=norm(path)
    local names={}; for key in pairs(disk) do
        if key~=path and parent(key)==path then names[#names+1]=key:match('([^/]+)$') end
    end
    table.sort(names)
    local i=0
    return function() i=i+1; return names[i] end, {close=function() end}
end
local temp_sequence=0
stub('ao3lib.core.tempfile',{reserve=function(prefix)
    temp_sequence=temp_sequence+1
    local name=prefix..temp_sequence;put(name,'');return name
end})
stub('libs/libkoreader-lfs',lfs)
local real_open, real_rename, real_remove, real_tmpname = io.open, os.rename, os.remove, os.tmpname
local writes=0
io.open=function(path,mode)
    path=norm(path); mode=mode or 'r'
    local entry=disk[path]
    if mode:find('w') or mode:find('a') then
        if not disk[norm(parent(path))] then return nil,'missing parent' end
        if not mode:find('a') or not entry then put(path,'') end
    elseif not entry or entry.mode~='file' then return nil,'not found' end
    local position=1
    return {
        read=function(_,n)
            local s=disk[path].data
            if n=='*a' then return s:sub(position) end
            if position>#s then return nil end
            local chunk=s:sub(position,position+n-1); position=position+#chunk; return chunk
        end,
        write=function(self,s)
            writes=writes+1
            disk[path].data=disk[path].data..s; disk[path].size=#disk[path].data; return self
        end,
        close=function() return true end,
    }
end
local failSidecar=false
os.rename=function(from,to)
    from,to=norm(from),norm(to)
    if failSidecar and from:match('%.sdr$') then return nil,'sidecar failure' end
    if not disk[from] or not disk[norm(parent(to))] then return nil,'not found' end
    local updates={}
    for path,entry in pairs(disk) do
        if path==from or path:sub(1,#from+1)==from..'/' then updates[path]=entry end
    end
    for path in pairs(updates) do disk[path]=nil end
    for path,entry in pairs(updates) do disk[to..path:sub(#from+1)]=entry end
    return true
end
os.remove=function(path) disk[path]=nil; return true end
local temp=0
os.tmpname=function() temp=temp+1; return '/tmp/token'..temp end
local function deepcopy(t)
    if type(t)~='table' then return t end
    local out={}; for k,v in pairs(t) do out[k]=deepcopy(v) end; return out
end
local function encode(value)
    if type(value)=='string' then return '"'..value:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n')..'"' end
    if type(value)=='number' or type(value)=='boolean' then return tostring(value) end
    if type(value)=='table' then
        local out={}; for k,v in pairs(value) do out[#out+1]=encode(tostring(k))..':'..encode(v) end
        table.sort(out); return '{'..table.concat(out,',')..'}'
    end
    return 'null'
end
stub('dkjson',{encode=encode})
local util={trim=function(s) return s:match('^%s*(.-)%s*$') end,makePath=mkdir,tableDeepCopy=deepcopy,
    getSafeFilename=function(s,_,limit) return s:sub(1,limit or 240) end}
stub('util',util)
stub('ffi/util',{realpath=function(path) if path:sub(1,1)=='/' and disk[norm(path)] then return norm(path) end end})
stub('logger',{dbg=function() end,warn=function() end})
stub('datastorage',{getDataDir=function() return '/ko' end,getSettingsDir=function() return '/ko/settings' end})
stub('ao3lib.core.persistent',{path=function(name) return '/ko/settings/ao3lib/'..name end})
stub('ao3lib.core.paths',{getHomeDirectory=function() return '/ko/fanfic' end})
stub('ao3lib.core.config',{readSetting=function(_,key,default) return default end})
G_reader_settings={readSetting=function(_,key,default) return default end}
local function sidecar(path) return path:gsub('%.[^/.]+$','')..'.sdr' end
local DS={}
function DS:getSidecarDir(path,loc)
    if loc=='dir' then return '/central'..sidecar(path) end
    if loc=='hash' then return '/hash/'..path:match('([^/]+)$')..'.sdr' end
    return sidecar(path)
end
function DS.getSidecarFilename() return 'metadata.epub.lua' end
function DS:hasSidecarFile(path) return disk[sidecar(path)..'/metadata.epub.lua']~=nil end
function DS:findSidecarFile(path)
    if self:hasSidecarFile(path) then return sidecar(path)..'/metadata.epub.lua','doc' end
end
function DS.updateLocation() error('fallback not available in fixture') end
function DS:open() return {readSetting=function() return nil end} end
stub('docsettings',DS)
local history,collections,historyCalls,collectionCalls = {},{},0,0
stub('readhistory',{updateItem=function(_,old,new)
    historyCalls=historyCalls+1; if history[old] then history[new]=history[old]; history[old]=nil end
end,updateItems=function() error('Batch API must not be used for renamed books') end})
stub('readcollection',{updateItem=function(_,old,new)
    collectionCalls=collectionCalls+1; if collections[old] then collections[new]=collections[old]; collections[old]=nil end
end,updateItems=function() error('Batch API must not be used for renamed books') end})
stub('lib/bookshelf_hardcover',{relinkPath=function() end})
stub('ui/widget/booklist',{resetBookInfoCache=function() end})
stub('lib/bookshelf_book_repository',{invalidateWalkCache=function() end})
stub('lib/bookshelf_scaled_cover_cache',{drop=function() end})
stub('ui/event',{new=function(_,name) return name end})
stub('ui/uimanager',{broadcastEvent=function() end})
local reader={}
stub('apps/reader/readerui',reader)
stub('lib/bookshelf_reader_park',{parkedFile=function() end})
stub('apps/filemanager/filemanager',{moveFile=function() return false end})
local Epub={read=function(path)
    local e=disk[path]; local id=e and e.data and e.data:match('^EPUB:(%d+)')
    if id then return {id=id,path=path} end
end}
stub('ao3lib.library.epub',Epub)
mkdir('/ko/settings'); mkdir('/ko/settings/ao3lib'); mkdir('/ko/fanfic'); mkdir('/books'); mkdir('/cwd')
put('/ko/history.lua','original history')
put('/ko/settings/collection.lua','original collections')
put('/ko/settings.reader.lua','original settings')
local History=require('ao3lib.library.history')
local Layout=require('ao3lib.library.layout')
local Organizer=require('ao3lib.library.organizer')
local function work(id,author,title,path,withState)
    path=path or ('/books/'..id..'.epub')
    put(path,'EPUB:'..id)
    local w={id=id,path=path,author=author,title=title,chapter_data={{id='chapter',read=true}},read=true}
    History.add(w)
    if withState then
        put(sidecar(path)..'/metadata.epub.lua','XP0INTER+ANNOTATIONS+BOOKMARKS')
        put(sidecar(path)..'/cover.png','CUSTOM COVER')
        put(sidecar(path)..'/plugin-state.dat','CUSTOM PLUGIN DATA')
        put(path..'.txt','NOTEBOOK')
    end
    history[path],collections[path]='last read page','Favorites'
    return w
end
local opts={template='%A/%T'}
assert(Layout.author({author='Pseud (account), Other'})=='account')
assert(Layout.author({author='A/B:C'})=='A_B_C')
assert(Layout.basePath({author='Writer',title='A title',id='1'},'/books',opts)=='/books/Writer/A title.epub')
assert(Layout.basePath({author='Writer',title='A title',id='1'},'/books',{template='%t_%I'})=='/books/A_title_1.epub')
local example={id='42',title='A story',author='Pen (first-user), Second',fandoms={'One','Two'},
    language='English',published='2020-02-01',iswip='Complete',series={{title='A series'}}}
assert(Layout.basePath(example,'/books',{template='%F/%A/%T [%I]'})=='/books/Crossover/first-user/A story [42].epub')
assert(Layout.basePath(example,'/books',{template='%L/%Y/%S/%R/%B'})=='/books/English/2020/Complete/A series/Pen (first-user), Second.epub')
assert(Layout.basePath({title='Title',fandoms={'A fandom, with comma'}},'/books',{template='%F/%T'})=='/books/A fandom, with comma/Title.epub')
assert(Layout.basePath({title='Title',fandoms={}},'/books',{template='%F/%T'})=='/books/Unknown fandom/Title.epub')
assert(Layout.basePath({title='../Unsafe/Title',fandoms={'../Escaping'}},'/books',{template='%F/%T'})=='/books/.._Escaping/.._Unsafe_Title.epub')
for _,bad in ipairs({'/absolute','../%T','%A//%T','%A/','%Z','%T%','a\\b','./%T'}) do
    assert(not Layout.validate(bad),'Unsafe or invalid template accepted: '..bad)
    assert(not Layout.destination(example,'/books',{template=bad}))
end
assert(Layout.validate('%F/%A/%T [%I]'))
assert(Layout.basePath({title='Story',series={{title='First'},{title='Second'}}},'/books',{template='%R/%T'})=='/books/First/Story.epub')
assert(Layout.basePath({title='Story',series={}},'/books',{template='%R/%T'})=='/books/No series/Story.epub')
assert(Layout.root('./more')=='/cwd/more')
local a=work('1','Pseud (Writer)','Shared title',nil,true)
local originalA=a.path
a.fandoms={'First','Second'}
local crossover_plan=assert(Organizer.plan({a},'/books',{template='%F/%A/%T'}))
assert(crossover_plan.moves[1].to=='/books/Crossover/Writer/Shared title.epub')
assert(Organizer.describe(crossover_plan):find('%F/%A/%T',1,true))
a.fandoms=nil
local b=work('2','Writer','Shared title')
local c=work('3','Another','../Unsafe: title?')
local open=work('4','Writer','Open book')
reader.instance={document={file=open.path}}
local before=writes
local plan=assert(Organizer.plan({a,b,c,open},'/books',opts))
assert(writes==before, 'Preview must not create folders or change metadata')
assert(#plan.moves==3 and #plan.skipped==1 and plan.skipped[1].reason=='Currently open')
assert(plan.moves[1].to=='/books/Writer/Shared title.epub')
assert(plan.moves[2].to=='/books/Writer/Shared title [2].epub')
assert(not plan.moves[3].to:find('/../',1,true))
local summary=assert(Organizer.execute(plan))
assert(summary.moved==3 and summary.failed==0 and summary.skipped==0 and #summary.errors==0)
local new=plan.moves[1].to
assert(not disk[originalA] and disk[new].data=='EPUB:1')
assert(disk[sidecar(new)..'/metadata.epub.lua'].data=='XP0INTER+ANNOTATIONS+BOOKMARKS')
assert(disk[sidecar(new)..'/cover.png'].data=='CUSTOM COVER')
assert(disk[sidecar(new)..'/plugin-state.dat'].data=='CUSTOM PLUGIN DATA')
assert(disk[new..'.txt'].data=='NOTEBOOK')
assert(history[new]=='last read page' and not history[originalA] and collections[new]=='Favorites' and not collections[originalA])
local saved=History.getAll()['1']
assert(saved.path==new and saved.read and saved.chapter_data[1].read)
assert(historyCalls>=3 and collectionCalls>=3)
assert(disk[summary.journal] and disk[parent(summary.journal)..'/events.jsonl'])
local metadataBackedUp=false
for _,backup in ipairs(plan.backups) do
    if backup.source==sidecar(originalA) then
        metadataBackedUp=disk[backup.backup..'/metadata.epub.lua'].data=='XP0INTER+ANNOTATIONS+BOOKMARKS'
    end
end
assert(metadataBackedUp and disk['/ko/settings/ao3lib/fanfic_history.json'])
local historyBackedUp=false
for _,backup in ipairs(plan.backups) do
    if backup.source=='/ko/settings/ao3lib/fanfic_history.json' then historyBackedUp=true end
end
assert(historyBackedUp)
-- Re-running is idempotent. Orphan sidecars and case-insensitive reservations
-- are collisions too, without overwriting any old state.
local again=assert(Organizer.plan(History.getAll(),'/books',opts))
assert(#again.moves==0)
local orphan=work('5','Writer','Orphan')
put('/books/Writer/Orphan.sdr/metadata.epub.lua','UNRELATED STATE')
local orphanPlan=assert(Organizer.plan({orphan},'/books',opts))
assert(orphanPlan.moves[1].to=='/books/Writer/Orphan [5].epub')
local late=work('6','Writer','Late collision')
local latePlan=assert(Organizer.plan({late},'/books',opts))
put(latePlan.moves[1].to,'OTHER BOOK')
local lateResult=assert(Organizer.execute(latePlan))
assert(lateResult.moved==0 and lateResult.skipped==1 and disk[late.path].data=='EPUB:6')
assert(disk[latePlan.moves[1].to].data=='OTHER BOOK' and History.getAll()['6'].path==late.path)
local changed=work('7','Writer','Changed source')
local changedPlan=assert(Organizer.plan({changed},'/books',opts))
put(changed.path,'EPUB:999')
assert(Organizer.execute(changedPlan).skipped==1)
local busy=work('8','Writer','Becomes open')
local busyPlan=assert(Organizer.plan({busy},'/books',opts))
reader.instance.document.file=busy.path
assert(Organizer.execute(busyPlan).skipped==1)
reader.instance=nil
-- A backup failure aborts before any file moves.
local fail=work('9','Writer','Backup failure')
local failPlan=assert(Organizer.plan({fail},'/books',opts))
local backup=Organizer.backup
Organizer.backup=function() error('out of space') end
local failed,err=Organizer.execute(failPlan)
assert(not failed and err:find('no works were moved',1,true) and disk[fail.path])
Organizer.backup=backup
-- A failed physical move must not rewrite AO3 history.
local moveFailure=work('10','Writer','Physical failure')
local failedPlan=assert(Organizer.plan({moveFailure},'/books',opts))
local rename=os.rename
os.rename=function(from,to) if from==moveFailure.path then return nil,'denied' end; return rename(from,to) end
local failedSummary=assert(Organizer.execute(failedPlan))
assert(failedSummary.failed==1 and failedSummary.moved==0 and History.getAll()['10'].path==moveFailure.path)
os.rename=rename
-- If the sidecar cannot follow, move the book back and retain original progress.
local stateFailure=work('11','Writer','State failure',nil,true)
local statePlan=assert(Organizer.plan({stateFailure},'/books',opts))
failSidecar=true
local stateResult=assert(Organizer.execute(statePlan))
failSidecar=false
assert(stateResult.failed==1 and stateResult.moved==0 and disk[stateFailure.path])
assert(disk[sidecar(stateFailure.path)..'/metadata.epub.lua'].data=='XP0INTER+ANNOTATIONS+BOOKMARKS')
assert(History.getAll()['11'].path==stateFailure.path)
-- Files occupying author directory names are caught in the preview.
local blocked=work('12','Blocked','Title')
put('/books/Blocked','not a directory')
local blockedPlan=assert(Organizer.plan({blocked},'/books',opts))
assert(#blockedPlan.moves==0 and blockedPlan.skipped[1].reason:find('occupied',1,true))
-- Exercise the actual preview UI: cancellation is read-only, and execution
-- is available only from the concrete preview's Organize button.
local shown,closed,tasks={}, {}, {}
local UI=require('ui/uimanager')
UI.show=function(_,widget) shown[#shown+1]=widget end
UI.close=function(_,widget) closed[widget]=true end
UI.scheduleIn=function(_,_,fn) tasks[#tasks+1]=fn end
UI.forceRePaint=function() end
local Class={new=function(_,t) return t end}
stub('ui/widget/infomessage',Class)
stub('ui/widget/textviewer',Class)
stub('gettext',function(s) return s end)
stub('apps/filemanager/filemanagerutil',{getHomeFolder=function() return '/books' end})
local uiWork=work('13','Writer','Preview book',nil,true)
local uiSource=uiWork.path
stub('ao3lib.library.discovery',{scan=function(roots,done)
    assert(roots[1]=='/books' and roots[2]=='/books'); done({uiWork})
end})
stub('ao3lib.core.config',{readSetting=function(_,key,default)
    if key=='fanfic_folder_path' then return '/books' end; return default
end})
local OrganizerUI=require('ao3lib.ui.organizer')
local beforeUI=writes
OrganizerUI.show({ui={}})
local preview=shown[#shown]
assert(preview.title:find('preview',1,true) and preview.text:find('Preview book.epub',1,true))
assert(writes==beforeUI and disk[uiSource])
preview.buttons_table[1][1].callback()
assert(closed[preview] and writes==beforeUI and disk[uiSource])
OrganizerUI.show({ui={}})
shown[#shown].buttons_table[1][2].callback()
assert(#tasks==1 and disk[uiSource])
table.remove(tasks,1)()
assert(shown[#shown].title=='Organization results' and not disk[uiSource])
assert(disk['/books/Writer/Preview book.epub'] and History.getAll()['13'].chapter_data[1].read)
-- A real update uses the organizer to move the replacement and every sidecar.
local updateWork=work('14','Writer','Updated story','/books/original.epub',true)
updateWork.fandoms={'First'};updateWork.chapters='1/2';History.update(updateWork)
local old_path=updateWork.path
local updateSettings=require('ao3lib.core.config')
updateSettings.readSetting=function(_,key,default)
    if key=='fanfic_folder_path' then return '/books' end
    if key=='download_layout_template' then return '%F/%S/%A/%T' end
    return default
end
local cache_removed,indexed
stub('ao3lib.library.local_cache',{removePath=function(path) cache_removed=path end,index=function(path) indexed=path end})
stub('ao3lib.library.metadata_refresh',{notify=function() end})
stub('ao3lib.ao3.client',{downloadEpub=function(_,url,path,replace,check)
    assert(path==old_path and replace and check())
    put(path,'EPUB:14 updated');return {success=true}
end})
local Updates=require('ao3lib.updates.checks')
local current=disk[old_path]
local entry={work=updateWork,local_work={id='14',chapters='1/2'},
    fingerprint={size=current.size,mtime=current.modification,change=current.change},
    remote={id='14',title='Updated story',author='Writer',fandoms={'First','Second'},iswip='Complete',
        chapters='1/1',epub_link='https://example.test/a',chapterData={{id='chapter',name='First'}}}}
local result=Updates.apply(entry)
local target='/books/Crossover/Complete/Writer/Updated story.epub'
assert(result.success and not result.move_error and result.work.path==target and disk[target] and not disk[old_path])
assert(History.get('14').path==target and History.get('14').chapter_data[1].read)
assert(disk[sidecar(target)..'/metadata.epub.lua'].data=='XP0INTER+ANNOTATIONS+BOOKMARKS')
assert(disk[target..'.txt'].data=='NOTEBOOK' and history[target]=='last read page' and collections[target]=='Favorites')
assert(cache_removed==old_path and indexed==target)
-- A failed move retains the successful update and provides an actionable warning.
local failWork=work('15','Writer','No move','/books/no-move.epub',true)
failWork.chapters='1/2';History.update(failWork);old_path=failWork.path
current=disk[old_path]
entry={work=failWork,local_work={id='15',chapters='1/2'},
    fingerprint={size=current.size,mtime=current.modification,change=current.change},
    remote={id='15',title='No move',author='Writer',fandoms={'New'},iswip='Complete',
        chapters='1/1',epub_link='https://example.test/b',chapterData={{id='chapter'}}}}
package.loaded['ao3lib.ao3.client'].downloadEpub=function(_,url,path,replace,check)
    assert(check());put(path,'EPUB:15 updated');return {success=true}
end
local originalFileOps=Organizer.fileOps
Organizer.fileOps=function() return nil,'Bookshelf unavailable' end
result=Updates.apply(entry);Organizer.fileOps=originalFileOps
assert(result.success and result.move_error=='Bookshelf unavailable' and result.work.path==old_path)
assert(disk[old_path].data=='EPUB:15 updated' and History.get('15').chapter_data[1].read)
assert(disk[sidecar(old_path)..'/metadata.epub.lua'].data=='XP0INTER+ANNOTATIONS+BOOKMARKS')
print('PASS: updated work automatically moves using organizer backups; progress, sidecars, notes, history and collections preserved; failed moves reported')
io.open,os.rename,os.remove,os.tmpname=real_open,real_rename,real_remove,real_tmpname
print('PASS: author/title layout; collision/idempotence/preview; native Bookshelf moves preserve sidecars, notes, history, collections and AO3 progress; backups/journal; changed/open sources; physical/sidecar/backup failures')
