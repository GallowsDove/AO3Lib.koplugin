local lfs = require("libs/libkoreader-lfs")
local ffiUtil = require("ffi/util")
local UIManager = require("ui/uimanager")
local Epub = require("ao3lib.library.epub")
local DownloadedFanfics = require("ao3lib.library.history")
local Background = require("ao3lib.ao3.background")
local M = {}

-- Walk in small batches so a first scan of a large library can be cancelled.
-- Cache lookups include size/mtime, so later scans only reopen changed EPUBs.
function M.scan(roots, done, cancelled, options)
    options=options or {}
    local stack, seen, found, errors = {}, {}, {}, {}
    local stopped=false
    local function invalid() return stopped or (cancelled and cancelled()) end
    local function progress()
        if options.progress and not invalid() then options.progress(found) end
    end
    local function closeDirectories()
        for _, frame in ipairs(stack) do
            if frame.handle then pcall(function() frame.handle:close() end) end
        end
    end
    local function push(path)
        if type(path) ~= "string" or path == "" then return end
        path = ffiUtil.realpath(path) or path
        if seen[path] then return end
        if lfs.attributes(path, "mode") ~= "directory" then
            errors[#errors+1]="Cannot read directory: "..path;return
        end
        seen[path] = true
        local ok, iter, handle = pcall(lfs.dir, path)
        if ok then stack[#stack + 1] = { path = path, iter = iter, handle = handle }
        else errors[#errors+1]="Cannot read directory: "..path end
    end
    for i = #roots, 1, -1 do push(roots[i]) end
    local step
    local function finish(err)
        closeDirectories()
        if invalid() then Epub.flushAsync();return end
        if not err and #errors>0 then err=table.concat(errors,"; ") end
        local cache=package.loaded['ao3lib.library.local_cache']
        if not err and cache and cache.merge then cache.merge(roots,found) end
        if options.read_only then Epub.flushAsync();done(found,err);return end
        local works,changed={},false
        for id,work in pairs(found) do
            local merged,updated=DownloadedFanfics.rememberLocal(work,true)
            works[id],changed=merged,changed or updated
        end
        if changed then DownloadedFanfics.saveAsync() end
        Epub.flushAsync();done(works,err)
    end
    step=function()
        if invalid() then closeDirectories(); Epub.flushAsync(); return end
        local uncached={}
        for _ = 1, 20 do
            local frame = stack[#stack]
            if not frame then
                if #uncached==0 then finish();return end
                break
            end
            local ok, name = pcall(frame.iter, frame.handle)
            if not ok or not name then
                if not ok then
                    errors[#errors+1]="Cannot read directory: "..frame.path
                    if frame.handle then pcall(function() frame.handle:close() end) end
                end
                table.remove(stack)
            elseif name ~= "." and name ~= ".." then
                local path = frame.path .. "/" .. name
                local stat = lfs.symlinkattributes(path)
                if stat and stat.mode == "directory" then
                    if name:sub(1, 1) ~= "." and not name:match("%.sdr$") then push(path) end
                elseif stat and (stat.mode == "file" or stat.mode == "link") and name:lower():match("%.epub$") then
                    if Background.available() then
                        local work,known=Epub.cached(path)
                        if work and not found[work.id] then found[work.id]=work end
                        if not known then uncached[#uncached+1]=path end
                    else
                        local read_ok,work=pcall(Epub.read,path)
                        if read_ok and work and not found[work.id] then found[work.id]=work end
                    end
                end
            end
        end
        progress()
        if #uncached>0 then
            Background.run(function()
                local entries={}
                for _,path in ipairs(uncached) do
                    local entry=Epub.inspect(path)
                    if entry then entries[#entries+1]=entry end
                end
                return entries
            end,function(entries,err)
                if invalid() or Background.isCancelled(err) then closeDirectories();return end
                if not entries then finish(tostring(err));return end
                for _,entry in ipairs(entries) do
                    local work=Epub.accept(entry)
                    if work and not found[work.id] then found[work.id]=work end
                end
                progress()
                UIManager:scheduleIn(0.01,step)
            end,{valid=function() return not invalid() end})
        else UIManager:scheduleIn(0.01,step) end
    end
    UIManager:scheduleIn(0, step)
    return {cancel=function() stopped=true;closeDirectories() end}
end

return M
