-- Identify native AO3 downloads by the original-work link in their preface.
-- Never infer identity from filenames, arbitrary body links, or history.
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local M = {}
local cache, settings, flush_scheduled, cache_dirty
local MAX_TEXT = 4 * 1024 * 1024

local function attr(tag, name)
    name = name:gsub("%-", "%%-")
    return tag:match('%s' .. name .. '%s*=%s*"([^"]*)"')
        or tag:match("%s" .. name .. "%s*=%s*'([^']*)'")
end

local function text(s)
    local entities = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }
    s = (s or ""):gsub("<[^>]*>", "")
    s = s:gsub("&([^;]+);", function(e)
        if entities[e] then return entities[e] end
        local code = e:match("^#(%d+)$")
        local hex = e:match("^#[xX](%x+)$")
        code = tonumber(code) or (hex and tonumber(hex, 16))
        if code and code > 0 and code <= 0x10ffff and not (code >= 0xd800 and code <= 0xdfff) then
            return util.unicodeCodepointToUtf8(code)
        end
        return "&" .. e .. ";"
    end)
    return util.trim(s:gsub("%s+", " "))
end

local function workId(url)
    local host, id, tail = url:match("^https?://([^/]+)/works/(%d+)(.*)$")
    if host ~= "archiveofourown.org" and host ~= "www.archiveofourown.org" then return end
    if id:match("^0+$") then return end
    if tail == "" or tail:match("^[/#?]") then return id end
end

