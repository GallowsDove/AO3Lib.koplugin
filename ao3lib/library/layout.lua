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
    local username = first:match('%(([%w_]+)%)$')
    return component(username or first, "Unknown author", 100)
end

function M.filename(work, template)
    local fields = { I = tostring(work.id or ""), T = tostring(work.title or ""), A = tostring(work.author or "") }
    return component((template or "%I"):gsub('%%([ITA])', function(key)
        return fields[key]:gsub('%s+', '_')
    end), tostring(work.id or "Untitled"))
end

function M.options()
    local config = require("ao3lib.core.config")
    return {
        author_folders = config:readSetting("author_folders", true),
        filename_template = config:readSetting("filename_template", "%I"),
    }
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
    if options.author_folders then
        return root .. '/' .. M.author(work) .. '/' .. component(work.title, "Untitled") .. '.epub'
    end
    return root .. '/' .. M.filename(work, options.filename_template) .. '.epub'
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
    if type(root) ~= 'string' or root == '' then return nil, 'Set the fanfic folder first' end
    local base = M.basePath(work, root, options)
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
