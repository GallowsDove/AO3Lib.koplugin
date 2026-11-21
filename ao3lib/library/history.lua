local json = require("dkjson")
local Persistent = require("ao3lib.core.persistent")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local DownloadedFanfics = {}

local history_file_path = Persistent.path("fanfic_history.json")
local downloaded_fanfics = {}
local revision = 0
local progress_dirty, save_scheduled, worker
local startBackgroundSave
local loaded_stamp
local function historyStamp()
    local s = lfs.attributes(history_file_path)
    if not s then return "missing" end
    return table.concat({s.size or 0,s.modification or 0,s.change or 0,s.ino or 0}, ":")
end

function DownloadedFanfics.revision() return revision end

local deepcopy = require("ao3lib.core.table").deepCopy

local Fields = require("ao3lib.library.fields")

local function writeHistory(destination, temporary)
    local content, encode_err = json.encode(downloaded_fanfics, { indent = true })
    if not content then return nil, encode_err end
    local file, err = io.open(temporary, "wb")
    if not file then
        logger.err("Failed to save work history:", err)
        return nil, err
    end

    local wrote, write_err = file:write(content)
    local closed, close_err = file:close()
    if not wrote or not closed then os.remove(temporary); return nil, write_err or close_err end
    local renamed, rename_err = os.rename(temporary, destination)
    if not renamed then os.remove(temporary); return nil, rename_err end
    logger.dbg("Work history saved successfully.")
    return true
end

-- Explicit mutations and shutdown checkpoints remain synchronous. An older
-- worker can only publish through the parent, which checks its revision.
function DownloadedFanfics.save()
    revision = revision + 1
    if save_scheduled then
        require("ui/uimanager"):unschedule(startBackgroundSave)
        save_scheduled = false
    end
    local ok, err = writeHistory(history_file_path, history_file_path .. ".tmp")
    if ok then progress_dirty = false; loaded_stamp = historyStamp() end
    return ok, err
end

local function scheduleSave()
    if save_scheduled or worker then return end
    save_scheduled = true
    -- Let the page paint before forking. Encoding and writing run in the child,
    -- rather than merely moving the same blocking write to a later UI callback.
    require("ui/uimanager"):scheduleIn(0.25, startBackgroundSave)
end

startBackgroundSave = function()
    save_scheduled = false
    if not progress_dirty or worker then return end
    local UI = require("ui/uimanager")
    local ffiutil = require("ffi/util")
    if not ffiutil.runInSubProcess or not ffiutil.isSubProcessDone then
        logger.warn("AO3 background history save unavailable; progress will be saved when closing the reader")
        return
    end
    local named, token = pcall(os.tmpname)
    if not named then logger.warn("AO3 history save could not create a temporary name:", token); return end
    os.remove(token)
    local ready = history_file_path .. ".async-" .. token:match("([^/]+)$")
    local temporary = ready .. ".tmp"
    os.remove(ready); os.remove(temporary)
    local snapshot_revision = revision
    local ok, pid = pcall(ffiutil.runInSubProcess, function()
        -- Fork supplies a consistent copy-on-write snapshot of history. The
        -- child never touches the canonical history or another worker's file.
        local saved, err = writeHistory(ready, temporary)
        if not saved then logger.warn("AO3 background history save failed:", err) end
        return saved
    end)
    if not ok or not pid then
        os.remove(ready); os.remove(temporary)
        logger.warn("AO3 background history save could not start:", pid)
        return
    end
    local job = {pid=pid, revision=snapshot_revision}
    worker = job
    local function collect()
        if not ffiutil.isSubProcessDone(job.pid) then UI:scheduleIn(0.1, collect); return end
        worker = nil
        if job.revision == revision then
            local saved, err = os.rename(ready, history_file_path)
            if saved then progress_dirty = false; loaded_stamp = historyStamp()
            else logger.warn("AO3 history save did not complete; will retry on reader close:", err) end
        end
        os.remove(ready); os.remove(temporary)
        if progress_dirty and job.revision ~= revision then scheduleSave() end
    end
    UI:scheduleIn(0.1, collect)
end

function DownloadedFanfics.flushPending()
    if progress_dirty then return DownloadedFanfics.save() end
    return true
end

function DownloadedFanfics.updateDownloadFile_1()
    DownloadedFanfics.load()

    local new_fanfics_set = {}

    for __, fanfic in pairs(downloaded_fanfics) do
        new_fanfics_set[fanfic.id] = fanfic
    end

    downloaded_fanfics = new_fanfics_set

    DownloadedFanfics.save()
end

