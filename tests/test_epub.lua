-- Run from the plugin directory: luajit tests/test_epub.lua
package.path = './?.lua;' .. package.path
local function stub(name, value) package.loaded[name] = value end
local function copy(t)
    if type(t) ~= 'table' then return t end
    local out = {}; for k,v in pairs(t) do out[k] = copy(v) end; return out
end
local function trim(s) return s:match('^%s*(.-)%s*$') end
stub('util', { trim = trim, tableDeepCopy = copy,
    unicodeCodepointToUtf8 = function(n) return string.char(n) end })
local tasks = {}
local UI = { scheduleIn = function(_, _, fn) tasks[#tasks + 1] = fn end }
function UI:unschedule(fn)
    for i=#tasks,1,-1 do if tasks[i]==fn then table.remove(tasks,i) end end
end
stub('ui/uimanager', UI)
local function drain()
    local count = 0
    while #tasks > 0 do
        count = count + 1; assert(count < 1000, 'scan did not finish')
        table.remove(tasks, 1)()
    end
end
local persistent, flushes = {}, 0
local settings = {
    readSetting = function(_, k, default) if persistent[k] == nil then persistent[k] = default end; return persistent[k] end,
    saveSetting = function(_, k, v) persistent[k] = v end,
    flush = function() flushes = flushes + 1 end,
}
stub('luasettings', { open = function() return settings end })
stub('datastorage', { getDataDir = function() return '/data' end })
local fs, dirs, archives = {}, {}, {}
local handlesClosed, opens, archivesClosed = 0, 0, 0
local lfs = {}
function lfs.attributes(path, field)
    local stat = fs[path]
    if field then return stat and stat[field] end
    return stat
end
lfs.symlinkattributes = lfs.attributes
function lfs.dir(path)
    assert(dirs[path], 'not a readable directory')
    local names, index = dirs[path], 0
    local handle = { close = function() handlesClosed = handlesClosed + 1 end }
    return function()
        index = index + 1
        if names[index] then return names[index] end
        handle:close()
    end, handle
end
stub('libs/libkoreader-lfs', lfs)
local Reader = {}
function Reader:new() return setmetatable({}, {__index=self}) end
function Reader:open(path)
    opens = opens + 1
    local data = assert(archives[path], 'unreadable fixture')
    self.data, self.entries = data, {}
    for name,s in pairs(data) do
        local e = {path=name, mode='file', size=#s}
        self.entries[#self.entries+1], self.entries[name] = e, e
    end
    return true
end
function Reader:iterate()
    local index = 0
    return function() index = index + 1; return self.entries[index] end
end
function Reader:extractToMemory(name)
    if self.data[name] == 'EXTRACTION ERROR' then error('corrupt entry') end
    return self.data[name]
end
function Reader:close() archivesClosed = archivesClosed + 1 end
stub('ffi/archiver', {Reader=Reader})
local Epub = require('ao3lib.library.epub')
local function preface(id)
    return [[<div class='calibre1' id='preface'><h2>Preface</h2>
      <p class='message extra'><b>Title</b><a href='https://archiveofourown.org/'>Archive</a>
      <a href='https://archiveofourown.org/works/]] .. id .. [[?view_full_work=true&amp;x=1'>original</a></p>
      <div class='meta'><dl class='tags'><dt>Fandom:</dt><dd><a href='/tags/fandom'>Example &amp; Fandom</a></dd>
      <dt>Categories:</dt><dd><a href='/tags/fm'>F/M</a><a href='/tags/ff'>F/F</a></dd>
      <dt>Rating:</dt><dd><a href='/tags/rating'>Explicit</a></dd>
      <dt>Archive Warnings:</dt><dd><a href='/tags/warning'>No Archive Warnings Apply</a></dd>
      <dt>Additional Tags:</dt><dd><a href='/tags/fluff'>Fluff, with a comma</a>, <a href='/tags/comfort'>Comfort</a></dd>
      <dt>Series:</dt><dd><span class="position">Part 2 of <a href="https://archiveofourown.org/series/3884635">The Harem's Kingdom</a></span>,
      <span class="position">Part 1.5 of <a href="/series/42">Other &amp; Series</a></span>
      <a href="https://evil.example/series/99">Wrong host</a><a href="/series/42">Duplicate</a></dd>
      <dt>Stats:</dt><dd>Published: 2026-01-01 Updated: 2026-01-02 Words: 1,234 Chapters: 2/3</dd>
      <dt>Characters:</dt><dd><a href='/tags/person'>Person</a></dd></dl></div></div>]]
end
assert(Epub.fromPreface(preface('123')) == '123')
assert(Epub.fromPreface([[<p><a href='https://archiveofourown.org/works/999'>recommendation</a></p>]]) == nil)
assert(Epub.fromPreface(preface('123'):gsub('archiveofourown.org/works', 'archiveofourown.org.evil/works')) == nil)
assert(Epub.fromPreface(preface('123'):gsub('class=\'message extra\'', "class='notes'")) == nil)
assert(Epub.fromPreface(preface('123'):gsub('/works/123%?', '/works/123abc?')) == nil)
assert(Epub.fromPreface(preface('123'):gsub('id=\'preface\'', "id='chapters'")) == nil)
assert(Epub.fromPreface('<!--' .. preface('123') .. '-->') == nil)
-- An unrelated AO3 link in user-supplied summary/notes is never consulted.
assert(Epub.fromPreface([[<div id='preface'><div class='meta'><p class='message'>
<a href='https://archiveofourown.org/works/999'>Other work</a></p></div></div>]]) == nil)
local function fixture(path, id)
    fs[path] = {mode='file', size=100, modification=10, change=10}
    archives[path] = {
        ['META-INF/container.xml'] = [[<container><rootfiles><rootfile media-type='application/oebps-package+xml' full-path='OPS/package.opf'/></rootfiles></container>]],
        ['OPS/package.opf'] = [[<package><metadata><dc:title>Title &amp; More</dc:title><dc:creator>Writer</dc:creator><dc:creator>Other Writer</dc:creator><dc:language>en</dc:language></metadata>
<manifest><item media-type='application/xhtml+xml' href='../Text/front%20matter.xhtml' id='first'/></manifest><spine><itemref idref='first'/></spine></package>]],
        ['Text/front matter.xhtml'] = preface(id),
    }
end
fixture('/home/renamed.epub', '123')
local w = assert(Epub.read('/home/renamed.epub'))
assert(w.id == '123' and w.path == '/home/renamed.epub')
assert(w.title == 'Title & More' and w.author == 'Writer, Other Writer')
assert(w.authors[1] == 'Writer' and w.authors[2] == 'Other Writer')
assert(w.categories[1]=='F/M' and w.categories[2]=='F/F' and w.category=='F/M, F/F')
assert(w.rating=='Explicit' and w.warnings[1]=='No Archive Warnings Apply' and w.tags[1]=='Fluff, with a comma')
assert(w.fandoms[1] == 'Example & Fandom' and w.characters[1] == 'Person')
assert(w.chapters == '2/3' and w.iswip == 'Work in Progress' and w.wordcount == '1,234')
assert(#w.series==2 and w.series[1].id==3884635 and w.series[1].position=='2')
assert(w.series[1].title=="The Harem's Kingdom" and w.series[2].title=='Other & Series' and w.series[2].position=='1.5')
assert(w.published == '2026-01-01' and w.updated == '2026-01-02')
assert(opens == 1 and archivesClosed == 1)
w.title = 'Mutated'; w.fandoms[1] = 'Mutated'
assert(Epub.read('/home/renamed.epub').title == 'Title & More' and opens == 1)
assert(Epub.read('/home/renamed.epub').fandoms[1] == 'Example & Fandom')
fixture('/home/ordinary.epub', '456')
archives['/home/ordinary.epub']['Text/front matter.xhtml'] = '<p>Ordinary EPUB</p>'
assert(Epub.read('/home/ordinary.epub') == nil)
local before = opens
assert(Epub.read('/home/ordinary.epub') == nil and opens == before) -- negative cache
archives['/home/ordinary.epub']['Text/front matter.xhtml'] = preface('456')
fs['/home/ordinary.epub'].modification = 20
assert(Epub.read('/home/ordinary.epub').id == '456' and opens == before + 1)
Epub.flush()
local saved_flushes = flushes
Epub.flush()
assert(flushes == saved_flushes, 'An unchanged metadata cache must not be rewritten')
assert(#tasks == 0, 'Manual flush must cancel its scheduled duplicate')
package.loaded["ao3lib.library.epub"] = nil
Epub = require('ao3lib.library.epub')
before = opens
assert(Epub.read('/home/renamed.epub').id == '123' and opens == before) -- persisted cache
stub('ffi/util', {realpath=function(path) return path end})
local cached=Epub.cachedPaths({'/home'})
local cached_set={};for _,path in ipairs(cached) do cached_set[path]=true end
assert(cached_set['/home/renamed.epub'] and not cached_set['/home-sibling/renamed.epub'])
fs['/home/renamed.epub'].modification=11
for _,path in ipairs(Epub.cachedPaths({'/home'})) do
    assert(path~='/home/renamed.epub','A changed EPUB cannot seed a shelf')
end
fs['/home/renamed.epub'].modification=10
-- Previously cached EPUBs acquire separate category values without modifying
-- the book, while the negative cache and current-schema entries stay warm.
persistent.preface_v1['/home/renamed.epub'].metadata_version=3
persistent.preface_v1['/home/renamed.epub'].work.series=nil
assert(Epub.indexWorks({'/home'})['123'],'Older cached works must remain available to seed a background refresh')
assert(not Epub.cached('/home/renamed.epub'),'Old metadata must be refreshed even if the EPUB fingerprint is unchanged')
persistent.preface_v1['/home/renamed.epub'].work.categories=nil
local refreshed=Epub.read('/home/renamed.epub')
assert(opens==before+1 and refreshed.categories[2]=='F/F' and refreshed.series[1].id==3884635)
fixture('/home/corrupt.epub', '777')
archives['/home/corrupt.epub']['Text/front matter.xhtml'] = 'EXTRACTION ERROR'
before = archivesClosed
assert(Epub.read('/home/corrupt.epub') == nil and archivesClosed == before + 1)
fixture('/home/transient.epub','333')
local real_archive_open=Reader.open
Reader.open=function(self,path)
    if path=='/home/transient.epub' then return nil end
    return real_archive_open(self,path)
end
assert(Epub.read('/home/transient.epub')==nil)
Reader.open=real_archive_open
assert(Epub.read('/home/transient.epub').id=='333','A temporary archive-open failure must not be negatively cached')
fs['/home/missing.epub'] = nil
assert(Epub.read('/home/missing.epub') == nil and Epub.read('/home/book.pdf') == nil)
-- Load real history code. It supplies progress, but cannot recognize a work.
stub('dkjson', {})
stub('ao3lib.core.paths', {getHomeDirectory=function() return '/data/fanfic' end})
stub('ao3lib.core.persistent', {path=function(name) return '/data/fanfic/'..name end})
stub('logger', {dbg=function() end, err=function() end, warn=function() end})
stub('ffi/util', {realpath=function(path) return path end})
stub('device', {isAndroid=function() return false end})
local History = require('ao3lib.library.history')
local saves = 0
History.save = function() saves = saves + 1 end
History.add({id='123', path='/old/name.epub', title='Saved title', tags='Fluff, with a comma, Comfort', warnings={}, read=true, chapter_data={{id='chapter',read=true}}})
assert(History.checkIfStored('123') == nil) -- history alone is insufficient
local remembered = History.rememberLocal(Epub.read('/home/renamed.epub'))
assert(remembered.path == '/home/renamed.epub' and remembered.read and remembered.chapter_data[1].read)
assert(#remembered.tag_names==2 and remembered.tag_names[1]=='Fluff, with a comma' and remembered.tag_names[2]=='Comfort',
    'Existing flattened history must recover exact tag boundaries from the EPUB')
assert(History.get('123').tag_names[1]=='Fluff, with a comma')
assert(remembered.warnings[1]=='No Archive Warnings Apply' and History.get('123').warnings[1]==remembered.warnings[1],
    'Empty saved warnings must be recovered from the EPUB')
History.add({id='hidden',path='/hidden.epub',warnings={},warnings_hidden=true})
local hidden=History.rememberLocal({id='hidden',path='/hidden.epub',warnings={'Major Character Death'}})
assert(hidden.warnings_hidden and #hidden.warnings==0, 'Deliberately hidden warnings must remain hidden')
History.add({id='known',path='/known.epub',warnings={'Major Character Death'}})
local known=History.rememberLocal({id='known',path='/known.epub',warnings={'No Archive Warnings Apply'}})
assert(known.warnings[1]=='Major Character Death', 'Existing saved warnings must not be overwritten')
assert(History.checkIfStored('123').path == '/home/renamed.epub')
History.add({id='wrong', path='/home/renamed.epub', title='Wrong identity'})
assert(History.checkIfStored('wrong') == nil)
-- Scan real content from both selected roots; ignore stale records and links
-- to directories, avoid overlapping roots, and yield between batches.
fs['/downloads'], dirs['/downloads'] = {mode='directory'}, {'native.epub'}
fixture('/downloads/native.epub', '888')
fs['/home'], dirs['/home'] = {mode='directory'}, {'renamed.epub','ordinary.epub','missing.epub','corrupt.epub','.hidden','loop'}
fs['/home/.hidden'], dirs['/home/.hidden'] = {mode='directory'}, {'private.epub'}
fixture('/home/.hidden/private.epub', '999')
fs['/home/loop'] = {mode='link'}
local Library = require('ao3lib.library.discovery')
local discovered
local beforeReadOnly=saves
Library.scan({'/downloads','/home','/home'}, function(works) discovered=works end, nil, {read_only=true})
drain()
assert(discovered['123'] and discovered['456'] and discovered['888'])
assert(saves==beforeReadOnly, 'Bookshelf discovery must not modify AO3 download history')
discovered=nil
Library.scan({'/downloads','/home','/home'}, function(works) discovered = works end)
assert(discovered == nil)
drain()
assert(discovered['123'] and discovered['456'] and discovered['888'])
assert(not discovered['999'] and not discovered['wrong'])
assert(discovered['123'].read and discovered['123'].path == '/home/renamed.epub')
assert(discovered['456'].title == 'Title & More' and discovered['456'].chapter_data)
fs['/home/renamed.epub'] = nil
Library.scan({'/downloads','/home'}, function(works) discovered = works end)
drain()
assert(not discovered['123'] and History.checkIfStored('123') == nil)
local cancelled, finished = true, false
local oldSaves, oldClosed = saves, handlesClosed
Library.scan({'/home'}, function() finished = true end, function() return cancelled end)
drain()
assert(not finished and saves == oldSaves and handlesClosed > oldClosed)
assert(flushes > 0)
print('PASS: preface-only identity; OPF/spine paths; metadata; positive/negative/persisted cache; invalidation; corrupt archives; history independence; library discovery/removal/cancellation')
-- Keep a localized preface in the cache to verify invalidation below.
fixture('/home/localized.epub', '222')
archives['/home/localized.epub']['Text/front matter.xhtml'] = preface('222'):gsub('<dl.-</dl>', '')

-- A warm read-only rescan uses cached metadata without rewriting the cache.
Epub.flush();drain()
local before_flush=flushes
Library.scan({'/downloads','/home'},function() end,nil,{read_only=true})
drain()
local cold_flush=flushes
Library.scan({'/downloads','/home'},function() end,nil,{read_only=true})
drain()
assert(flushes==cold_flush,'Warm library scans must not write the metadata cache')
Epub.read('/home/localized.epub')
Epub.flush();cold_flush=flushes
Epub.invalidate('/home/localized.epub')
assert(flushes==cold_flush+1,'Explicit invalidation must still persist cache removal')
Epub.invalidate('/not-cached.epub')
assert(flushes==cold_flush+1,'Invalidating an absent entry must not rewrite the cache')
print('PASS: unchanged scans and absent invalidations do not write cache; scheduled flush deduplication')
