-- Run from the plugin directory: luajit tests/test_cleanup_reader.lua
package.path='./?.lua;'..package.path
local function stub(n,v) package.loaded[n]=v end
local function copy(t) if type(t)~='table' then return t end;local o={};for k,v in pairs(t) do o[k]=copy(v) end;return o end
local messages,jobs,events={}, {},{}
local function class() return {new=function(_,t) return t end} end
stub('ui/widget/infomessage',class());stub('ui/widget/confirmbox',class())
stub('ui/event',{new=function(_,name,value) return {name=name,value=value} end})
stub('ui/uimanager',{
    show=function(_,w) messages[#messages+1]=w end,close=function(_,w) if w.onCloseWidget then w:onCloseWidget() end end,
    nextTick=function(_,fn) jobs[#jobs+1]=fn end,scheduleIn=function(_,_,fn) jobs[#jobs+1]=fn end,
    broadcastEvent=function(_,e) events[#events+1]=e end,
    setDirty=function() end,
})
stub('util',{tableDeepCopy=copy})
local invalidations=0
stub('fanfic_epub',{invalidate=function() invalidations=invalidations+1 end})
stub('lib/bookshelf_book_repository',{forgetBook=function() end,invalidateWalkCache=function() end})
G_reader_settings={readSetting=function() return nil end}
local commit_ok=true
local commits,discards,closed=0,0,false
local prepared
stub('fanfic_cleanup',{
    commit=function() assert(closed,'Never replace an open EPUB');commits=commits+1;return commit_ok, 'simulated replacement failure' end,
    discard=function() discards=discards+1 end,
    findBackup=function() return nil end,
    prepare=function(path,id,yield_fn) yield_fn();return prepared end,
})
local M=require('fanfic_cleanup_reader')
local reader={isActiveReader=function(self,ui) return self.ui==ui end}
local function fresh()
    closed=false
    local settings={data={last_xpointer='original-anchor',last_epubcfi='old-cfi',custom_font='font',partial_md5_checksum='statistics-identity',summary={status='reading'}}}
    function settings:readSetting(k) return self.data[k] end
    function settings:saveSetting(k,v) self.data[k]=v end
    function settings:delSetting(k) self.data[k]=nil end
    function settings:flush() return true end
    local oldtoc={{page=1,title='Preface'},{page=20,title='First'},{page=60,title='Second'}}
    local ui={rolling={},annotation={annotations={}},doc_settings=settings}
    ui.document={file='/book.epub',getToc=function() return oldtoc end,getPageCount=function() return 100 end,invalidateCacheFile=function() end}
    function ui:getCurrentPage() return 35 end
    function ui:handleEvent(e) events[#events+1]=e end
    function ui:reloadDocument(after_close,_,after_open)
        self.doc_settings.data.last_xpointer='final-saved-anchor'
        closed=true;after_close()
        if commit_ok then assert(not self.doc_settings.data.last_xpointer) end
        self.document.getToc=function() return {{page=1,title='Preface'},{page=12,title='First'},{page=32,title='Second'}} end
        self.document.getPageCount=function() return 60 end
        after_open(self)
    end
    reader.ui=ui;reader.current_fanfic={id='123'}
    return ui
end
local ui=fresh()
local pos=M.capture(ui);assert(pos.index==2 and pos.fraction==0.375)
M.apply(reader,ui,{path='/book.epub'})
assert(commits==1 and invalidations==1 and not reader._formatting_reload_path)
assert(ui.doc_settings.data.custom_font=='font' and ui.doc_settings.data.partial_md5_checksum=='statistics-identity')
assert(ui.doc_settings.data.summary.status=='reading' and ui.doc_settings.data.last_epubcfi==nil)
assert(events[#events].name=='GotoPage' and events[#events].value==19)
-- Failed replacement restores the final state saved by reader shutdown.
ui=fresh();commit_ok=false
M.apply(reader,ui,{path='/book.epub'})
assert(ui.doc_settings.data.last_xpointer=='final-saved-anchor')
assert(messages[#messages].text:find('simulated replacement failure',1,true))
assert(not reader._formatting_reload_path)
commit_ok=true
-- Protect both live and legacy annotations on cleanup and revert.
for _,key in ipairs({'annotations','annotations_rolling','bookmarks','highlight'}) do
    ui=fresh();ui.doc_settings.data[key]={{page='anchor'}}
    local before=commits;M.apply(reader,ui,{path='/book.epub'});assert(commits==before)
end
ui=fresh();ui.annotation.annotations={{page='anchor'}}
local before=commits;M.revert(reader,ui);assert(commits==before)
-- Prepare is asynchronous and cancellation cannot reach confirmation or commit.
ui=fresh();prepared={path='/book.epub',changed=1,breaks=2,blanks=3}
local function drain() while #jobs>0 do table.remove(jobs,1)() end end
M.clean(reader,ui)
local progress=messages[#messages];progress.dismiss_callback();drain()
assert(commits==before and not M.busy)
-- The confirmation offers a concrete review and keeps staging on acceptance.
M.clean(reader,ui);drain()
local confirmation=messages[#messages]
assert(confirmation.ok_text=='Clean up')
assert(confirmation.text:find('Only the currently open EPUB will be changed',1,true))
assert(not confirmation.text:find('document(s)',1,true))
assert(confirmation.text:find('2 repeated line-break runs and 3 empty paragraphs',1,true))
local discarded=discards
confirmation.ok_callback();confirmation:onCloseWidget()
assert(discards==discarded,'Closing an accepted confirmation must retain the staging file')
drain();assert(commits==before+1)
-- Dismissing the confirmation releases staging without applying it.
ui=fresh();M.clean(reader,ui);drain()
confirmation=messages[#messages];discarded=discards;confirmation:onCloseWidget()
assert(discards==discarded+1)
print('AO3 reader cleanup lifecycle tests passed')

-- Progress replaces the overlay without cancelling the worker. Dismissal does
-- cancel it, and a completed worker explicitly invalidates the screen.
ui=fresh()
local cleanup=package.loaded['fanfic_cleanup']
local real_prepare=cleanup.prepare
local real_clock,real_time=os.clock,os.time
local clock=0
os.clock=function() clock=clock+0.03;return clock end
os.time=function() return math.floor(clock*100) end
cleanup.prepare=function(path,id,yield_fn)
    local ok=pcall(function()
        for i=1,4 do yield_fn{phase='Checking paragraphs',current=i,total=4} end
    end)
    return ok and prepared or nil, 'cancelled'
end
local UI=package.loaded['ui/uimanager']
local old_close=UI.close
UI.close=function(_,widget)
    if widget.dismiss_callback then widget.dismiss_callback() end
    if widget.onCloseWidget then widget:onCloseWidget() end
end
M.clean(reader,ui)
local initial=messages[#messages]
table.remove(jobs,1)()
assert(M.busy)
local updated=messages[#messages]
assert(updated~=initial and initial.dismiss_callback==nil)
assert(updated.text:find('Checking paragraphs (1/4)',1,true))
updated.dismiss_callback()
drain();assert(not M.busy)
local paints=0
UI.setDirty=function(_,_,mode) assert(mode=='ui');paints=paints+1 end
M.clean(reader,ui);drain()
assert(messages[#messages].ok_text=='Clean up' and paints==1)
messages[#messages]:onCloseWidget()
os.clock,os.time=real_clock,real_time
cleanup.prepare=real_prepare;UI.close=old_close
print('PASS: live progress, overlay replacement, cancellation and confirmation repaint')
