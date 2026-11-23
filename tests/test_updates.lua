-- Run from the plugin directory: luajit tests/test_updates.lua
package.path='./?.lua;'..package.path
local function stub(name,t) package.loaded[name]=t end
stub('ao3lib.core.config',{readSetting=function(_,key,default) if key=='update_check_delay_seconds' then return 9 end;return default end})
local function copy(t)
    if type(t)~='table' then return t end
    local out={}; for k,v in pairs(t) do out[k]=copy(v) end; return out
end
stub('util',{tableDeepCopy=copy,trim=function(s) return s:match('^%s*(.-)%s*$') end})
stub('gettext',function(s) return s end)
stub('ffi/util',{})
local files,epubs,saved,remote={},{},{},{}
local downloads,checks,saves=0,0,0
local fail_download,fail_save,change_during_download=false,false,false
local Reader={instance=nil}
stub('apps/reader/readerui',Reader)
local parked
stub('lib/bookshelf_reader_park',{parkedFile=function() return parked end})
stub('libs/libkoreader-lfs',{attributes=function(path) return copy(files[path]) end,
    symlinkattributes=function(path) return copy(files[path]) end})
stub('ao3lib.library.epub',{read=function(path) return copy(epubs[path]) end})
stub('ao3lib.library.history',{
    get=function(id) return copy(saved[tostring(id)]) end,
    update=function(work)
        saves=saves+1; saved[tostring(work.id)]=copy(work)
        if fail_save then return nil,'disk full' end
        return true
    end,
    save=function() if fail_save then return nil,'disk full' end; return true end,
})
stub('ao3lib.ao3.client',{
    getWorkMetadata=function(_,id)
        checks=checks+1
        local value=remote[tostring(id)]
        if value.throw then error('parser failure') end
        return value.success==false and copy(value) or {success=true,work_metadata=copy(value)}
    end,
    downloadEpub=function(_,url,path,replace,before_commit)
        downloads=downloads+1
        assert(replace and url:find('https://',1,true))
        if fail_download then return {success=false,error='Download interrupted'} end
        if change_during_download then files[path].size=files[path].size+1 end
        local allowed,reason=before_commit()
        if not allowed then return {success=false,error=reason} end
        files[path].size=files[path].size+10
        files[path].modification=files[path].modification+1
        for _,work in pairs(remote) do if work.epub_link==url then
            epubs[path]=copy(work); epubs[path].path=path
        end end
        return {success=true,filepath=path}
    end,
})
local function fixture(id,chapters)
    id=tostring(id)
    local path='/books/'..id..'.epub'
    files[path]={mode='file',size=100,modification=1,change=1}
    epubs[path]={id=id,path=path,title='Work '..id,author='Writer',chapters=chapters or '2/3',wordcount='1,000',updated='2026-01-01'}
    saved[id]=copy(epubs[path]); saved[id].last_accessed='2025-01-01'
    saved[id].chapter_data={{id='10',name='First',read=true},{id='20',name='Second',read=false}}
    remote[id]={id=id,title='Work '..id,author='Writer',chapters='3/3',wordcount='2,000',updated='2026-02-01',
        epub_link='https://example.test/'..id..'.epub',chapterData={{id='10'},{id='20'},{id='30'}}}
    return copy(saved[id])
