local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local json = require("dkjson")
local Layout = require("ao3lib.library.layout")
local Epub = require("ao3lib.library.epub")
local History = require("ao3lib.library.history")
local M = {}

local function parent(path) return path:match('^(.*)/[^/]+$') end
local function assertDir(path)
    local ok, err = util.makePath(path)
    if not ok then error(err or ('Could not create ' .. path)) end
end
local function writeFile(path, data)
    local file, err = io.open(path, 'wb')
    if not file then error(err) end
    local wrote, write_err = file:write(data)
    local closed, close_err = file:close()
    if not wrote or not closed then error(write_err or close_err or ('Could not write ' .. path)) end
end
local function journal(path, data)
    local encoded, err = json.encode(data, {indent=true})
    if not encoded then error(err or 'Could not encode move journal') end
    writeFile(path .. '.tmp', encoded)
    local ok, rename_err = os.rename(path .. '.tmp', path)
    if not ok then error(rename_err) end
end
local function event(plan, index, move)
    local encoded = assert(json.encode({index=index, status=move.status, error=move.error}))
    local file, err = io.open(parent(plan.journal) .. '/events.jsonl', 'ab')
    if not file then error(err) end
    local wrote, write_err = file:write(encoded .. '\n')
    local closed, close_err = file:close()
    if not wrote or not closed then error(write_err or close_err) end
end

function M.fileOps()
    local ok, ops = pcall(require, "lib/bookshelf_file_ops")
    if not ok or type(ops) ~= 'table' or type(ops.moveBook) ~= 'function' or type(ops.inUsePaths) ~= 'function' then
        return nil, "Enable Bookshelf and restart KOReader to organize works while preserving reading state."
    end
    return ops
end

