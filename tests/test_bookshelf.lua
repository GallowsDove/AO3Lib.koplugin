-- Run from the AO3 plugin directory. Uses Bookshelf's real filter engine;
-- repository/sidecar fixtures provide local books without KOReader's UI.
package.path = './?.lua;../bookshelf.koplugin/?.lua;' .. package.path
local function stub(name, value) package.loaded[name] = value end
stub('gettext', function(s) return s end)
stub('lib/bookshelf_i18n', {gettext=function(s) return s end})
local epubs, saved, sidecars = {}, {}, {}
local reads, sidecar_reads, revision = 0, 0, 1
stub('fanfic_epub', {read=function(fp)
    reads = reads+1
    if fp == '/broken.epub' then error('Corrupt archive') end
    return epubs[fp]
end})
stub('downloaded_fanfics', {
    get=function(id) return saved[tostring(id)] end,
    revision=function() return revision end,
})
stub('docsettings', {
    hasSidecarFile=function(_, fp) return sidecars[fp] ~= nil end,
    open=function(_, fp)
        sidecar_reads = sidecar_reads+1
        return {readSetting=function(_, key) return sidecars[fp][key] end}
    end,
})
local Metadata = require('fanfic_bookshelf')
local fp1, fp2, fp3 = '/one.epub', '/two.epub', '/imported.epub'
epubs[fp1] = {id='1', title='First', author='Writer, Coauthor',
    fandoms={'Fandom A', 'Fandom A'}, relationships={'A/B'}, chapters='3/3',
    categories={'F/M','F/F'}, rating='Explicit', warnings={'No Archive Warnings Apply'},
    characters={'Alice'}, tags={'Slow Burn', 'Fluff, with a comma'}}
epubs[fp2] = {id='2', title='Second', author='Writer',
    fandoms={'Fandom B'}, relationships={'C/D'}, chapters='2/?'}
