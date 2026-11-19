local UI = require('ui/uimanager')
local Info = require('ui/widget/infomessage')
local Confirm = require('ui/widget/confirmbox')
local Event = require('ui/event')
local Cleanup = require('ao3lib.library.cleanup')
local util = require('util')
local M = {}
local function message(text) UI:show(Info:new{text=text}) end
local function annotated(ui)
    if ui.annotation and next(ui.annotation.annotations or {}) then return true end
    for _,key in ipairs({'annotations','annotations_rolling','bookmarks','highlight'}) do
        local value=ui.doc_settings:readSetting(key)
        if type(value)=='table' and next(value) then return true end
    end
    return false
end
local function eligible(reader,ui)
    if not reader:isActiveReader(ui) then message('Open an AO3 EPUB first.');return false end
    if not ui.rolling or not ui.doc_settings then message('Formatting cleanup requires the EPUB reader.');return false end
    if G_reader_settings:readSetting('document_metadata_folder')=='hash' then
        message('Formatting cleanup is unavailable with hash-based book metadata storage. Changing EPUB contents would change its metadata location.');return false
    end
    if annotated(ui) then
        message('This book has highlights, notes or bookmarks. Formatting changes would invalidate their positions, so cleanup and revert are blocked. Keep an annotated copy before removing them.');return false
    end
    return true
end
-- Page positions change during reflow. Retain ToC section and its relative position;
-- never reuse a stale XPointer. Keep all other reader settings and statistics.
function M.capture(ui)
    local page=ui:getCurrentPage()
    local total=ui.document:getPageCount()
    local toc=ui.document:getToc() or {}
    local index=1
    for i,entry in ipairs(toc) do if entry.page and entry.page<=page then index=i end end
    local first=toc[index] and toc[index].page or 1
    local last=toc[index+1] and toc[index+1].page or total+1
    return {index=index,title=toc[index] and toc[index].title,
        fraction=math.max(0,math.min(1,(page-first)/math.max(1,last-first))),percent=(page-1)/math.max(1,total-1)}
end
function M.restore(ui,position)
    local toc=ui.document:getToc() or {}
    local entry=toc[position.index]
    local total=ui.document:getPageCount()
    local target
    if entry and entry.page and entry.title==position.title then
        local last=toc[position.index+1] and toc[position.index+1].page or total+1
        target=entry.page+math.floor(position.fraction*math.max(1,last-entry.page))
    else target=1+math.floor(position.percent*math.max(1,total-1)) end
    ui:handleEvent(Event:new('GotoPage',math.max(1,math.min(total,target))))
end
local function invalidate(path)
    require('ao3lib.library.epub').invalidate(path)
    UI:broadcastEvent(Event:new('InvalidateMetadataCache',path))
    pcall(function()
        local repo=require('lib/bookshelf_book_repository')
        repo.forgetBook(path);repo.invalidateWalkCache()
    end)
end
function M.apply(reader,ui,plan)
    if not eligible(reader,ui) then Cleanup.discard(plan);return end
    local position=M.capture(ui)
    local settings=ui.doc_settings
    local success,failure
    reader._formatting_reload_path=plan.path
    local ok,err=pcall(function()
        ui.document:invalidateCacheFile()
        ui:reloadDocument(function()
            -- onClose has now saved final reading state and closed CRe's file.
            local old=util.tableDeepCopy(settings.data)
            local committed=false
            local changed,change_err=pcall(function()
                settings:delSetting('last_xpointer')
                settings:delSetting('last_epubcfi')
                settings:delSetting('doc_pages')
                settings:saveSetting('last_percent',position.percent)
                assert(settings:flush(),'Could not save reading position; the EPUB was not changed')
                local done,commit_err=Cleanup.commit(plan)
                assert(done,commit_err)
                committed=true
                success=true
            end)
            if not changed then
                failure=tostring(change_err)
                if not committed then
                    settings.data=old
                    if not settings:flush() then failure=failure..'\nCould not restore saved reader settings.' end
                end
            end
            -- Delete only the old closed DOM cache; never retain stale paragraph anchors.
            if success then
                local cache=old.cache_file_path
                if cache then os.remove(cache) end
                local invalidated,why=pcall(invalidate,plan.path)
                if not invalidated then failure='EPUB changed, but metadata refresh failed: '..tostring(why) end
            end
        end,false,function(reopened)
            if success then M.restore(reopened,position) end
            reader._formatting_reload_path=nil
            Cleanup.discard(plan)
            if failure then message(failure)
            elseif success then message(plan.revert and 'Original EPUB formatting restored.' or 'Formatting cleaned up. An original EPUB backup is available from AO3 formatting → Revert formatting cleanup.') end
        end)
    end)
    if not ok then
        reader._formatting_reload_path=nil
        Cleanup.discard(plan)
        message('Could not complete formatting change: '..tostring(err))
    end