function M.plan(works, root, options)
    local ops, err = M.fileOps()
    if not ops then return nil, err end
    if type(root) ~= 'string' or root == '' then return nil, 'Set the work folder first.' end
    root = Layout.root(root)
    local paths, reserved = {}, {}
    for _, work in pairs(works) do paths[#paths+1] = work end
    table.sort(paths, function(a,b) return a.path < b.path end)
    local plan = {root=root, moves={}, skipped={}, options=options or Layout.options()}
    local in_use = ops.inUsePaths()
    for _, work in ipairs(paths) do
        local stat = lfs.symlinkattributes(work.path)
        local to, error_message = Layout.destination(work, root, plan.options, reserved)
        local reason
        if not stat or stat.mode ~= 'file' then reason = 'Missing file or symbolic link'
        elseif to == work.path then reason = 'Already organized'
        elseif in_use[work.path] then reason = 'Currently open'
        elseif not to then reason = error_message
        else reason = Layout.parentProblem(to) end
        if reason then
            plan.skipped[#plan.skipped+1] = {path=work.path, reason=reason}
            if to == work.path then reserved[to:lower()] = true end
        else
            reserved[to:lower()] = true
            plan.moves[#plan.moves+1] = {id=tostring(work.id), from=work.path, to=to,
                size=stat.size, mtime=stat.modification, status='pending'}
        end
    end
    return plan
end

function M.describe(plan)
    local lines = {
        'Destination: ' .. plan.root,
        'Layout: ' .. (plan.options.template or '%A/%T') .. '.epub',
        'AO3 IDs are added only to resolve filename or sidecar collisions.',
        'Reading-state backups and a move journal are created before any work moves.',
        '', tostring(#plan.moves) .. ' to move; ' .. tostring(#plan.skipped) .. ' skipped.', '',
    }
    for _, move in ipairs(plan.moves) do
        lines[#lines+1] = move.from .. '\n  → ' .. move.to
    end
    for _, skip in ipairs(plan.skipped) do lines[#lines+1] = 'SKIP: ' .. skip.path .. ' — ' .. skip.reason end
    return table.concat(lines, '\n')
end

local function copyTree(source, destination)
    local stat = lfs.symlinkattributes(source)
    if not stat then return end
    if stat.mode == 'directory' then
        assertDir(destination)
        for name in lfs.dir(source) do
            if name ~= '.' and name ~= '..' then copyTree(source .. '/' .. name, destination .. '/' .. name) end
        end
    elseif stat.mode == 'file' then
        assertDir(parent(destination))
        local input, err = io.open(source, 'rb')
        if not input then error(err) end
        local output, open_err = io.open(destination, 'wb')
        if not output then input:close(); error(open_err) end
        local ok, copy_err = pcall(function()
            while true do
                local chunk, read_err = input:read(256 * 1024)
                if not chunk then if read_err then error(read_err) end; break end
                assert(output:write(chunk))
            end
        end)
        input:close()
        local closed, close_err = output:close()
        if not ok or not closed then error(copy_err or close_err) end
    else error('Cannot back up symbolic link or special file: ' .. source) end
end

-- Snapshot state, not the EPUB payloads: moving never rewrites their contents.
function M.backup(plan)
    local DataStorage = require('datastorage')
    local base = require('ao3lib.core.paths').getHomeDirectory() .. '/organization'
    assertDir(base)
    local token,err = require('ao3lib.core.tempfile').reserve(base .. '/backup-')
    assert(token,err)
    local dir = token .. '.d'
    local made,why=lfs.mkdir(dir)
    os.remove(token)
    assert(made,why)
    local sources = {
        DataStorage:getDataDir() .. '/history.lua',
        DataStorage:getDataDir() .. '/settings.reader.lua',
        DataStorage:getSettingsDir() .. '/collection.lua',
        DataStorage:getSettingsDir() .. '/bookshelf',
        DataStorage:getSettingsDir() .. '/ao3lib/fanfic_history.json',
    }
    local DocSettings = require('docsettings')
    local seen = {}
    plan.backups = {}
    local function backup(source)
        if not source or seen[source] or not lfs.attributes(source, 'mode') then return end
        for path in pairs(seen) do if source:sub(1,#path+1) == path .. '/' then return end end
        seen[source] = true
        local destination = dir .. '/state/' .. tostring(#plan.backups+1)
        copyTree(source, destination)
        plan.backups[#plan.backups+1] = {source=source, backup=destination}
    end
    for _, source in ipairs(sources) do backup(source) end
    for _, move in ipairs(plan.moves) do
        for _, location in ipairs({'doc', 'dir', 'hash'}) do backup(DocSettings:getSidecarDir(move.from, location)) end
        local sidecar = DocSettings:findSidecarFile(move.from)
        backup(sidecar)
        backup(move.from .. '.txt')
        backup(move.from .. '.html')
    end
    plan.journal = dir .. '/moves.json'
    plan.status = 'prepared'
    journal(plan.journal, plan)
    return plan.journal
end

function M.execute(plan, progress)
    local ops, err = M.fileOps()
    if not ops then return nil, err end
    if #plan.moves == 0 then return nil, 'There are no works to move.' end
    local ok, path = pcall(M.backup, plan)
    if not ok then return nil, 'Backup failed; no works were moved: ' .. tostring(path) end
    local summary = {moved=0, failed=0, skipped=0, journal=path, errors={}}
    plan.status = 'running'
    for index, move in ipairs(plan.moves) do
        local moved = false
        local success, failure = pcall(function()
            local stat = lfs.symlinkattributes(move.from)
            local identified = Epub.read(move.from)
            if not stat or stat.mode ~= 'file' or stat.size ~= move.size or stat.modification ~= move.mtime
                    or not identified or tostring(identified.id) ~= move.id then
                move.status = 'skipped'; move.error = 'Source changed since preview'; return
            end
            if ops.inUsePaths()[move.from] then move.status='skipped'; move.error='Currently open'; return end
            if Layout.occupied(move.to, move.from) then move.status='skipped'; move.error='Destination is now occupied'; return end
            assertDir(parent(move.to))
            local DocSettings = require('docsettings')
            local had_sidecar = DocSettings:hasSidecarFile(move.from)
            move.status = 'moving'
            event(plan, index, move)
            -- Do not use moveBooks: its same-folder batch assumes basenames
            -- stay unchanged when updating history and collections.
            local done, move_err = ops.moveBook(move.from, move.to)
            if not done then error(move_err or 'Move failed') end
            moved = true
            if had_sidecar and not DocSettings:hasSidecarFile(move.to) then
                pcall(DocSettings.updateLocation, move.from, move.to)
                if not DocSettings:hasSidecarFile(move.to) then
                    if ops.moveBook(move.to, move.from) then
                        moved = false
                        error('Reading state could not be relocated; work returned to its original path')
                    end
                    History.relocate(move.id, move.from, move.to, true)
                    error('Reading state needs recovery from the backup')
                end
            end
            assert(History.relocate(move.id, move.from, move.to, true))
            move.status = 'moved'
        end)
        if not success then
            move.status = moved and 'moved_with_error' or 'failed'
            move.error = tostring(failure)
            summary.failed = summary.failed+1
            summary.errors[#summary.errors+1] = move.from .. ': ' .. move.error
        elseif move.status == 'skipped' then summary.skipped=summary.skipped+1 end
        if moved then summary.moved=summary.moved+1 end
        -- Stop if journaling fails, keeping the prepared journal and backups.
        local saved, save_err = pcall(event, plan, index, move)
        if not saved then summary.errors[#summary.errors+1]=tostring(save_err); break end
        if progress then pcall(progress, index, #plan.moves) end
    end
    if summary.moved > 0 then
        local saved, save_err = History.save()
        if not saved then summary.errors[#summary.errors+1]='AO3 history could not be saved: ' .. tostring(save_err) end
    end
    plan.status = #summary.errors > 0 and 'incomplete' or 'completed'
    local finalized, final_err = pcall(journal, plan.journal, plan)
    if not finalized then summary.errors[#summary.errors+1]='Could not finalize move journal: ' .. tostring(final_err) end
    pcall(function()
        require('lib/bookshelf_book_repository').invalidateWalkCache()
        require('ui/uimanager'):broadcastEvent(require('ui/event'):new('BookMetadataChanged'))
    end)
    return summary
end

-- Compatibility for the old rename entry point, now using the same backup,
-- preflight checks and metadata-aware move path as the organizer.
function M.moveTo(id, destination)
    local work = History.checkIfStored(id)
    if not work then return nil, 'AO3 EPUB not found' end
    if work.path == destination then return true end
    local stat = lfs.attributes(work.path)
    local plan = {root=parent(destination), options={author_folders=false}, skipped={}, moves={{
        id=tostring(id), from=work.path, to=destination, size=stat.size, mtime=stat.modification, status='pending',
    }}}
    local summary, err = M.execute(plan)
    if not summary then return nil, err end
    return summary.moved == 1 and #summary.errors == 0, summary.errors[1]
end

return M
