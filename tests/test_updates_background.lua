package.path='./?.lua;'..package.path
dofile('tests/test_updates.lua')
local H=dofile('tests/support/async.lua')
package.loaded.fanfic_background=nil
local B=require('fanfic_background')
local Updates=require('fanfic_updates')
local path='/books/worker.epub'
local work={id='worker',path=path,title='Worker',chapters='1/2',chapter_data={{id='first',read=true}}}
local fs=require('libs/libkoreader-lfs')
local attr=fs.attributes
fs.attributes=function(p) if p==path then return {mode='file',size=100,modification=1,change=1} end;return attr(p) end
fs.symlinkattributes=fs.attributes
local Epub=require('fanfic_epub')
local read=Epub.read
Epub.read=function(p) if p==path then return work end;return read(p) end
local Client=require('AO3_downloader_client')
Client.getWorkMetadata=function()
    local result,err=B.await(function() H.sleep(80);return {id='worker',chapters='2/2',
        chapterData={{id='first'},{id='second'}},epub_link='https://example.test/work.epub'} end)
    return result and {success=true,work_metadata=result} or {success=false,error=err}
end
local owner={item_table={}}
H.UI:show(owner)
local session=Updates.new({work})
local entry=session.entries[1]
session:run('check',{entry})
H.tick();H.tick()
assert(H.forks==1 and session.busy)
session:stop();H.drain()
assert(entry.status=='unchecked' and session.done==0)
session:run('check',{entry});H.drain()
assert(entry.status=='update' and session.done==1)
local commits=0
Client.downloadEpub=function(_,_,_,_,before_commit)
    B.await(function() H.sleep(100);return {success=true} end)
    assert(before_commit());commits=commits+1
    return {success=true,filepath=path}
end
session:run('update',{entry})
H.tick();H.tick()
session.closed=true
H.drain()
assert(commits==0 and entry.status=='update','Closing the review must discard an in-flight update before commit')
assert(#H.warnings==0)
print('PASS: Stop interrupts in-flight update checks; resume works; closing review cancels a pending download before its commit or reading-state writes')