end
function M.clean(reader,ui)
    if M.busy or not eligible(reader,ui) then return end
    local path,id=ui.document.file,reader.current_fanfic.id
    local existing,backup_err=Cleanup.findBackup(path,id)
    if backup_err then message(backup_err);return end
    if existing then message('This EPUB has already been cleaned up. Use Revert formatting cleanup to restore its original formatting.');return end
    M.busy=true
    local cancelled=false
    local preparing=Info:new{text='Preparing AO3 formatting cleanup… Tap to cancel.',dismiss_callback=function() cancelled=true end}
    UI:show(preparing)
    local last_update=os.time()
    local function showProgress(status)
        if not status or os.time()==last_update then return end
        last_update=os.time()
        local detail=status.phase
        if status.current and status.total then detail=detail..' ('..status.current..'/'..status.total..')' end
        -- InfoMessage has no text setter. Replace it without firing cancellation.
        preparing.dismiss_callback=nil
        UI:close(preparing)
        preparing=Info:new{text='Preparing AO3 formatting cleanup…\n\n'..detail..'\n\nTap to cancel.',dismiss_callback=function() cancelled=true end}
        UI:show(preparing)
    end
    local worker=coroutine.create(function()
        return Cleanup.prepare(path,id,function(status)
            assert(not cancelled and reader:isActiveReader(ui), 'Cleanup cancelled')
            coroutine.yield(status)
            assert(not cancelled and reader:isActiveReader(ui), 'Cleanup cancelled')
        end)
    end)
    local function finish() M.busy=false;preparing.dismiss_callback=nil;UI:close(preparing) end
    local function step()
        -- Resume once after cancellation so the worker can close its archive handles.
        local ok,plan,err
        local started=os.clock()
        -- Batch cheap checkpoints into a short CPU slice instead of adding a
        -- timer delay for every group of paragraphs on fast devices.
        for _=1,32 do
            ok,plan,err=coroutine.resume(worker)
            if not ok or coroutine.status(worker)=='dead' or os.clock()-started>=0.02 then break end
        end
        if not ok then finish();if not cancelled then message(tostring(plan)) end;return end
        if coroutine.status(worker)~='dead' then showProgress(plan);UI:scheduleIn(0.01,step);return end
        finish()
        if cancelled or not reader:isActiveReader(ui) then Cleanup.discard(plan);return end
        if not plan then message('Could not prepare cleanup: '..tostring(err));return end
        if plan.changed==0 then Cleanup.discard(plan);message('No formatting cleanup is needed.');return end
        local dialog,accepted
        dialog=Confirm:new{
            text=string.format('Clean up formatting in this book?\n\nOnly the currently open EPUB will be changed (%d internal chapter/content files).\n\n%d repeated line-break runs and %d empty paragraphs will be cleaned up. Deliberate formatting and possible scene gaps are preserved.\n\nAn original EPUB backup will be kept. Reading position is restored approximately within the current section.',plan.changed,plan.breaks,plan.blanks),
            ok_text='Clean up',ok_callback=function()
                accepted=true
                UI:nextTick(function() M.apply(reader,ui,plan) end)
            end,
            cancel_callback=function() Cleanup.discard(plan) end,
        }
        -- Dismissing through Back/outside must also release the prepared file.
        local close=dialog.onCloseWidget
        dialog.onCloseWidget=function(self,...)
            if not accepted then Cleanup.discard(plan) end
            if close then return close(self,...) end
        end
        UI:show(dialog)
        -- Clear the preparation overlay over the whole screen, including e-ink.
        UI:setDirty(nil,'ui')
    end
    UI:nextTick(step)
end
function M.revert(reader,ui)
    if M.busy or not eligible(reader,ui) then return end
    local plan,err=Cleanup.findBackup(ui.document.file,reader.current_fanfic.id)
    if not plan then message(err or 'No matching original EPUB backup was found. Revert is unavailable if the book has been updated or edited since cleanup.');return end
    UI:show(Confirm:new{
        text='Restore this book’s original formatting?\n\nCurrent reading settings and statistics are kept. Reading position is restored approximately within the current section.',
        ok_text='Revert',ok_callback=function() UI:nextTick(function() M.apply(reader,ui,plan) end) end,
    })
end
return M
