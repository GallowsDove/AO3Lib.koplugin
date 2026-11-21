package.path='./?.lua;'..package.path
local events,forgot,walk={},nil,0
package.loaded['ui/uimanager']={broadcastEvent=function(_,event) events[#events+1]=event end}
package.loaded['ui/event']={new=function(_,name,path) return {name=name,path=path} end}
package.loaded['lib/bookshelf_book_repository']={forgetBook=function(path) forgot=path end,
    invalidateWalkCache=function() walk=walk+1 end}
local Refresh=require('ao3lib.library.metadata_refresh')
Refresh.notify('/books/download.epub')
assert(events[1].name=='InvalidateMetadataCache' and events[1].path=='/books/download.epub')
assert(events[2].name=='BookMetadataChanged')
assert(forgot=='/books/download.epub' and walk==1)
package.loaded['lib/bookshelf_book_repository'].forgetBook=function() error('Optional integration failed') end
Refresh.notify('/books/updated.epub')
assert(walk==2 and events[4].name=='BookMetadataChanged','One failure must not prevent other cache refreshes')
print('PASS: KOReader metadata invalidation, Bookshelf file/walk refresh, rendered metadata notification and isolated integration failures')
