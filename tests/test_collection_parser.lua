dofile('tests/test_failures.lua')
local Client=require('ao3lib.ao3.client')
local function findParser(fn,seen)
    seen=seen or {};if seen[fn] then return end;seen[fn]=true
    for i=1,100 do
        local name,value=debug.getupvalue(fn,i);if not name then break end
        if name=='AO3WebParser' then return value end
        if type(value)=='function' then local found=findParser(value,seen);if found then return found end end
    end
end
local Parser=assert(findParser(Client.getUserCollections))
local function node(content,attrs,selectors)
    return {attributes=attrs or {},getcontent=function() return content or '' end,
        select=function(_,selector) return (selectors or {})[selector] or {} end}
end
local entry=node('',nil,{['.heading > a:not([class])']={node('Title &amp; More',{href='/collections/example'})},
    [".heading > a.owner"]={node('Owner',{href='/users/owner'})},
    [".heading > a.mod"]={node('Pseud',{href='/users/mod/pseuds/Pseud'})},
    ['p.type']={node('(Open, Moderated)')},['.summary']={node('<p>Full text</p>')},
    ['.tags > a.tag']={node('Tag &amp; More')},['dd.works > a']={node('1,200')},
    ['dd.bookmarks > a']={node('33')},['dd.collections > a']={node('4')},['dd.prompts > a']={node('5')}})
local parsed=Parser:parseUserCollectionsPage(node('',nil,{['#main']={node()},['li.collection']={entry}}))[1]
assert(parsed.id=='example' and parsed.title=='Title & More' and parsed.type=='(Open, Moderated)')
assert(parsed.authors[1].username=='owner' and parsed.authors[1].pseud=='owner' and parsed.authors[2].pseud=='Pseud')
assert(parsed.work_count==1200 and parsed.bookmark_count==33 and parsed.subcollection_count==4 and parsed.prompt_count==5)
assert(parsed.summary=='Full text' and parsed.tags[1]=='Tag & More')
local no_type=node('',nil,{['.heading > a:not([class])']={node('Untyped',{href='/collections/empty'})}})
assert(Parser:parseUserCollectionsPage(node('',nil,{['#main']={node()},['li.collection']={no_type}}))[1].title=='Untyped')
local header=node('',nil,{['h2.heading']={node('Bookmark collection')},['blockquote.userstuff']={node('<p>Description</p>')},
    ['p.type']={node('(Open, Moderated)')}})
local dashboard={node('Works (0)',{href='/collections/example/works'}),node('Bookmarked Items (1,234)',{href='/collections/example/bookmarks'})}
require('htmlparser').parse=function() return node('',nil,{['div.primary.header.module']={header},['#dashboard a']=dashboard}) end
require('ssl.https').request=function(req) req.sink('body');return 1,200,{} end
local details=Client:getCollectionInfo('example')
assert(details.success and details.collection.title=='Bookmark collection' and details.collection.work_count==0 and details.collection.bookmark_count==1234)
assert(details.collection.summary:find('Description',1,true) and details.collection.type=='(Open, Moderated)')
assert(not Client:getCollectionInfo('../bad').success)
print('PASS: collection listing parsing, account links, status, counts and optional fields')
