-- Reuse the update test's KOReader UI stubs, then exercise native-only mode.
dofile('tests/test_updates.lua')
local Updates=require('ao3lib.updates.checks')
local Epub=require('ao3lib.library.epub')
local History=require('ao3lib.library.history')
local Client=require('ao3lib.ao3.client')
local fs=require('libs/libkoreader-lfs')
local UI=require('ui/uimanager')
local function copy(t)
    if type(t)~='table' then return t end
    local out={};for k,v in pairs(t) do out[k]=copy(v) end;return out
end
local path='/books/converted.epub'
local local_work={id='native-test',path=path,title='Same work',author='Writer',chapters='2/2',wordcount='1000',
    updated='2026-01-01',_ao3_html_conversion=true}
local stored=copy(local_work)
stored.chapter_data={{id='a',read=true},{id='b',read=false}}
local remote=copy(local_work)
remote._ao3_html_conversion=nil
remote.epub_link='https://example.test/native.epub';remote.html_link='https://example.test/work.html'
remote.chapterData={{id='a'},{id='b'}}
local stat={mode='file',size=100,modification=1,change=1}
local getstat=fs.attributes
fs.attributes=function(p) if p==path then return copy(stat) end;return getstat(p) end
fs.symlinkattributes=fs.attributes
local read=Epub.read
Epub.read=function(p) if p==path then return copy(local_work) end;return read(p) end
History.get=function() return copy(stored) end
History.update=function(work) stored=copy(work);return true end
Client.getWorkMetadata=function() return {success=true,work_metadata=copy(remote)} end
local downloaded,fail=0,false
Client.downloadEpub=function(_,source,dest,replace,before_commit)
    assert(type(source)=='string' and source==remote.epub_link,'Native replacements must bypass HTML fallback')
    assert(dest==path and replace)
    downloaded=downloaded+1
    if fail then return {success=false,error='Native download unavailable'} end
    assert(before_commit())
    local_work=copy(remote);local_work.path=path
    stat.size=stat.size+1;stat.modification=stat.modification+1
    return {success=true,filepath=path}
end
assert(Updates.check(local_work).status=='current')
local entry=Updates.check(local_work,true)
assert(entry.status=='update' and entry.native_only)
fail=true
assert(not Updates.apply(entry).success and local_work._ao3_html_conversion)
fail=false
local result=Updates.apply(entry)
assert(result.success and not local_work._ao3_html_conversion and result.work.path==path)
assert(stored.chapter_data[1].read and not stored.chapter_data[2].read)
local before=downloaded
local native=Updates.check(local_work,true)
assert(native.status=='current' and not native.remote)
assert(not Updates.apply(entry).success and downloaded==before,'Already native books must not be replaced again')
local_work._ao3_html_conversion=true
remote.epub_link=nil
assert(Updates.check(local_work,true).status=='unavailable','HTML availability must not count as native availability')
remote.epub_link='https://example.test/native.epub'
-- Session checks must retain native-only mode, rather than treating unchanged
-- converted works as current after an asynchronous check.
local session=Updates.new({local_work});session.native_only=true
local scheduled={}
assert(session:run('check',session.entries,nil,function(_,fn) scheduled[#scheduled+1]=fn end))
while #scheduled>0 do table.remove(scheduled,1)() end
assert(session.entries[1].status=='update' and session.entries[1].native_only)
-- Maintenance UI scans without changing history and excludes native books.
local scan,shown
UI.show=function(_,widget) shown=widget end
UI.close=function() end
package.loaded['ao3lib.library.discovery']={scan=function(_,done,invalid,options)
    assert(options.read_only)
    scan={done=done,invalid=invalid,cancel=function() scan.cancelled=true end}
    return scan
end}
local Review=require('ao3lib.ui.update_review')
local dialog=Review.showNative({ui={}})
dialog.dismiss_callback()
assert(scan.cancelled and scan.invalid())
Review.showNative({ui={}})
scan.done({converted=local_work,native={id='other',path='/books/native.epub',title='Native'}},nil)
assert(shown.title=='Replace converted EPUBs')
assert(shown.review_model.summary:find('0 of 1 checked',1,true))
local found=false
for _,row in ipairs(shown.review_model.buttons[1]) do
    if row.text=='Check native availability' then found=true end
end
assert(found)
shown:onCloseWidget()
print('PASS: unchanged conversions eligible; native-only download; failures preserve books; chapter flags preserved; native books excluded; cancelable read-only scan')