-- Load the downloaded fanfic history from a file
function DownloadedFanfics.load()
    -- Reader/FileManager instances share this module. Do not replace pending
    -- in-memory progress with an older on-disk snapshot during a reader switch.
    if progress_dirty then return end
    local stamp = historyStamp()
    if loaded_stamp == stamp then return end
    local file, err = io.open(history_file_path, "r")
    if not file then
        logger.dbg("No work history file found. Starting fresh.")
        loaded_stamp = stamp
        return
    end

    local content = file:read("*a")
    file:close()

    local history, _, err = json.decode(content)
    if not history then
        logger.err("Failed to load work history:", err)
        return
    end

    -- Normalize fields for all loaded fanfics
    for _, fanfic in pairs(history) do
        fanfic.id = tostring(fanfic.id)
        Fields.normalize(fanfic, {"fandoms", "relationships", "characters", "tags"})
    end

    downloaded_fanfics = history
    loaded_stamp = stamp
    revision = revision + 1
    logger.dbg("Work history loaded successfully.")
end

-- Get all downloaded fanfics
function DownloadedFanfics.getAll()
    return deepcopy(downloaded_fanfics)
end

-- Saved state only; callers must establish file identity separately.
function DownloadedFanfics.get(fanficId)
    return deepcopy(downloaded_fanfics[tostring(fanficId)])
end

-- Identity has already been verified from the EPUB. History contributes
-- reading progress and richer online metadata, never identity.
function DownloadedFanfics.rememberLocal(work, defer_save)
    local id = tostring(work.id)
    local current = downloaded_fanfics[id]
    local merged = current and deepcopy(current) or deepcopy(work)
    local changed = not current or current.path ~= work.path
    for key, value in pairs(work) do
        if merged[key] == nil or merged[key] == "" then
            merged[key] = deepcopy(value)
            changed = true
        end
    end
    merged.id, merged.path = id, work.path
    merged.chapter_data = merged.chapter_data or {}
    downloaded_fanfics[id] = merged
    if changed and not defer_save then DownloadedFanfics.save() end
    return deepcopy(merged), changed
end

-- Add a new fanfic to the downloaded list
function DownloadedFanfics.add(fanfic)
    Fields.normalize(fanfic, {"fandoms", "relationships", "characters", "tags"})
    downloaded_fanfics[tostring(fanfic.id)] = fanfic
    DownloadedFanfics.save()
end

-- Update an existing fanfic in the downloaded list
function DownloadedFanfics.update(fanfic, notSave)
    Fields.normalize(fanfic, {"fandoms", "relationships", "characters", "tags"})
    downloaded_fanfics[tostring(fanfic.id)] = fanfic
    if notSave then
        return true
    end
    return DownloadedFanfics.save()
end

-- Delete a fanfic from the downloaded list
function DownloadedFanfics.delete(fanficId)
    if not downloaded_fanfics[tostring(fanficId)] then
        return false
    end
    downloaded_fanfics[tostring(fanficId)] = nil
    DownloadedFanfics.save()
    return true
end

function DownloadedFanfics.markChapterAsRead(fanficId, chapter_id)
    local work = downloaded_fanfics[tostring(fanficId)]
    if not work or not work.chapter_data or not work.chapter_data[chapter_id] then return nil end
    if not work.chapter_data[chapter_id].read then
        work.chapter_data[chapter_id].read = true
        revision = revision + 1
        progress_dirty = true
        scheduleSave()
    end
    return true
end

function DownloadedFanfics.markWorkAsRead(fanficId)
    local work = downloaded_fanfics[tostring(fanficId)]
    if not work then return nil end
    if not work.read then
        work.read = true
        revision = revision + 1
        progress_dirty = true
        scheduleSave()
    end
    return true
end

function DownloadedFanfics.checkIfStored(fanficId)
    local work = downloaded_fanfics[tostring(fanficId)]
    if not work then return end
    local epub = require("ao3lib.library.epub").read(work.path)
    if epub and tostring(epub.id) == tostring(fanficId) then return work end
end





function DownloadedFanfics.relocate(id, oldPath, newPath, defer_save)
    local work = downloaded_fanfics[tostring(id)]
    if not work or (work.path ~= oldPath and work.path ~= newPath) then
        return nil, "AO3 record changed since preview"
    end
    work.path = newPath
    if not defer_save then return DownloadedFanfics.save() end
    return true
end

function DownloadedFanfics.changePath(fanficId, newPath)
    return require("ao3lib.library.organizer").moveTo(fanficId, newPath)
end


return DownloadedFanfics
