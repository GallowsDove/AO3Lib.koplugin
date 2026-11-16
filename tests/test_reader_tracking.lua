-- Run from the plugin directory: luajit tests/test_reader_tracking.lua
package.path='./?.lua;'..package.path
local function stub(name,value) package.loaded[name]=value end
local function copy(t)
    if type(t)~='table' then return t end
    local out={}; for k,v in pairs(t) do out[k]=copy(v) end; return out
end
local Class={new=function(self,t) return setmetatable(t or {},{__index=self}) end}
for _,name in ipairs({'container/widgetcontainer','notification','infomessage','inputdialog','buttondialog','multiinputdialog'}) do
    stub('ui/widget/'..name,Class)
end
stub('fanfic_network',{wrap=function(fn) return fn end})
stub('fanfic_bookmark_dialog',{})
stub('AO3_downloader_client',setmetatable({}, {__index=function() error('Reading must stay offline') end}))
stub('ffi/util',{template=function(s) return s end})
local warnings=0
stub('logger',{dbg=function() end,warn=function() warnings=warnings+1 end})
local jobs,events={},{}
stub('ui/uimanager',{
    show=function() end,
    nextTick=function(_,callback) jobs[#jobs+1]=callback end,
    broadcastEvent=function(_,event) events[#events+1]=event end,
})
stub('ui/event',{new=function(_,name,value) return {name=name,value=value} end})
local epubs={
    ['/books/one.epub']={id='1',path='/books/one.epub',title='One'},
    ['/books/two.epub']={id='2',path='/books/two.epub',title='Two'},
    ['/books/import.epub']={id='3',path='/books/import.epub',title='Imported'},
}
local identified={}
stub('fanfic_epub',{read=function(path)
    identified[#identified+1]=path
    if path=='/books/corrupt.epub' then error('Corrupt archive') end
    return copy(epubs[path])
end})
local saved={
    ['1']={id='1',path='/old/location.epub',chapter_data={{id='11',name='First'},{id='12',name='Last'}}},
    ['2']={id='2',path='/books/two.epub',chapter_data={{id='21',name='Only'}}},
    ['stale']={id='stale',path='/books/ordinary.epub',chapter_data={{id='bogus'}}},
}
local chapter_writes,whole_writes=0,0
stub('downloaded_fanfics',{
    rememberLocal=function(work)
        local current=copy(saved[work.id] or work)
        current.id,current.path,current.title=work.id,work.path,work.title
        current.chapter_data=current.chapter_data or {}
        saved[work.id]=copy(current)
        return current
    end,
    markChapterAsRead=function(id,index)
        local work=saved[id]
        if not work or not work.chapter_data[index] then return nil end
        work.chapter_data[index].read=true
        chapter_writes=chapter_writes+1
        return copy(work)
    end,
    markWorkAsRead=function(id)
        if not saved[id] then return nil end
        saved[id].read=true; whole_writes=whole_writes+1; return copy(saved[id])
    end,
})
local ReaderUI={}
stub('apps/reader/readerui',ReaderUI)
local Reader=require('fanfic_reader')
local function ui(path)
    local instance={name='ReaderUI',post={},registrations=0,[1]={},
        document={file=path,getPageCount=function() return 100 end,
            getToc=function() return {{page=1},{page=10},{page=50}} end},
        toc={getTocIndexByPage=function(_,page) return page<50 and 2 or 3 end,
            isChapterEnd=function(_,page) return page==49 end},
    }
    instance.menu={registerToMainMenu=function() instance.registrations=instance.registrations+1 end}
    function instance:registerPostInitCallback(fn) self.post[#self.post+1]=fn end
    function instance:finishInit() for _,fn in ipairs(self.post) do fn() end; self.post={} end
    function instance:getCurrentPage() return self.restored_page end
    return instance
end
local function open(path)
    local instance=ui(path); ReaderUI.instance=instance
    Reader:initializeFromReaderUI(instance); instance:finishInit()
    return instance
end
local ordinary=open('/books/ordinary.epub')
assert(not Reader.is_showing and ordinary.registrations==0 and not ordinary._ao3_reader_listener)
assert(not saved.stale.chapter_data[1].read, 'A stale download-history path cannot activate AO3 tracking')
local corrupt=open('/books/corrupt.epub')
assert(not Reader.is_showing and corrupt.registrations==0 and warnings==1)
local first=open('/books/one.epub')
assert(Reader.is_showing and Reader.current_fanfic.id=='1' and first.registrations==1)
assert(saved['1'].path=='/books/one.epub', 'Renamed AO3 EPUBs retain their saved chapter flags')
Reader:initializeFromReaderUI(first); first:finishInit()
assert(first.registrations==1 and #first==2, 'Duplicate initialization must not duplicate hooks or menus')
first._ao3_reader_listener:onPosUpdate(200,49)
assert(chapter_writes==1 and saved['1'].chapter_data[1].read and not saved['1'].chapter_data[2].read)
first._ao3_reader_listener:onPageUpdate(49)
assert(chapter_writes==1)
-- Parking under Bookshelf is not a real close: the same listener resumes.
assert(Reader:isActiveReader(first))
first._ao3_reader_listener:onPageUpdate(100)
assert(chapter_writes==2 and saved['1'].chapter_data[2].read)
first._ao3_reader_listener:onPageUpdate(100)
assert(chapter_writes==2)
Reader:onFinishChapter(999)
assert(chapter_writes==2)
local second=open('/books/two.epub')
first._ao3_reader_listener:onCloseWidget()
first._ao3_reader_listener:onPageUpdate(49)
assert(Reader:isActiveReader(second) and Reader.current_fanfic.id=='2' and chapter_writes==2)
second._ao3_reader_listener:onPageUpdate(100)
assert(chapter_writes==3 and saved['2'].chapter_data[1].read)
ordinary=open('/books/ordinary.epub')
second._ao3_reader_listener:onPageUpdate(100)
second._ao3_reader_listener:onCloseWidget()
assert(not Reader.is_showing and Reader.current_fanfic==nil and chapter_writes==3)
local imported=open('/books/import.epub')
imported._ao3_reader_listener:onPageUpdate(49)
assert(whole_writes==0)
imported._ao3_reader_listener:onPageUpdate(100)
imported._ao3_reader_listener:onPageUpdate(100)
assert(whole_writes==1 and saved['3'].read)
imported._ao3_reader_listener:onCloseWidget()
assert(not Reader.is_showing and Reader._reader_ui==nil and Reader.current_fanfic==nil)
saved['3'].read=false
local resume=open('/books/import.epub')
resume.restored_page=100
resume._ao3_reader_listener:onReaderReady()
assert(whole_writes==2 and saved['3'].read)
print('PASS: offline direct-open activation; EPUB-only identity; renamed works; chapter and final-page tracking; duplicate hooks; parking; switching; stale close/page events; ordinary/corrupt books; imported completion')

-- Plugin launches still support Open at chapter, including synchronous
-- ReaderReady during showReader and switchDocument.
local function launch(path)
    local instance=open(path)
    instance._ao3_reader_listener:onReaderReady()
    return instance
end
ReaderUI.instance=nil
ReaderUI.showReader=function(_,path) launch(path) end
Reader:show{fanfic_path='/books/one.epub',current_fanfic={id='forged'},chapter_opening_at=2}
assert(Reader.current_fanfic.id=='1' and Reader:isActiveReader(ReaderUI.instance))
assert(#jobs==1 and Reader.chapter_opening_at==nil)
table.remove(jobs,1)()
assert(events[#events].name=='GotoPage' and events[#events].value==50)
local old=ReaderUI.instance
old.switchDocument=function(_,path)
    old._ao3_reader_listener:onCloseWidget()
    launch(path)
end
Reader:show{fanfic_path='/books/two.epub',chapter_opening_at=1}
assert(Reader.current_fanfic.id=='2' and #jobs==1)
old._ao3_reader_listener:onCloseWidget()
table.remove(jobs,1)()
assert(Reader:isActiveReader(ReaderUI.instance) and events[#events].value==10)
local current=ReaderUI.instance
Reader.chapter_opening_at=1
current._ao3_reader_listener:onReaderReady()
local before=#events
open('/books/ordinary.epub')
table.remove(jobs,1)()
assert(#events==before, 'Delayed chapter jumps must not affect a different book')
local restored=open('/books/one.epub')
Reader.chapter_opening_at=999
restored._ao3_reader_listener:onReaderReady()
table.remove(jobs,1)()
assert(#events==before)
restored.switchDocument=function() return nil end -- Failed open leaves no pending jump.
Reader:show{fanfic_path='/books/missing.epub',chapter_opening_at=2}
assert(Reader._pending_open==nil)
local ghost=open('/books/one.epub')
saved['1']=nil
Reader.current_fanfic.chapter_data[1].read=false
ghost._ao3_reader_listener:onPageUpdate(49)
assert(Reader.current_fanfic~=nil, 'Removed history cannot erase active reader state or crash the reader')
print('PASS: synchronous plugin launch; verified identity instead of supplied metadata; chapter navigation; delayed/stale callbacks; invalid jumps; failed opens; removed history')

-- Reflow/reload must not turn temporary restoration pages into AO3 chapter flags.
local formatting=open('/books/one.epub')
local chapter_before,whole_before=chapter_writes,whole_writes
Reader._formatting_reload_path='/books/one.epub'
formatting._ao3_reader_listener:onPageUpdate(49)
formatting._ao3_reader_listener:onPageUpdate(100)
formatting.restored_page=100
formatting._ao3_reader_listener:onReaderReady()
assert(chapter_writes==chapter_before and whole_writes==whole_before)
Reader._formatting_reload_path=nil
local menu={}
Reader:addToMainMenu(menu)
assert(menu.AO3_formatting.sub_item_table[1].text=='Clean up formatting')
assert(menu.AO3_formatting.sub_item_table[2].text=='Revert formatting cleanup')
print('PASS: manual reader formatting menu; reload position updates cannot mark chapters read')

local flushes=0
package.loaded.downloaded_fanfics.flushPending=function() flushes=flushes+1;return true end
local closing=open('/books/one.epub')
closing._ao3_reader_listener:onCloseWidget()
assert(flushes==1,'Closing the active reader must checkpoint pending chapter progress')
closing._ao3_reader_listener:onCloseWidget()
assert(flushes==1,'A stale reader must not checkpoint the replacement reader')
print('PASS: active-reader close checkpoints pending progress; stale close events stay isolated')

-- PageUpdate and PosUpdate may describe the same page. Do chapter work once;
-- ToC/layout resets must allow that same page to be evaluated again.
local tracked=open('/books/two.epub')
Reader.current_fanfic.chapter_data[1].read=false
local lookups,ends=0,0
tracked.toc.getTocIndexByPage=function() lookups=lookups+1;return 2 end
tracked.toc.isChapterEnd=function() ends=ends+1;return false end
tracked._ao3_reader_listener:onPageUpdate(25)
tracked._ao3_reader_listener:onPosUpdate(1000,25)
assert(lookups==1 and ends==1)
tracked._ao3_reader_listener:onTocReset()
tracked._ao3_reader_listener:onPageUpdate(25)
assert(lookups==2 and ends==2)
tracked._ao3_reader_listener:onDocumentRerendered()
tracked._ao3_reader_listener:onPageUpdate(25)
assert(lookups==3 and ends==3)
Reader.current_fanfic.chapter_data[1].read=true
tracked._ao3_reader_listener:onPageUpdate(26)
assert(lookups==4 and ends==3,'Already-read chapters do not need another boundary scan')
tracked.document.getPageCount=function() return 110 end
tracked._ao3_reader_listener:onPageUpdate(26)
assert(lookups==5,'Changed page counts invalidate a same-page check')
print('PASS: duplicate page/position events; ToC/reflow invalidation; read-chapter fast path')
