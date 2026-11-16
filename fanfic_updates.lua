local Client = require("AO3_downloader_client")
local Epub = require("fanfic_epub")
local History = require("downloaded_fanfics")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")
local M = {}

local function number(value) return tonumber((tostring(value or ""):gsub(",", ""))) end
local function count(work) return tonumber((work.chapters or ""):match("^(%d+)%s*/")) end
local function fingerprint(path)
    local stat = (lfs.symlinkattributes or lfs.attributes)(path)
    if not stat or stat.mode ~= "file" then return nil end
    return {size=stat.size, mtime=stat.modification, change=stat.change}
end
local function same(a,b)
    return a and b and a.size==b.size and a.mtime==b.mtime and a.change==b.change
end
local function failure(message, result)
    return {success=false, error=tostring(message or _("Update failed.")),
        status=result and result.status, retry_later=result and result.retry_later,
        unexpected_response=result and result.unexpected_response,
        response_headers=result and result.response_headers}
end

function M.check(work)
    local entry = {work=work, status="error", selected=false}
    local local_work = Epub.read(work.path)
    entry.fingerprint = fingerprint(work.path)
    if not local_work or tostring(local_work.id) ~= tostring(work.id) or not entry.fingerprint then
        entry.error=_("The local AO3 EPUB is missing or has changed."); return entry
    end
    entry.local_work = local_work
    local response = Client:getWorkMetadata(work.id)
    if not response.success then
        entry.status = (response.status==404 or response.status==403) and "unavailable" or "error"
        entry.error, entry.failure = response.error, response
        return entry
    end
    local remote = response.work_metadata
    if not remote or tostring(remote.id) ~= tostring(work.id) or not remote.epub_link then
        entry.error=_("AO3 returned incomplete work metadata."); return entry
    end
    entry.remote, entry.changes = remote, {}
    local old, new = count(local_work), count(remote)
    if old and new and new > old then
        entry.changes[#entry.changes+1] = string.format(_("%d new chapter(s)"), new-old)
    elseif old and new and new < old then
        entry.status="review"
        entry.changes[#entry.changes+1] = _("AO3 reports fewer chapters than the local EPUB. Review before replacing it.")
    end
    local old_words, new_words = number(local_work.wordcount), number(remote.wordcount)
    if old_words and new_words and old_words ~= new_words then
        entry.changes[#entry.changes+1] = string.format(_("Words: %s → %s"), local_work.wordcount, remote.wordcount)
    end
    local old_date = local_work.updated or local_work.published
    local new_date = remote.updated or remote.published
    if old_date and new_date and new_date > old_date then
        entry.changes[#entry.changes+1] = string.format(_("Updated: %s → %s"), old_date, new_date)
    elseif old_date and new_date and new_date < old_date then
        entry.status="review"
        entry.changes[#entry.changes+1] = _("AO3 reports an older update date than the local EPUB. Review before replacing it.")
    end
    if local_work.chapters ~= remote.chapters and old and new and old==new then
        entry.changes[#entry.changes+1] = string.format(_("Chapters: %s → %s"), local_work.chapters, remote.chapters)
    end
    if entry.status ~= "review" then
        if #entry.changes > 0 then entry.status="update"
        elseif old and new and old==new then entry.status="current"
        else
            entry.status="review"
            entry.changes[1]=_("Local metadata is insufficient to determine whether this work changed.")
        end
    end
    return entry
end

local function isOpen(path)
    local ok, Reader = pcall(require,"apps/reader/readerui")
    local instance = ok and Reader.instance
    if instance and instance.document and instance.document.file==path then return true end
    local parked, Park = pcall(require,"lib/bookshelf_reader_park")
    return parked and Park.parkedFile and Park.parkedFile()==path
end
local function sourceUnchanged(entry)
    if isOpen(entry.work.path) then return nil, _("Close this book before updating it.") end
    if not same(entry.fingerprint, fingerprint(entry.work.path)) then
        return nil, _("The EPUB changed since it was checked. Check this work again before updating.")
    end
    local work = Epub.read(entry.work.path)
    if not work or tostring(work.id)~=tostring(entry.work.id) then return nil, _("The local AO3 work no longer matches.") end
    return true
end

function M.apply(entry)
    if not entry.remote or not entry.local_work then return failure(_("Check this work before updating it.")) end
    local unchanged, err = sourceUnchanged(entry)
    if not unchanged then return failure(err) end
    local remote, old = entry.remote, History.get(entry.work.id) or util.tableDeepCopy(entry.work)
    local n = count(remote)
    local chapters = util.tableDeepCopy(remote.chapterData or {})
    if n and n > 1 and #chapters ~= n then return failure(_("AO3 chapter information is incomplete. Check this work again.")) end
    local by_id = {}
    for __, chapter in ipairs(old.chapter_data or {}) do
        if chapter.id then by_id[tostring(chapter.id)] = chapter end
    end
    for index, chapter in ipairs(chapters) do
        local previous = chapter.id and by_id[tostring(chapter.id)]
        local legacy = (old.chapter_data or {})[index]
        if not previous and not chapter.id and legacy and not legacy.id and legacy.name==chapter.name then previous=legacy end
        chapter.read = previous and previous.read or false
        if old.read and #(old.chapter_data or {})==0 and n and n==count(entry.local_work) then chapter.read=true end
    end
    -- Keep the work at the same path: KOReader sidecars, annotations and
    -- bookmarks stay attached. The client stages the EPUB and commits atomically.
    local response = Client:downloadEpub(remote.epub_link, entry.work.path, true,
        function() return sourceUnchanged(entry) end)
    if not response.success then return failure(response.error, response) end
    local updated = util.tableDeepCopy(old)
    for __, key in ipairs({"title","author","chapters","summary","fandoms","tags","relationships","characters",
            "warnings","hits","kudos","bookmarks","comments","rating","category","iswip","updated","published","wordcount",
            "markedForLater","subscriptionID","bookmarkID","bookmarkContent"}) do
        if remote[key]~=nil then updated[key]=util.tableDeepCopy(remote[key]) end
    end
    updated.id, updated.path = tostring(entry.work.id), entry.work.path
    updated.chapter_data = chapters
    if #chapters==0 and n==1 and #(old.chapter_data or {})==1 then updated.chapter_data=old.chapter_data end
    if #updated.chapter_data > 0 or (n and count(entry.local_work) and n>count(entry.local_work)) then updated.read=nil end
    local saved, save_err = History.update(updated)
    -- Let the library discover the changed file without changing any
    -- Bookshelf source or touching the document's reading-state sidecar.
    pcall(function()
        local UI = require("ui/uimanager")
        UI:broadcastEvent(require("ui/event"):new("InvalidateMetadataCache", updated.path))
        local Repo = require("lib/bookshelf_book_repository")
        Repo.forgetBook(updated.path)
        Repo.invalidateWalkCache()
    end)
    if not saved then
        local result=failure(_("The EPUB was updated, but its AO3 reading state could not be saved: ") .. tostring(save_err))
        result.downloaded=true
        result.work=updated
        return result
    end
    return {success=true, work=updated}
end

function M.retrySave(session)
    local saved, err=History.save()
    if not saved then return nil,err end
    for __, entry in ipairs(session.entries) do
        if entry.status=="state_error" then
            entry.work=History.get(entry.work.id) or entry.work
            entry.status="updated"; entry.error=nil; entry.failure=nil; entry.selected=false
            entry.fingerprint=fingerprint(entry.work.path)
        end
    end
    return true
end

local Session = {}
Session.__index=Session

function M.new(works, previous)
    local session=setmetatable({entries={}, generation=0, busy=false, closed=false},Session)
    if previous and previous.retry_at and previous.retry_at>os.time() then
        session.retry_at,session.pause_reason=previous.retry_at,previous.pause_reason
    end
    local prior={}
    for __, entry in ipairs(previous and previous.entries or {}) do prior[tostring(entry.work.id)]=entry end
    for __, work in pairs(works) do
        local old=prior[tostring(work.id)]
        if old and old.work.path==work.path and same(old.fingerprint,fingerprint(work.path)) then
            old.work=work; session.entries[#session.entries+1]=old
        else session.entries[#session.entries+1]={work=work,status="unchecked",selected=false} end
    end
    table.sort(session.entries,function(a,b)
        if (a.work.title or "")~=(b.work.title or "") then return (a.work.title or "")<(b.work.title or "") end
        return tostring(a.work.id)<tostring(b.work.id)
    end)
    return session
end

function Session:stop()
    self.generation=self.generation+1
    self.busy=false
end

-- Requests run one at a time; scheduled gaps keep cancellation and the
-- review menu usable. Stopping invalidates every queued continuation.
function Session:run(operation, targets, changed, schedule)
    if self.busy or self.closed then return false end
    if self.retry_at and os.time()<self.retry_at then return nil, self.pause_reason end
    schedule=schedule or function(delay, callback) require("ui/uimanager"):scheduleIn(delay,callback) end
    self.generation=self.generation+1
    local generation, index=self.generation,0
    self.busy, self.operation, self.done, self.total=true,operation,0,#targets
    self.pause_reason, self.retry_at=nil,nil
    local unexpected=0
    local function notify() if changed then changed(self) end end
    local step
    local function stepBody()
        if self.closed or self.generation~=generation then return end
        index=index+1
        local entry=targets[index]
        if not entry then self.busy=false; notify(); return end
        local ok, result=pcall(operation=="check" and M.check or M.apply, operation=="check" and entry.work or entry)
        if self.closed or self.generation~=generation then return end
        if not ok and require("fanfic_background").isCancelled(result) then
            self:stop();notify();return
        end
        if not ok then result=failure(result) end
        if operation=="check" and ok then
            for key in pairs(entry) do entry[key]=nil end
            for key,value in pairs(result) do entry[key]=value end
        elseif operation=="update" and ok and result.success then
            entry.work=result.work; entry.status="updated"; entry.selected=false; entry.error=nil; entry.failure=nil
            entry.fingerprint=fingerprint(result.work.path)
        else
            entry.error=result.error
            entry.failure=result
            entry.status=result.downloaded and "state_error" or "error"
            if result.downloaded then
                entry.work=result.work or entry.work
                entry.selected=false
                entry.fingerprint=fingerprint(entry.work.path)
            end
        end
        self.done=index
        local failed=entry.failure
        unexpected = failed and failed.unexpected_response and (unexpected+1) or 0
        if failed and (failed.retry_later or unexpected>=3) then
            self.busy=false
            self.pause_reason=failed.error
            local headers=failed.response_headers or {}
            local delay=tonumber(headers["retry-after"] or headers["Retry-After"])
            self.retry_at=os.time()+math.max(0,delay or (failed.status==429 and 60 or 30))
            notify(); return
        end
        if index==#targets then self.busy=false; notify(); return end
        notify()
        schedule(3+math.random()*2,step)
    end
    step=function()
        require("fanfic_background").wrap(stepBody,{
            valid=function() return not self.closed and self.generation==generation end,
            on_cancel=function()
                if self.generation==generation then self:stop();notify() end
            end,
        })
    end
    notify()
    schedule(0.1,step)
    return true
end

return M
