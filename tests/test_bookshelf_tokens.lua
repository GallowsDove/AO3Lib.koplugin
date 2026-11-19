-- Uses Bookshelf's real token registry, expansion and conditionals.
-- Run from the AO3 plugin root: luajit tests/test_bookshelf_tokens.lua
package.path = './?.lua;../bookshelf.koplugin/?.lua;' .. package.path
local function identity(s) return s end
package.loaded.gettext = identity
package.loaded['lib/bookshelf_i18n'] = {gettext=identity}
local warnings = 0
package.loaded.logger = {warn=function() warnings=warnings+1 end}
package.loaded["ao3lib.library.history"] = setmetatable({}, {__index=function()
    error('Tokens must not consult download history')
end})
package.loaded.docsettings = setmetatable({}, {__index=function()
    error('Metadata tokens must not consult or create sidecars')
end})
local works = {
    ['/imported.epub'] = {id='123', title='Local title', authors={'Writer','Coauthor'},
        wordcount='12,345', chapters='3/?', categories={'F/M','F/F'}, rating='Mature',
        warnings={'Creator Chose Not To Use Archive Warnings'}, fandoms={'Fandom A','Fandom B'},
        relationships={'A/B','C/D'}, characters={'Alice','Bob'}, tags={'Slow Burn','Fluff, with a comma'}},
    ['/partial.epub'] = {id='456', title='Partial', chapters='?/?'},
}
package.loaded["ao3lib.library.epub"] = {read=function(path)
    if path=='/broken.epub' then error('corrupt archive') end
    return works[path]
end}
local Tokens = require('lib/bookshelf_tokens')
local Extension = require('ao3lib.bookshelf.tokens')
local book = {filepath='/imported.epub',title='Ordinary title',authors={'Ordinary author'},rating=4}
local function expand(s, fixture) return Tokens.expand(s, fixture or book, {}) end
local builtin = expand('%title|%authors|%rating')
-- Warm the registry's token-name cache before registration.
assert(expand('%ao3_words')=='%ao3_words')
assert(Extension.install())
assert(expand('%title|%authors|%rating')==builtin, 'built-in semantics must stay unchanged')
local expected = {
    ao3_id='123', ao3_words='12,345', ao3_chapters='3/?', ao3_authors='Writer, Coauthor',
    ao3_category='F/M, F/F', ao3_rating='Mature', ao3_warnings='Creator Chose Not To Use Archive Warnings',
    ao3_fandoms='Fandom A, Fandom B', ao3_relationships='A/B, C/D', ao3_characters='Alice, Bob',
    ao3_tags='Slow Burn, Fluff, with a comma', ao3_status='Work in progress',
}
local count=0
for name, value in pairs(expected) do
    count=count+1
    assert(expand('%'..name)==value, name)
    for _, fixture in ipairs({{}, {filepath='/ordinary.epub'}, {filepath='/ao3.pdf'},
            {filepath='/missing.epub'}, {filepath='/broken.epub'}}) do
        assert(expand('%'..name, fixture)=='', 'non-AO3/missing/corrupt data must be empty')
    end
end
local picker={}
for _, entry in ipairs(Tokens.CATALOGUE) do
    if entry.owner=='AO3' then
        assert(entry.category=='AO3' and entry.description~='')
        assert(expected[entry.token:sub(2)], 'undocumented token in picker')
        picker[entry.token]=(picker[entry.token] or 0)+1
    end
end
assert(count==12)
for name in pairs(expected) do assert(picker['%'..name]==1) end
assert(Extension.install())
local listed=0
for _, entry in ipairs(Tokens.CATALOGUE) do if entry.owner=='AO3' then listed=listed+1 end end
assert(listed==count, 'reinstallation must not duplicate picker entries')
assert(expand('[if:ao3_words]%ao3_words words · %ao3_chapters chapters[/if]')=='12,345 words · 3/? chapters')
assert(expand('[if:ao3_words]Words: %ao3_words[else]No word count[/if]', {filepath='/ordinary.epub'})=='No word count')
assert(expand('[b]%title[/b] [i]by %ao3_authors[/i]')=='[b]Ordinary title[/b] [i]by Writer, Coauthor[/i]')
assert(expand('%ao3_words|%ao3_chapters|%ao3_status|%ao3_fandoms', {filepath='/partial.epub'})=='|||')
-- An EPUB refreshed on disk must show its current local metadata immediately.
works['/imported.epub'].wordcount, works['/imported.epub'].chapters = '15,000', '4/4'
assert(expand('%ao3_words · %ao3_chapters · %ao3_status')=='15,000 · 4/4 · Complete')
assert(warnings==count, 'each failing native expander logs only once')
package.loaded['lib/bookshelf_tokens']={API=0,register=function() error('unsupported API used') end}
assert(Extension.install()==false)
package.loaded['lib/bookshelf_tokens']=Tokens
assert(Extension.install())
print('PASS: 12 local AO3 tokens; real expansion/conditionals/styles; picker/idempotence; built-in isolation; imported/partial/non-AO3/corrupt files; fresh metadata; no history/sidecars; older API compatibility')
