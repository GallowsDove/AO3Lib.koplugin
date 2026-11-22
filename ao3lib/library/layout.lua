local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local ffiUtil = require("ffi/util")
local M = {}

local function component(value, fallback, limit)
    value = util.trim(tostring(value or "")):gsub('[\\/:*?"<>|%c]', '_')
    value = util.getSafeFilename(value, nil, limit or 180):gsub('[%.%s]+$', '')
    if value == "" or value == "." or value == ".." then return fallback end
    return value
end

function M.author(work)
    local first = util.trim((tostring(work.author or ""):match('^[^,]+') or ""))
    local username = first:match('%(([%w_%-]+)%)$')
    return component(username or first, "Unknown author", 100)
end

function M.fandom(work)
    local fandoms=require('ao3lib.library.fields').list(work.fandoms)
    local names,seen={},{}
    for _,value in ipairs(fandoms) do
        local name=util.trim(tostring(value or ''))
        if name~='' and name~='N/A' and not seen[name:lower()] then
            names[#names+1]=name;seen[name:lower()]=true
        end
    end
    if #names>1 then return 'Crossover' end
    return names[1] or 'Unknown fandom'
end

function M.validate(template)
    if type(template)~='string' or util.trim(template)=='' then return false, 'Layout template cannot be empty.' end
    if template:sub(1,1)=='/' or template:sub(-1)=='/' or template:find('//',1,true) then
        return false, 'Use / only between folder and filename components.'
    end
    if template:find('[\\:*?"<>|%c]') then return false, 'Template contains an invalid filename character.' end
    for part in template:gmatch('[^/]+') do
        if part=='.' or part=='..' or util.trim(part)=='' then return false, 'Folder and filename components cannot be empty, . or ..' end
        if part:find('[%.%s]+$') then return false, 'Components cannot end with a dot or whitespace.' end
    end
    local pos=1
    while true do
        local i=template:find('%',pos,true)
        if not i then break end
        local token=template:sub(i+1,i+1)
        if token=='' or not ('ITAFBLYSRta'):find(token,1,true) then return false, 'Unknown layout token: %'..token end
        pos=i+2
    end
    return true
end

local function tokens(work)
    local title=tostring(work.title or '')
    local authors=tostring(work.author or '')
    local series=type(work.series)=='table' and work.series[1]
    local series_name=type(series)=='table' and series.title or type(series)=='string' and series or nil
    local date=tostring(work.published or ''):match('^(%d%d%d%d)')
    local status=tostring(work.iswip or '')
    if status=='' or status=='N/A' then status='Unknown status' end
    return {I=tostring(work.id or 'Unknown ID'),T=title~='' and title or 'Untitled',A=M.author(work),F=M.fandom(work),
        B=authors~='' and authors or 'Unknown author',L=work.language or 'Unknown language',Y=date or 'Unknown year',
        S=status,R=series_name or 'No series',t=(title~='' and title or 'Untitled'):gsub('%s+','_'),
        a=(authors~='' and authors or 'Unknown author'):gsub('%s+','_')}
end

function M.filename(work, template)
    local fields=tokens(work)
    return component((template or '%I'):gsub('%%([ITAFBLYSRta])',fields),tostring(work.id or 'Untitled'))
end

function M.options()
    return {template=require('ao3lib.core.config'):readSetting('download_layout_template','%A/%T')}
end

function M.root(path)
    local canonical = ffiUtil.realpath and ffiUtil.realpath(path)
    if canonical then return canonical end
    if path:sub(1,1) ~= '/' then path = lfs.currentdir() .. '/' .. path end
    local parts = {}
    for part in path:gmatch('[^/]+') do
        if part == '..' then table.remove(parts)
        elseif part ~= '.' then parts[#parts+1] = part end
    end
    return '/' .. table.concat(parts, '/')
end

function M.basePath(work, root, options)
    options = options or M.options()
    root = M.root(root):gsub('/+$', '')
    local template=options.template or '%A/%T'
    local valid,err=M.validate(template)
    if not valid then return nil,err end
    local fields=tokens(work)
    local parts={}
    for part in template:gmatch('[^/]+') do
        local expanded=part:gsub('%%([ITAFBLYSRta])',fields)
        parts[#parts+1]=component(expanded,'Unknown')
    end
    return root .. '/' .. table.concat(parts,'/') .. '.epub'
end

function M.parentProblem(path)
    local dir = path:match('^(.*)/[^/]+$')
    while dir and dir ~= '' do
        local mode = lfs.attributes(dir, 'mode')
        if mode and mode ~= 'directory' then return 'Destination folder is occupied by a file: ' .. dir end
        dir = dir:match('^(.*)/[^/]+$')
    end
end

-- Include companion files and orphaned sidecars when reserving a name. A
-- vacant EPUB filename must not merge unrelated reading state into this book.
function M.occupied(path, source)
    if path == source then return false end
    local stat = lfs.symlinkattributes or lfs.attributes
    if stat(path, "mode") then return true end
    if stat(path:gsub('%.[^/.]+$', '') .. '.sdr', "mode") then return true end
    for _, ext in ipairs({'.txt', '.html'}) do
        if stat(path .. ext, "mode") then return true end
    end
    local ok, DocSettings = pcall(require, "docsettings")
    if ok then
        local dir = DocSettings:getSidecarDir(path, "dir")
        if dir and stat(dir, "mode") then return true end
    end
    return false
end

-- The ID is only appended when another file or a planned destination occupies
-- the plain title. A numeric suffix also handles stale/colliding ID paths.
function M.destination(work, root, options, reserved)
    if type(root) ~= 'string' or root == '' then return nil, 'Set the work folder first' end
    local base,err = M.basePath(work, root, options)
    if not base then return nil,err end
    reserved = reserved or {}
    local function available(path)
        return not reserved[path:lower()] and not M.occupied(path, work.path)
    end
    if available(base) then return base end
    local stem = base:sub(1, -6) .. ' [' .. component(work.id, "AO3", 30) .. ']'
    for n = 1, 1000 do
        local path = stem .. (n == 1 and '' or ' (' .. n .. ')') .. '.epub'
        if available(path) then return path end
    end
    return nil, "Too many filename collisions for " .. tostring(work.title)
end

return M