epubs[fp3] = {id='3', title='Imported', author='', fandoms={}, chapters='?/?'}
saved['1'] = {chapter_data={{read=true},{read=false},{read=true}}}
saved['2'] = {chapter_data={{read=true},{read=true}}}
saved['stale'] = {path='/ordinary.epub', author='Should never appear'}
local data = Metadata.get(fp1, true)
assert(data.ao3_authors[1] == 'Writer' and data.ao3_authors[2] == 'Coauthor')
assert(#data.ao3_fandoms == 1 and data.ao3_completion[1] == 'complete')
assert(data.unread_chapters == 1 and data.ao3_unread[1] == 'unread' and sidecar_reads == 0)
assert(data.ao3_categories[1]=='F/M' and data.ao3_categories[2]=='F/F' and data.ao3_ratings[1]=='Explicit')
assert(data.ao3_warnings[1]=='No Archive Warnings Apply' and data.ao3_characters[1]=='Alice')
assert(data.ao3_tags[2]=='Fluff, with a comma')
assert(Metadata.get(fp2, true).ao3_unread[1] == 'read')
-- An externally updated EPUB has an unread chapter even if the old map is read.
epubs[fp2].chapters = '3/?'
assert(Metadata.get(fp2, true).unread_chapters == 1)
epubs[fp2].chapters = '2/?'
assert(Metadata.get(fp3).ao3_authors[1] == 'Anonymous')
assert(Metadata.get(fp3).ao3_completion[1] == 'unknown')
assert(Metadata.get('/ordinary.epub', true) == nil)
assert(Metadata.get(fp3, true).ao3_unread[1] == 'unread')
sidecars[fp3] = {percent_finished=1, summary={status='complete'}}
assert(Metadata.get(fp3, true).ao3_unread[1] == 'read')
sidecars[fp3].percent_finished, sidecars[fp3].summary = 0.5, {}
assert(Metadata.get(fp3, true).ao3_unread[1] == 'unread')
sidecars[fp3] = {}
assert(Metadata.get(fp3, true).ao3_unread[1] == 'unknown')
local DS = package.loaded.docsettings
local native_open = DS.open
DS.open = function() error('Unreadable sidecar') end
assert(Metadata.get(fp3, true).ao3_unread[1] == 'unknown')
DS.open = native_open
epubs[fp1].authors = {'Pseud, with comma'}
assert(#Metadata.get(fp1).ao3_authors == 1 and Metadata.get(fp1).ao3_authors[1] == 'Pseud, with comma')
epubs[fp1].authors = nil
print('PASS: EPUB-only identity; structured authors; metadata; completion; chapter maps; new chapters; imported KOReader progress; no sidecar creation/history mutation')

local Filter = require('lib/bookshelf_filter')
local books = {
    [fp1]={filepath=fp1, title='First', author='Writer', _status='reading', genres={'Fantasy'}},
    [fp2]={filepath=fp2, title='Second', author='Writer', _status='unread', genres={'Other'}},
    [fp3]={filepath=fp3, title='Imported', _status='finished'},
    ['/ordinary.epub']={filepath='/ordinary.epub', title='Ordinary'},
    ['/broken.epub']={filepath='/broken.epub', title='Broken'},
}
local paths = {fp1, fp2, fp3, '/ordinary.epub', '/broken.epub'}
local Repo = {}
function Repo.getAllFilepaths() return paths end
function Repo.lightMetaFor(fp) return books[fp] end
function Repo.applyFilter(records, filter)
    local out, compiled = {}, Filter.compile(filter)
    for _, book in ipairs(records) do
        if Filter.matches(book, compiled) then out[#out+1] = book end
    end
    return out
end
local native_distinct, native_counts = 0, 0
function Repo.distinctFilterValues() native_distinct=native_distinct+1; return {{value='native'}} end
function Repo.filterValueCounts() native_counts=native_counts+1; return {native=1} end
function Repo.searchBooks(query, limit)
    local out = {}
    if not query then return out end
    for _, fp in ipairs(paths) do
        local book, hit = books[fp], true
        local hay = ((book.title or '')..' '..(book.author or '')):lower()
        for word in query:lower():gmatch('%S+') do if not hay:find(word,1,true) then hit=false end end
        if query:find('%S') and hit then
            out[#out+1]=book
            if limit and #out>=limit then break end
        end
    end
    return out
end
stub('lib/bookshelf_book_repository', Repo)
local include_tags = true
stub('lib/bookshelf_settings_store', {read=function(key)
    if key=='search_include_genres' then return include_tags end
end})
local source_calls = 0
stub('lib/bookshelf_sources', {
    get=function(kind) if kind=='catalogue' or kind=='remote' then return {} end end,
    isPaged=function(kind) return kind=='remote' end,
    list=function(kind)
        assert(kind=='catalogue', 'Remote catalogue must never be fetched')
        source_calls=source_calls+1
        return {books[fp2]}
    end,
})
local Integration = require('fanfic_bookshelf_integration')
local native_search = Repo.searchBooks
Repo.searchBooks = nil
assert(not Integration.install() and #Filter.dimensions()==8, 'Unsupported versions must remain untouched')
Repo.searchBooks = native_search
assert(Integration.install() and Integration.install())
assert(#Filter.dimensions() == 18) -- Repeated ReaderUI/FileManager init adds nothing twice.
reads=0
assert(not Filter.isActive({}) and Filter.signature({}) == '')
assert(Filter.matches(books[fp1], Filter.compile({statuses={reading=true}})) and reads==0)
assert(not Filter.isActive({ao3_fandoms={}}))
local filter = {ao3_authors={coauthor=true}, ao3_fandoms={['Fandom A']=true},
    ao3_completion={complete=true}, ao3_unread={unread=true}, statuses={reading=true}}
assert(Filter.isActive(filter) and Filter.summary(filter) == '5 active')
assert(Filter.dimSummary(filter, 'ao3_completion') == 'Complete')
assert(Filter.dimSummary(filter, 'ao3_unread') == 'Has unread chapters')
local kept = Repo.applyFilter({books[fp1], books[fp2], books[fp3], books['/ordinary.epub'], books['/broken.epub']}, filter)
assert(#kept==1 and kept[1].filepath==fp1)
assert(not Filter.matches(books['/broken.epub'], Filter.compile({ao3_authors={Writer=true}})))
assert(Filter.matches(books[fp1],Filter.compile({ao3_categories={['F/M']=true},ao3_ratings={Explicit=true},
    ao3_warnings={['No Archive Warnings Apply']=true},ao3_characters={Alice=true},ao3_tags={['Slow Burn']=true}})))
assert(not Filter.matches(books[fp2],Filter.compile({ao3_categories={['F/M']=true}})))
assert(Repo.distinctFilterValues('ao3_categories')[1].count==1)
assert(Filter.signature({ao3_authors={Writer=true, Coauthor=true}})
    == Filter.signature({ao3_authors={Coauthor=true, Writer=true}}))
assert(Filter.signature({ao3_authors={['a,b']=true}})
    ~= Filter.signature({ao3_authors={a=true,b=true}}))
local before = Filter.signature(filter)
revision=revision+1
assert(Filter.signature(filter) ~= before, 'Reading-state changes must invalidate filtered orders')
local choices = Repo.distinctFilterValues('ao3_authors')
assert(#choices==3 and choices[1].value=='Anonymous' and choices[2].value=='Coauthor')
assert(choices[3].value=='Writer' and choices[3].count==2)
local counts = Repo.filterValueCounts('ao3_fandoms', {ao3_fandoms={['Fandom B']=true}, ao3_completion={complete=true}})
assert(counts['Fandom A']==1 and counts['Fandom B']==nil)
assert(Repo.filterValueCounts('ao3_authors', {ao3_authors={Writer=true}})==nil)
local scoped = Repo.distinctFilterValues('ao3_authors', {kind='catalogue'})
assert(#scoped==1 and scoped[1].value=='Writer' and scoped[1].count==1 and source_calls==1)
assert(#Repo.distinctFilterValues('ao3_authors', {kind='remote'})==0 and source_calls==1)
assert(Repo.distinctFilterValues('genres')[1].value=='native' and native_distinct==1)
assert(Repo.filterValueCounts('genres', filter).native==1 and native_counts==1)
local results = Repo.searchBooks('First Fandom A')
assert(#results==1 and results[1].filepath==fp1)
assert(#Repo.searchBooks('Coauthor')==1)
local native_light = Repo.lightMetaFor
Repo.lightMetaFor = function(fp) if fp~=fp1 then return native_light(fp) end end
local uncached = Repo.searchBooks('First Fandom A')
assert(#uncached==1 and uncached[1].title=='First' and uncached[1].author=='Writer, Coauthor')
Repo.lightMetaFor = native_light
assert(#Repo.searchBooks('A/B')==1 and #Repo.searchBooks('Fandom')==2)
assert(#Repo.searchBooks('F/M Explicit')==1 and #Repo.searchBooks('Alice Slow Burn')==1)
assert(#Repo.searchBooks('Writer')==2, 'Native hits must not be duplicated')
assert(#Repo.searchBooks('Fandom',1)==1)
assert(#Repo.searchBooks('Fandom missing')==0 and #Repo.searchBooks('   ')==0)
include_tags=false
assert(#Repo.searchBooks('Fandom')==0 and #Repo.searchBooks('A/B')==0)
assert(#Repo.searchBooks('Alice')==0 and #Repo.searchBooks('Slow Burn')==0)
assert(#Repo.searchBooks('F/M Explicit')==1)
assert(#Repo.searchBooks('Coauthor')==1)
print('PASS: runtime installation/idempotence; native behavior; combined/saved filters; signatures; counts/facets/source scope; offline search/deduplication/limits/tag setting; corrupt archives')

-- Book details use the existing native modal and pill widgets. The extension
-- adds a tab only while a verified AO3 book's detail modal is being built.
local modal_args, closed, expanded, events = nil, nil, nil, {}
local Modal = {new=function(_, args) modal_args=args; return args end}
local Widget = {}
function Widget:_showBookDetail(book, opts)
    if book.fail then error('Native detail failure') end
    -- Other modals constructed along the way must remain unchanged.
    assert(#Modal:new{tabs={{id='unrelated'}}}.tabs == 1)
    return Modal:new{bw=self, tabs={{id='description'},{id='edit'}}, active_tab=1}
end
function Widget:_expandTag(group, whole)
    events[#events+1] = 'expand'
    expanded=group
    assert(whole)
    self._drilldown_path[#self._drilldown_path+1] = {
        kind='tag', label=group.series_name, payload=group, whole=whole}
end
function Widget:_serializeDrillPath()
    local out={}
    for _, entry in ipairs(self._drilldown_path) do
        out[#out+1]={kind=entry.kind, label=entry.label, whole=entry.whole}
    end
    return out
end
local restored_native=0
function Widget:_restoreDrillPath(entries)
    for _, entry in ipairs(entries or {}) do
        restored_native=restored_native+1
        self._drilldown_path[#self._drilldown_path+1]=entry
    end
end
function Widget:_fetchChipItems()
    return self._drilldown_path[#self._drilldown_path].payload.books
end
function Widget:_currentRegisteredSource() return {kind='native'} end
local current_heading, sections
function Widget:_sectionHeadingBar(title)
    current_heading=title; return {title=title}
end
function Widget:_buildPillGroup(specs)
    sections[current_heading]=specs
    return {specs=specs}, {{specs[1]}}
end
stub('lib/bookshelf_widget', Widget)
stub('lib/bookshelf_reviews_modal', Modal)
stub('device', {screen={scaleBySize=function(_, n) return n end}})
stub('lib/bookshelf_space', {px=function(n) return n end})
local Class = {new=function(_, args) return args end}
stub('ui/widget/container/framecontainer', Class)
stub('ui/widget/verticalgroup', Class)
stub('ui/geometry', Class)
stub('lib/bookshelf_snug_scroll', {new=Class.new, widen=function(n) return n end})
stub('ui/uimanager', {close=function(_, modal) closed=modal end})
assert(Integration.install() and Integration.install())
local bw=setmetatable({_drilldown_path={{kind='folder', label='Starting view'}}}, {__index=Widget})
bw:_showBookDetail(books['/ordinary.epub'])
assert(#modal_args.tabs==2)
bw:_showBookDetail(books['/broken.epub'])
assert(#modal_args.tabs==2)
bw:_showBookDetail(books[fp1])
assert(#modal_args.tabs==3 and modal_args.tabs[3].id=='ao3' and modal_args.active_tab==1)
local live_modal={font_size=20, onClose=function(self)
    closed=self; events[#events+1]='close'
end}
sections={}
local body=modal_args.tabs[3].widget_builder(600,800,live_modal)
assert(#body.focus_tables==10 and #sections['Author(s)']==2)
assert(sections.Category[1].label=='F/M' and sections.Category[2].label=='F/F')
assert(sections.Rating[1].label=='Explicit' and sections['Archive warnings'][1].label=='No Archive Warnings Apply')
assert(sections.Characters[1].label=='Alice' and sections['Additional tags'][2].label=='Fluff, with a comma')
local content=body[1]
assert(content[1].padding_top==0 and content[1].padding_bottom==3)
assert(content[3].padding_top==8 and content[3].padding_bottom==3 and content[2].padding_bottom==0)
assert(sections.Fandoms[1].label=='Fandom A' and sections.Relationships[1].label=='A/B')
assert(sections['Work status'][1].label=='Complete')
assert(sections['Reading status'][1].label=='Has unread chapters')
sections['Author(s)'][2].on_tap()
assert(closed==live_modal and events[1]=='close' and events[2]=='expand')
assert(#expanded.books==1 and expanded.books[1].filepath==fp1)
assert(#bw._drilldown_path==2 and bw._drilldown_path[1].label=='Starting view')
local snapshot=bw:_serializeDrillPath()
assert(snapshot[2]._fanfic_ao3.key=='ao3_authors' and snapshot[2]._fanfic_ao3.value=='Coauthor')
local restored=setmetatable({_drilldown_path={}}, {__index=Widget})
restored:_restoreDrillPath(snapshot)
assert(restored_native==1 and #restored._drilldown_path==2)
assert(restored._drilldown_path[2].payload.books[1].filepath==fp1)
sections.Fandoms[1].on_tap()
assert(#expanded.books==1 and expanded.books[1].filepath==fp1)
sections.Relationships[1].on_tap()
assert(#expanded.books==1 and expanded.books[1].filepath==fp1)
sections['Work status'][1].on_tap()
assert(#expanded.books==1 and expanded.books[1].filepath==fp1)
sections.Category[1].on_tap()
assert(#expanded.books==1 and expanded.books[1].filepath==fp1 and expanded._fanfic_ao3.key=='ao3_categories')
sections['Additional tags'][2].on_tap()
assert(#expanded.books==1 and expanded.books[1].filepath==fp1)
-- Return-from-reader and refresh re-evaluate the selected field rather than
-- restoring the AO3 group as an unrelated KOReader collection.
sections['Reading status'][1].on_tap()
assert(#bw:_fetchChipItems()==1)
saved['1'].chapter_data[2].read=true
assert(#bw:_fetchChipItems()==0)
saved['1'].chapter_data[2].read=false
local original_work=epubs[fp1]
epubs[fp1]=nil
assert(#restored:_fetchChipItems()==0)
epubs[fp1]=original_work
bw:_showBookDetail(books[fp1], {active='ao3'})
assert(modal_args.active_tab==3 and #modal_args.tabs==3)
assert(not pcall(bw._showBookDetail, bw, {filepath=fp1, fail=true}))
assert(#Modal:new{bw=bw,tabs={{id='unrelated'}}}.tabs==1, 'Failed detail builds must clear their scope')
print('PASS: AO3 detail tab; clickable fields; exact local matching; modal-close order; existing back path; persisted navigation; live progress/deletion refresh; scoped/idempotent hooks; failure cleanup')
