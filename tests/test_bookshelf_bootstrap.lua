-- A slow directory scan must not prevent cached EPUBs warming saved shelves.
package.path='./?.lua;'..package.path
local H=dofile('tests/support/async.lua')
package.loaded.gettext=function(s) return s end
package.loaded['ao3lib.core.config']={readSetting=function() return '/books' end}
package.loaded['apps/filemanager/filemanagerutil']={getHomeFolder=function() return '/books' end}
package.loaded['ao3lib.library.history']={revision=function() return 0 end}
local books={
    ['/books/one.epub']={id='1',title='One',authors={'Author'},fandoms={'Fandom'}},
    ['/books/two.epub']={id='2',title='Two',authors={'Author'},fandoms={'Fandom'}},
}
package.loaded['ao3lib.library.epub']={
    cachedPaths=function(roots)
        assert(H.inChild() and roots[1]=='/books')
        return {'/books/one.epub'}
    end,
    read=function(path) assert(H.inChild());return books[path] end,
}
local finish_scan
package.loaded['ao3lib.library.discovery']={scan=function(_,done) finish_scan=done end}
local specs={}
local Sources={API=1,register=function(id,spec) specs[id]=spec;return true end,
    changed=function() end,list=function(id) return specs[id].list() end}
package.loaded['lib/bookshelf_sources']=Sources
local sort={{key='book_count',reverse=true}}
package.loaded['lib/bookshelf_settings_store']={read=function(key,default)
    if key=='tabs' then return {{source={kind='ao3_fandoms'},filter={},sort_priority=sort}} end
    return default
end}
package.loaded['lib/bookshelf_sort_engine']={chainedComparator=function()
    return function(a,b) return a.book_count>b.book_count end
end}
local Repo={getBySource=function(source) return Sources.list(source.kind) end,
    lightMetaFor=function() return {} end}
local Extension=require('ao3lib.bookshelf.sources')
assert(Extension.install(Repo) and finish_scan,'Startup must start discovery')
H.drain()
local page,total=Repo.getBySource({kind='ao3_fandoms'},{},sort,0,10)
assert(total==1 and page[1].book_count==1,
    'A warm cached shelf must be available while discovery is still running')
finish_scan({one={path='/books/one.epub'},two={path='/books/two.epub'}})
H.drain()
page,total=Repo.getBySource({kind='ao3_fandoms'},{},sort,0,10)
assert(total==1 and page[1].book_count==2,
    'Completed discovery must replace the bootstrap with the full library')
print('PASS: cached AO3 shelves become available during slow discovery and refresh afterward')