-- The message precedes the metadata and author-supplied summary/notes.
-- Restricting detection to it avoids mistaking a linked recommendation for
-- the identity of the containing book.
function M.fromPreface(html)
    if type(html) ~= "string" then return end
    html = html:gsub("<!%-%-.-%-%->", "")
    local start
    for pos, tag, finish in html:gmatch("()<div(%s[^>]-)>()") do
        if attr(tag, "id") == "preface" then start = finish; break end
    end
    if not start then return end
    local preface = html:sub(start)
    local boundary = preface:find("<div[%s>]") or preface:find("</div%s*>") or (#preface + 1)
    local header = preface:sub(1, boundary - 1)
    local id
    for attrs, content in header:gmatch("<p(%s[^>]-)>(.-)</p%s*>") do
        if (" " .. (attr(attrs, "class") or "") .. " "):find("%smessage%s") then
            for tag in content:gmatch("<a(%s[^>]-)>") do
                local candidate = workId(text(attr(tag, "href")))
                if candidate then
                    if id and id ~= candidate then return end
                    id = candidate
                end
            end
        end
    end
    if not id then return end
    return id, preface
end

local function values(html)
    local out = {}
    for content in html:gmatch("<a[^>]*>(.-)</a%s*>") do out[#out + 1] = text(content) end
    if #out == 0 and text(html) ~= "" then out[1] = text(html) end
    return out
end

local function metadata(id, preface, opf)
    local function dc(name)
        return text(opf:match("<dc:" .. name .. "[^>]*>(.-)</dc:" .. name .. "%s*>"))
    end
    local work = {
        id = id, title = dc("title"), author = dc("creator"), summary = dc("description"),
        language = dc("language"), fandoms = {}, warnings = {}, relationships = {},
        characters = {}, tags = {}, chapter_data = {}, chapters = "?/?",
    }
    local creators = {}
    for creator in opf:gmatch("<dc:creator[^>]*>(.-)</dc:creator%s*>") do creators[#creators + 1] = text(creator) end
    work.author = table.concat(creators, ", ")
    work.authors = creators
    local fields = { fandom = "fandoms", fandoms = "fandoms", ["archive warning"] = "warnings",
        ["archive warnings"] = "warnings", relationship = "relationships", relationships = "relationships",
        character = "characters", characters = "characters", ["additional tags"] = "tags" }
    for label, content in preface:gmatch("<dt[^>]*>(.-)</dt%s*>%s*<dd[^>]*>(.-)</dd%s*>") do
        label = text(label):lower():gsub(":$", "")
        if fields[label] then work[fields[label]] = values(content)
        elseif label == "rating" then work.rating = text(content)
        elseif label == "category" or label == "categories" then
            work.categories = {}
            for _, category in ipairs(values(content)) do
                for value in category:gmatch("[^,%s]+") do work.categories[#work.categories+1] = value end
            end
            work.category = table.concat(work.categories, ", ")
        elseif label == "language" then work.language = text(content)
        elseif label == "stats" then
            local stats = text(content)
            work.published = stats:match("Published:%s*(%d%d%d%d%-%d%d%-%d%d)")
            work.updated = stats:match("Updated:%s*(%d%d%d%d%-%d%d%-%d%d)")
                or stats:match("Completed:%s*(%d%d%d%d%-%d%d%-%d%d)")
            work.wordcount = stats:match("Words:%s*([%d,]+)")
            work.chapters = (stats:match("Chapters:%s*(%d+%s*/%s*[%d?]+)") or "?/?"):gsub("%s", "")
        end
    end
    local count, total = work.chapters:match("^(%d+)/(%d+)$")
    work.iswip = count and total and tonumber(count) >= tonumber(total) and "Complete" or "Work in Progress"
    return work
end

local function decodePath(path)
    return (path:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function resolve(dir, href)
    local parts = {}
    href = decodePath(href:gsub("#.*$", ""))
    if href:find(":", 1, true) or href:sub(1, 1) == "/" then return end
    for part in (dir .. "/" .. href):gmatch("[^/]+") do
        if part == ".." then
            if #parts == 0 then return end
            table.remove(parts)
        elseif part ~= "." then parts[#parts + 1] = part end
    end
    return table.concat(parts, "/")
end

-- Read only the container, package, and up to eight opening spine documents.
function M.scanReader(rd)
    local function read(path)
        local e = path and rd.entries[path]
        if not e or (tonumber(e.size) or 0) > MAX_TEXT then return end
        local s = rd:extractToMemory(path)
        if rd.err then error(rd.err) end
        if type(s) == "string" and #s <= MAX_TEXT then return s end
    end
    local container = read("META-INF/container.xml")
    if not container then return end
    local package_path
    for tag in container:gmatch("<rootfile(%s[^>]-)>") do
        package_path = attr(tag, "full-path")
        if package_path then break end
    end
    if not package_path then return end
    package_path = decodePath(text(package_path))
    local opf = read(package_path)
    if not opf then return end
    local dir = package_path:match("^(.*)/[^/]+$") or ""
    local items = {}
    for tag in opf:gmatch("<item(%s[^>]-)>") do
        local id, href = attr(tag, "id"), attr(tag, "href")
        local media = attr(tag, "media-type")
        if id and href and (media == "application/xhtml+xml" or media == "text/html") then
            items[id] = resolve(dir, text(href))
        end
    end
    local checked = 0
    for tag in opf:gmatch("<itemref(%s[^>]-)>") do
        local path = items[attr(tag, "idref")]
        if path then
            checked = checked + 1
            if checked > 8 then break end
            local html = read(path)
            local id, preface = M.fromPreface(html)
            if id then return metadata(id, preface, opf) end
        end
    end
end

local function scan(path)
    local rd
    local ok, result = pcall(function()
        rd = require("ffi/archiver").Reader:new()
        if not rd:open(path) then error("Could not open EPUB archive") end
        local count = 0
        for _ in rd:iterate() do
            count = count + 1
            if count > 10000 then return end
        end
        if rd.err then error(rd.err) end
        return M.scanReader(rd)
    end)
    if rd then pcall(function() rd:close() end) end
    return ok and result or nil, ok
end

local function getCache()
    if cache then return cache end
    local ok, value = pcall(function()
        settings = require("luasettings"):open(require("datastorage"):getDataDir() .. "/cache/ao3_epubs.lua")
        return settings:readSetting("preface_v1", {})
    end)
    cache = ok and type(value) == "table" and value or {}
    return cache
end

function M.flush()
    if flush_scheduled then
        local UI = require("ui/uimanager")
        if UI.unschedule then UI:unschedule(M.flush) end
    end
    flush_scheduled = false
    if cache_dirty and settings then
        local ok = pcall(function() settings:saveSetting("preface_v1", cache); settings:flush() end)
        if ok then cache_dirty = false end
    end
end

function M.invalidate(path, defer)
    local entries = getCache()
    if entries[path] ~= nil then
        entries[path] = nil
        cache_dirty = true
        if defer then
            if not flush_scheduled then
                flush_scheduled=true
                require("ui/uimanager"):scheduleIn(1,M.flush)
            end
        else M.flush() end
    end
end
-- Return indexed works without checking the filesystem. Callers validate in a
-- worker so temporarily inaccessible storage does not erase the index.
function M.indexWorks(roots)
    local out,normalized={},{}
    for _,root in ipairs(roots or {}) do
        if type(root)=="string" and root~="" then
            root=(require("ffi/util").realpath(root) or root):gsub("/+$","")
            normalized[#normalized+1]=root=="" and "/" or root
        end
    end
    for path,entry in pairs(getCache()) do
        if type(path)=="string" and type(entry)=="table" and type(entry.work)=="table" and entry.work.id
                and entry.metadata_version==2 then
            for _,root in ipairs(normalized) do
                if (root=="/" and path:sub(1,1)=="/") or path:sub(1,#root+1)==root.."/" then
                    local work=util.tableDeepCopy(entry.work);work.path=path
                    out[tostring(work.id)]=work
                    break
                end
            end
        end
    end
    return out
end

local function current(path, entry)
    local stat=lfs.attributes(path)
    return stat and stat.mode=="file" and entry and (not entry.work or entry.metadata_version==2)
        and entry.size==stat.size and entry.mtime==stat.modification and entry.change==stat.change
end
-- Used in a background worker to seed library shelves before a directory walk
-- completes. Only current, positive entries under the configured roots qualify.
function M.cachedPaths(roots)
    local out,normalized={},{}
    for _,root in ipairs(roots or {}) do
        if type(root)=="string" and root~="" then
            root=(require("ffi/util").realpath(root) or root):gsub("/+$","")
            normalized[#normalized+1]=root=="" and "/" or root
        end
    end
    for path,entry in pairs(getCache()) do
        if type(path)=="string" and type(entry)=="table" and entry.work and entry.metadata_version==2 then
            for _,root in ipairs(normalized) do
                if (root=="/" and path:sub(1,1)=="/")
                        or path:sub(1,#root+1)==root.."/" then
                    if current(path,entry) then out[#out+1]=path end
                    break
                end
            end
        end
    end
    return out
end
local function result(path,entry)
    if not entry or not entry.work then return end
    local work=util.tableDeepCopy(entry.work)
    work.path=path
    if work.title=="" then work.title=path:match("([^/]+)$") end
    return work
end
local function remember(path,entry)
    getCache()[path]=entry
    cache_dirty=true
    if not flush_scheduled then
        flush_scheduled=true
        require("ui/uimanager"):scheduleIn(1,M.flush)
    end
end
-- Warm cache only: library discovery never opens an uncached EPUB in the UI.
function M.cached(path)
    local entry=getCache()[path]
    if current(path,entry) then return result(path,entry),true end
    return nil,false
end
-- Worker-safe: no cache/history writes. Fingerprints travel with the result.
function M.inspect(path)
    local stat=lfs.attributes(path)
    if not stat or stat.mode~="file" then return end
    local work,ok=scan(path)
    if not ok then return end
    local entry={path=path,size=stat.size,mtime=stat.modification,change=stat.change,
        metadata_version=2,work=work or false}
    if current(path,entry) then return entry end
end
function M.accept(entry)
    if type(entry)~="table" or type(entry.path)~="string" or not current(entry.path,entry) then return end
    local path=entry.path
    entry.path=nil
    remember(path,entry)
    return result(path,entry)
end
function M.read(path)
    if type(path) ~= "string" or not path:lower():match("%.epub$") then return end
    local stat = lfs.attributes(path)
    if not stat or stat.mode ~= "file" then return end
    local entries = getCache()
    local entry = entries[path]
    if not entry or (entry.work and entry.metadata_version ~= 2)
            or entry.size ~= stat.size or entry.mtime ~= stat.modification or entry.change ~= stat.change then
        local work, ok = scan(path)
        if not ok then return end -- Do not persist a transient archive failure.
        entry = { size = stat.size, mtime = stat.modification, change = stat.change, work = work or false, metadata_version=2 }
        remember(path,entry)
    end
    return result(path,entry)
end

return M