end
local Updates=require('ao3lib.updates.checks')
local work=fixture('1')
work.chapters='99/99' -- History metadata must never replace the actual EPUB baseline.
local entry=Updates.check(work)
assert(entry.status=='update' and entry.local_work.chapters=='2/3' and #entry.changes==3)
assert(downloads==0 and saves==0 and not entry.selected)
-- Reordered/inserted chapters preserve flags by ID, not array position.
remote['1'].chapterData={{id='30'},{id='10'},{id='20'}}
entry=Updates.check(work)
saved['1'].chapter_data[2].read=true -- Use the latest state, not the review's snapshot.
local updated=Updates.apply(entry)
assert(updated.success and downloads==1 and saves==1)
assert(saved['1'].path==work.path and saved['1'].last_accessed=='2025-01-01')
assert(not saved['1'].chapter_data[1].read and saved['1'].chapter_data[2].read and saved['1'].chapter_data[3].read)
assert(not remote['1'].chapterData[2].read, 'Remote review metadata must stay immutable')
work=fixture('2')
entry=Updates.check(work)
local before=copy(files[work.path]); local before_saved=copy(saved['2'])
fail_download=true
assert(not Updates.apply(entry).success and files[work.path].size==before.size and saved['2'].chapters==before_saved.chapters)
fail_download=false
files[work.path].size=101
local old_downloads=downloads
assert(not Updates.apply(entry).success and downloads==old_downloads)
files[work.path]=before
Reader.instance={document={file=work.path}}
assert(not Updates.apply(entry).success and downloads==old_downloads)
Reader.instance=nil; parked=work.path
assert(not Updates.apply(entry).success and downloads==old_downloads)
parked=nil; change_during_download=true
assert(not Updates.apply(entry).success and saved['2'].chapters==before_saved.chapters)
change_during_download=false
work=fixture('3'); entry=Updates.check(work)
fail_save=true
local failed=Updates.apply(entry)
assert(not failed.success and failed.downloaded and failed.error:find('disk full',1,true))
fail_save=false
work=fixture('4'); remote['4'].chapters='1/1'; entry=Updates.check(work)
assert(entry.status=='review')
work=fixture('5'); remote['5']=copy(epubs[work.path]); remote['5'].epub_link='https://example.test/5.epub'
assert(Updates.check(work).status=='current')
remote['5'].updated='2025-01-01'
assert(Updates.check(work).status=='review')
work=fixture('6','?/?'); epubs[work.path].wordcount=nil; epubs[work.path].updated=nil
assert(Updates.check(work).status=='review')
work=fixture('7'); remote['7']={success=false,status=404,error='Not found'}
assert(Updates.check(work).status=='unavailable')
work=fixture('8'); remote['8'].chapterData={{id='10'}}
entry=Updates.check(work); old_downloads=downloads
assert(not Updates.apply(entry).success and downloads==old_downloads)
work=fixture('9','2/2'); saved['9'].read=true; saved['9'].chapter_data={}
remote['9'].chapters='2/2'; remote['9'].chapterData={{id='10'},{id='20'}}
assert(Updates.apply(Updates.check(work)).success and saved['9'].chapter_data[1].read and saved['9'].chapter_data[2].read)
-- AO3 omits the status date on many one-shots. The display placeholder
-- sorts after ISO dates lexically, but is never evidence of an update.
work=fixture('missing-date','1/1')
remote['missing-date']=copy(epubs[work.path])
remote['missing-date'].epub_link='https://example.test/missing-date.epub'
for _,invalid in ipairs({'Unknown date','N/A','','2026-02-30','2026-13-01'}) do
    remote['missing-date'].updated=invalid
    local checked=Updates.check(work)
    assert(checked.status=='current' and #checked.changes==0,invalid)
end
remote['missing-date'].updated=nil
assert(Updates.check(work).status=='current')
epubs[work.path].published='2026-02-01'
epubs[work.path].updated='Unknown date'
remote['missing-date'].published='2026-02-01'
remote['missing-date'].updated='Unknown date'
assert(Updates.check(work).status=='current')
remote['missing-date'].published='2026-02-02'
assert(Updates.check(work).status=='update','Valid publication dates remain comparable')
epubs[work.path].updated='2026-02-01'
remote['missing-date'].published='2026-02-01'
remote['missing-date'].wordcount='3000'
remote['missing-date'].chapterData={}
entry=Updates.check(work)
assert(entry.status=='update' and #entry.changes==1 and entry.changes[1]:find('Words:',1,true))
assert(Updates.apply(entry).success)
assert(saved['missing-date'].updated~='Unknown date','Unknown remote dates must not overwrite known saved dates')
work=fixture('word-format','7/10')
epubs[work.path].wordcount='43,199'
remote['word-format'].wordcount='46494'
remote['word-format'].chapters='8/10'
entry=Updates.check(work)
assert(entry.changes[1]=='1 new chapter · 7 → 8')
assert(entry.changes[2]=='Words: 43,199 → 46,494')
print('PASS: unknown/malformed dates ignored; publication fallback; real changes still detected; missing dates never saved over known dates')
print('PASS: actual EPUB comparisons; edits/new chapters/completion; no downloads during review; ID-based latest progress; same paths; open/parked/changed sources; download/state-save failures')

-- Scheduled checks can stop, resume, retry individual failures, and pause
-- for service-wide failures without contacting every remaining work.
local jobs,delays={},{}
local function schedule(delay,callback) jobs[#jobs+1]=callback; delays[#delays+1]=delay end
local function nextJob() assert(#jobs>0); table.remove(jobs,1)() end
local function drain() local n=0; while #jobs>0 do n=n+1; assert(n<100); nextJob() end end
local a,b,c=fixture('a'),fixture('b'),fixture('c')
local session=Updates.new({a,b,c})
local start_checks=checks
assert(session:run('check',session.entries,function() end,schedule))
nextJob()
assert(checks==start_checks+1 and session.busy and delays[2]==9)
session:stop(); drain()
assert(checks==start_checks+1)
local pending={session.entries[2],session.entries[3]}
remote['b']={success=false,status=404,error='Deleted'}
assert(session:run('check',pending,nil,schedule)); drain()
assert(session.entries[2].status=='unavailable' and session.entries[3].status=='update')
local reused=Updates.new({a,b,c},session)
assert(reused.entries[1].status=='update' and reused.entries[2].status=='unavailable')
remote['a']={success=false,status=429,retry_later=true,error='Slow down',response_headers={['retry-after']='120'}}
start_checks=checks
assert(session:run('check',session.entries,nil,schedule)); drain()
assert(checks==start_checks+1 and not session.busy and session.retry_at>=os.time()+119)
assert(not session:run('check',pending,nil,schedule))
local reopened=Updates.new({a,b,c},session)
assert(reopened.retry_at==session.retry_at)
session.retry_at=nil
remote['a']={success=false,status=503,retry_later=true,error='Maintenance'}
assert(session:run('check',session.entries,nil,schedule)); drain()
assert(session.pause_reason=='Maintenance')
local d,e,f,g=fixture('d'),fixture('e'),fixture('f'),fixture('g')
for _,id in ipairs({'d','e','f','g'}) do remote[id]={success=false,unexpected_response=true,error='Unexpected page'} end
local malformed=Updates.new({d,e,f,g})
start_checks=checks
assert(malformed:run('check',malformed.entries,nil,schedule)); drain()
assert(checks==start_checks+3 and malformed.pause_reason=='Unexpected page' and malformed.entries[4].status=='unchecked')
session.retry_at=nil
session.closed=true
assert(not session:run('check',pending,nil,schedule))
local update_work=fixture('selected')
local selection=Updates.new({update_work})
assert(selection:run('check',selection.entries,nil,schedule)); drain()
selection.entries[1].selected=true
assert(selection:run('update',{selection.entries[1]},nil,schedule)); drain()
assert(selection.entries[1].status=='updated' and not selection.entries[1].selected)
print('PASS: paced scheduled requests; stop/resume; individual 404 failures; review reuse; rate-limit Retry-After; maintenance pause; closed-screen cancellation; selected updates')
local state_work=fixture('savefail')
local state_session=Updates.new({state_work})
assert(state_session:run('check',state_session.entries,nil,schedule)); drain()
fail_save=true
assert(state_session:run('update',state_session.entries,nil,schedule)); drain()
assert(state_session.entries[1].status=='state_error')
old_downloads=downloads
assert(not Updates.retrySave(state_session))
fail_save=false
assert(Updates.retrySave(state_session) and state_session.entries[1].status=='updated' and downloads==old_downloads)

-- Exercise the actual screen's callbacks, including the Wi-Fi continuation.
local shown,connected,pending_connection={},false,nil
local UI={show=function(_,widget) shown[#shown+1]=widget end,
    close=function() end, setDirty=function() end,
    scheduleIn=function(_,delay,callback) schedule(delay,callback) end}
stub('ui/uimanager',UI)
stub('ui/network/manager',{
    isConnected=function() return connected end,
    runWhenConnected=function(_,callback) pending_connection=callback end,
})
local Class={new=function(self,args) return setmetatable(args,{__index=self}) end,
    updateItems=function() end}
for _,name in ipairs({'menu','infomessage','textviewer','notification','buttondialog'}) do stub('ui/widget/'..name,Class) end
stub('ao3lib.core.config',{readSetting=function() return '/books' end})
stub('apps/filemanager/filemanagerutil',{getHomeFolder=function() return '/home' end})
local ui1,ui2=fixture('ui1'),fixture('ui2')
stub('ao3lib.library.discovery',{scan=function(roots,done)
    assert(roots[1]=='/books' and roots[2]=='/home'); done({ui1,ui2})
end})
local persisted
stub('ao3lib.updates.store',{
    load=function() return copy(persisted) end,
    save=function(state) persisted=copy(state) end,
    flush=function(state) persisted=copy(state);return true end,
})
stub('ui/bidi',{mirroredUILayout=function() return false end})
stub('ao3lib.ui.update_review_header',{new=function()
    return {update=function(self,model) self.model=model end}
end})
local Review=require('ao3lib.ui.update_review')
require('ao3lib.ui.library_rescan').show()
Review.show({ui={}})
local menu=shown[#shown]
assert(menu.title=='Downloaded work updates')
assert(menu.is_borderless and not menu.is_popout and menu.linesize==0)
assert(menu.with_bottom_line and menu.title_bar_left_icon=='ao3')
local function find(text)
    for _,row in ipairs(menu.item_table) do if row.text:find(text,1,true) then return row end end
    local model=menu.review_model
    if model.summary:find(text,1,true) then return {text=model.summary} end
    local actions={}
    for _,row in ipairs(model.buttons) do for _,button in ipairs(row) do actions[#actions+1]=button end end
    for _,button in ipairs(model.filters) do actions[#actions+1]=button end
    for _,button in ipairs(model.more) do actions[#actions+1]=button end
    if model.select_all then actions[#actions+1]=model.select_all end
    for _,button in ipairs(actions) do if button.text:find(text,1,true) then return button end end
    error('Missing control: '..text)
end
local function tap(text) menu:onMenuSelect(find(text)) end
start_checks=checks; old_downloads=downloads
assert(find('Update selected (0)').enabled==false)
tap('Check for updates')
assert(pending_connection and checks==start_checks, 'Wi-Fi prompt must preserve the check')
connected=true
local reconnect=pending_connection; pending_connection=nil; reconnect()
nextJob()
assert(checks==start_checks+1 and downloads==old_downloads)
tap('Stop checking'); drain()
assert(checks==start_checks+1)
tap('Continue checking'); drain()
assert(checks==start_checks+2 and downloads==old_downloads)
tap('Select all updates')
assert(find('Update selected (2)').enabled)
menu:onMenuSelect(find('Work ui1'),{x=0.05})
assert(find('Update selected (1)').enabled)
local row=find('Work ui2')
menu:onMenuHold(row)
assert(shown[#shown].title=='Work update details' and shown[#shown].text:find('1 new chapter',1,true))
assert(downloads==old_downloads)
tap('Update selected (1)'); drain()
assert(downloads==old_downloads+1 and saved.ui2.chapters=='3/3' and saved.ui1.chapters=='2/3')
connected=false
tap('Recheck all')
assert(pending_connection)
menu:onCloseWidget()
connected=true; reconnect=pending_connection; pending_connection=nil; reconnect()
nextJob()
local shared=require('ao3lib.updates.service').get()
assert(shared.busy and shared.done==1,'Check must continue after closing the review')
local reopened,reopened_menu=Review.show({ui={}})
assert(reopened==shared and reopened.busy,'Reopening must attach to the running check')
drain();menu=reopened_menu
assert(checks==start_checks+4, 'Closing a review must leave background checks running')
assert(find('2 of 2 checked') and find('Work ui1'))
tap('Recheck all'); drain()
assert(checks==start_checks+6 and find('Work ui1'))
print('PASS: actual review UI; explicit check/selection; preserved Wi-Fi continuation; stop/resume; hold details; selective update; close detaches checks; reopen and recheck')

-- A work action checks only that work, without a library scan or download.
local single=fixture('single-ui')
stub('ao3lib.library.discovery',{scan=function() error('Single-work review must not scan the library') end})
connected=false
local before_checks,before_downloads=checks,downloads
local single_session,single_menu=Review.showWork({ui={}},single)
assert(#single_session.entries==3 and single_menu.review_model.summary:find('0 of 1 checked',1,true))
assert(pending_connection and checks==before_checks and downloads==before_downloads)
connected=true;reconnect=pending_connection;pending_connection=nil;reconnect();drain()
assert(checks==before_checks+1 and downloads==before_downloads)
local single_entry
for _,entry in ipairs(single_session.entries) do if entry.work.id==single.id then single_entry=entry end end
assert(single_entry.status=='update' and not single_entry.selected)
single_menu:onCloseWidget()
print('PASS: single-work review auto-checks only the chosen work, preserves Wi-Fi continuation and never applies an update automatically')
