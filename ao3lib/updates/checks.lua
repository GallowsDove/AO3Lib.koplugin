local Client = require("ao3lib.ao3.client")
local Epub = require("ao3lib.library.epub")
local History = require("ao3lib.library.history")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")
local Format = require("ao3lib.core.format")
local M = {}

local function number(value) return tonumber((tostring(value or ""):gsub(",", ""))) end
-- Display placeholders are not dates and must never participate in ordering.
local function date(value)
    if type(value)~="string" then return end
    local year,month,day=value:match("^%s*(%d%d%d%d)%-(%d%d)%-(%d%d)%s*$")
    year,month,day=tonumber(year),tonumber(month),tonumber(day)
    if not year or year<1 or month<1 or month>12 then return end
    local days={31,28,31,30,31,30,31,31,30,31,30,31}
    if year%4==0 and (year%100~=0 or year%400==0) then days[2]=29 end
    if day<1 or day>days[month] then return end
    return string.format("%04d-%02d-%02d",year,month,day)
end
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

function M.check(work, native_only)
    local entry = {work=work, status="error", selected=false}
    local local_work = Epub.read(work.path)
    entry.fingerprint = fingerprint(work.path)
    if not local_work or tostring(local_work.id) ~= tostring(work.id) or not entry.fingerprint then
        entry.error=_("The local AO3 EPUB is missing or has changed."); return entry
    end
    entry.local_work = local_work
    if native_only then
        entry.native_only=true
        if not local_work._ao3_html_conversion then
            entry.status="current"; entry.changes={}; return entry
        end
    end
    local response = Client:getWorkMetadata(work.id)
    if not response.success then
        entry.status = (response.status==404 or response.status==403) and "unavailable" or "error"
        entry.error, entry.failure = response.error, response
        return entry
    end
    local remote = response.work_metadata
    if native_only and remote and tostring(remote.id)==tostring(work.id) and not remote.epub_link then
        entry.status="unavailable"; entry.error=_("Native EPUB download is not available yet."); return entry
    end
    if not remote or tostring(remote.id) ~= tostring(work.id) or not (remote.epub_link or (require("ao3lib.core.config"):readSetting("html_download_fallback", false) and remote.html_link)) then
        entry.error=_("AO3 returned incomplete work metadata."); return entry
    end
    entry.remote, entry.changes = remote, {}
    local old, new = count(local_work), count(remote)
    if old and new and new > old then
        entry.changes[#entry.changes+1] = Format.newChapters(new-old)..string.format(" · %d → %d",old,new)
    elseif old and new and new < old then
        entry.status="review"
        entry.changes[#entry.changes+1] = _("AO3 reports fewer chapters than the local EPUB. Review before replacing it.")
    end
    local old_words, new_words = number(local_work.wordcount), number(remote.wordcount)
    if old_words and new_words and old_words ~= new_words then
        entry.changes[#entry.changes+1] = string.format(_("Words: %s → %s"), Format.integer(local_work.wordcount), Format.integer(remote.wordcount))
    end
    local old_date = date(local_work.updated) or date(local_work.published)
    local new_date = date(remote.updated) or date(remote.published)
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
    if native_only then
        entry.changes[#entry.changes+1]=_("Replace the HTML conversion with AO3’s native EPUB.")
        if entry.status=="current" then entry.status="update" end
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
    if isOpen(entry.work.path) then return nil, _("Close this work before updating it.") end
    if not same(entry.fingerprint, fingerprint(entry.work.path)) then
        return nil, _("The EPUB changed since it was checked. Check this work again before updating.")
    end
    local work = Epub.read(entry.work.path)
    if not work or tostring(work.id)~=tostring(entry.work.id) then return nil, _("The local AO3 work no longer matches.") end
    return true
end

-- Reuse the organizer's preflight, backups and Bookshelf move so sidecars,
-- reading progress, collections and history follow a newly updated work.
local function organizeUpdated(work)
    local root=require('ao3lib.core.config'):readSetting('fanfic_folder_path')
    if not root or root=='' then return work,_('Download folder is not set.') end
    local Layout=require('ao3lib.library.layout')
    local destination,err=Layout.destination(work,root)
    if not destination then return work,err end
    if destination==work.path then return work end
    local Organizer=require('ao3lib.library.organizer')
    local plan,why=Organizer.plan({work},root)
    if not plan then return work,why end
    if #plan.moves==0 then return work,(plan.skipped[1] and plan.skipped[1].reason) or _('The move was skipped.') end
    local summary,move_err=Organizer.execute(plan)
    if not summary then return History.get(work.id) or work,move_err end
    local latest=History.get(work.id) or work
    local move=plan.moves[1]
    if summary.failed>0 or summary.skipped>0 or #summary.errors>0 or move.status~='moved' then
        return latest,summary.errors[1] or move.error or _('The move was not completed.')
    end
    return latest
end

function M.apply(entry)
    if not entry.remote or not entry.local_work then return failure(_("Check this work before updating it.")) end
    local unchanged, err = sourceUnchanged(entry)
    if not unchanged then return failure(err) end
    if entry.native_only then
        local local_work=Epub.read(entry.work.path)
        if not local_work or not local_work._ao3_html_conversion then return failure(_("This work is no longer an HTML conversion.")) end
        if not entry.remote.epub_link then return failure(_("Native EPUB download is not available yet.")) end
    end
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
    -- Replace the EPUB atomically first; relocate it only after progress is saved.
    -- URL-only calls cannot invoke HTML fallback, even when globally enabled.
    local source=remote.epub_link
    if not entry.native_only and remote.html_link and require("ao3lib.core.config"):readSetting("html_download_fallback", false) then source=remote end
    local response = Client:downloadEpub(source, entry.work.path, true,
        function() return sourceUnchanged(entry) end)
    if not response.success then return failure(response.error, response) end
    local updated = util.tableDeepCopy(old)
    for __, key in ipairs({"title","author","chapters","summary","fandoms","tags","relationships","characters",
            "warnings","hits","kudos","bookmarks","comments","rating","category","iswip","updated","published","wordcount","series","language",
            "markedForLater","subscriptionID","bookmarkID","bookmarkContent"}) do
        if key=="updated" or key=="published" then
            -- A real chapter/word change may still warrant an update when the
            -- date is absent. Do not overwrite a known date with a placeholder.
            if date(remote[key]) then updated[key]=date(remote[key]) end
        elseif remote[key]~=nil then updated[key]=util.tableDeepCopy(remote[key]) end
    end
    updated.id, updated.path = tostring(entry.work.id), entry.work.path
    updated._ao3_html_conversion=nil
    updated.chapter_data = chapters
    if #chapters==0 and n==1 and #(old.chapter_data or {})==1 then updated.chapter_data=old.chapter_data end
    if #updated.chapter_data > 0 or (n and count(entry.local_work) and n>count(entry.local_work)) then updated.read=nil end
    History.update(updated,true)
    local saved, save_err
    if History.awaitSave then saved,save_err=History.awaitSave() else saved,save_err=History.save() end
    if not saved then
        pcall(function() require('ao3lib.library.local_cache').index(updated.path) end)
        pcall(function() require('ao3lib.library.metadata_refresh').notify(updated.path) end)
        local result=failure(_("The EPUB was updated, but its AO3 reading state could not be saved: ") .. tostring(save_err))
        result.downloaded=true
        result.work=updated
        return result
    end
    local background=require('ao3lib.ao3.background')
    if background.checkpoint then background.checkpoint() end
    local old_path=updated.path
    local ok,moved,move_err=pcall(organizeUpdated,updated)
    if ok then updated=moved else move_err=moved;updated=History.get(updated.id) or updated end
    if updated.path~=old_path then
        pcall(function() require('ao3lib.library.local_cache').removePath(old_path) end)
        pcall(function() require('ao3lib.library.metadata_refresh').notify(old_path) end)
    end
    pcall(function() require('ao3lib.library.local_cache').index(updated.path) end)
    pcall(function() require('ao3lib.library.metadata_refresh').notify(updated.path) end)
    return {success=true, work=updated, missing_images=response.missing_images,move_error=move_err}

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
    self.active_entry=nil
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
        self.active_entry=entry;notify()
        local ok, result=pcall(operation=="check" and M.check or M.apply, operation=="check" and entry.work or entry, self.native_only)
        if self.closed or self.generation~=generation then return end
        self.active_entry=nil
        if not ok and require("ao3lib.ao3.background").isCancelled(result) then
            self:stop();notify();return
        end
        if not ok then result=failure(result) end
        if operation=="check" and ok then
            for key in pairs(entry) do entry[key]=nil end
            for key,value in pairs(result) do entry[key]=value end
        elseif operation=="update" and ok and result.success then
            entry.work=result.work; entry.status="updated"; entry.selected=false; entry.error=nil; entry.failure=nil
            entry.missing_images=result.missing_images;entry.move_error=result.move_error
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
        schedule(require("ao3lib.updates.pacing").delay(operation),step)
    end
    step=function()
        require("ao3lib.ao3.background").wrap(stepBody,{
            silent=true,detached=true,
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
