dofile('tests/test_failures.lua')
local Parser=require('ao3lib.ao3.bookmark_entries')
local function node(content,attrs,selectors)
    return {attributes=attrs or {},getcontent=function() return content or '' end,
        select=function(_,selector) return (selectors or {})[selector] or {} end}
end
local entry=node('',nil,{['h5.byline a']={node('Reader',{href='/users/reader/pseuds/Reader'})},
    ['p.datetime']={node('25 Nov 2026')},['blockquote.summary']={node('My note')},
    ['ul.tags a.tag']={node('Tag, with comma'),node('Favorite')},
    ['ul.meta a']={node('Collection',{href='/collections/example'}),node('Favorite',{href='/tags/favorite/bookmarks'})},
    ['p.status span.rec']={node('Rec')}})
local root=node('',nil,{['#main']={node()},['li.user.short.blurb']={entry},
    ['a[rel="next"]']={node('',{href='?page=2'})}})
local parsed=assert(Parser.parse(root,function(s) return s end,1))
assert(#parsed.bookmarks==1 and parsed.next_page==2)
local pagy=node('',nil,{['#main']={node()},['li.user.short.blurb']={entry},
    ['ol.pagination li.next a']={node('',{href='/works/123/bookmarks?view_adult=true&page=2'})},
    ['ol.pagination a']={node('2',{href='?page=2'}),node('10',{href='?page=10'})}})
assert(Parser.parse(pagy,function(s) return s end,1).next_page==2,
    'AO3 Pagy next links do not use rel=next')
assert(Parser.parse(pagy,function(s) return s end,1).total_pages==10)
assert(Parser.parse(root,function(s) return s end,1).total_pages==nil)
assert(Parser.parse(node('',nil,{['#main']={node()}}),function(s) return s end,1).total_pages==1)
local bookmark=parsed.bookmarks[1]
assert(bookmark.bookmarker=='Reader' and bookmark.username=='reader' and bookmark.pseud=='Reader')
assert(bookmark.tags[1]=='Tag, with comma' and bookmark.collections[1]=='Collection' and bookmark.notes=='My note' and bookmark.status=='rec')
assert(bookmark.collection_ids[1]=='example')
assert(not Parser.parse(node(),function(s) return s end,1))
local client=require('ao3lib.ao3.client')
local previous=require('htmlparser').parse
require('htmlparser').parse=function() return root end
local request
require('ssl.https').request=function(req) request=req;req.sink('body');return 1,200,{} end
local result=client:getWorkBookmarks('123',1)
assert(result.success and result.next_page==2 and request.url:find('/works/123/bookmarks?page=1',1,true))
assert(not client:getWorkBookmarks('../bad',1).success)
assert(client:getSeriesBookmarks('123',2).success and request.url:find('/series/123/bookmarks?page=2',1,true))
assert(not client:getSeriesBookmarks('../bad',1).success)
require('htmlparser').parse=previous

dofile('tests/test_work_view.lua')
local View=require('ao3lib.ui.work_view')
local series_opened=false
local series_html,series_actions=View.seriesHTML({id=42,title='Series',bookmarks='1,234',complete='No'},function() series_opened=true end)
assert(series_html:find('1,234 Bookmarks',1,true) and #series_actions==1)
assert(series_html:find('1,234 Bookmarks',1,true)<series_html:find('In progress',1,true))
assert(View.seriesHTML({complete='Yes'}):find('Complete',1,true))
series_actions[1]();assert(series_opened)
local series_rows=View.seriesRows({id=42,title='Series',bookmarks='1,234',complete='No'},function() end)
assert(series_rows[#series_rows-1][1]=='Bookmarks:' and series_rows[#series_rows-1].callback)
assert(series_rows[#series_rows][1]=='Status:' and series_rows[#series_rows][2]=='In progress')
local work={id='123',title='Story',comments='3',bookmarks='4'}
local calls={}
local html,actions=View.html(work,{{'Story'}},{stat_action=function(kind,w) calls[#calls+1]={kind,w} end})
assert(html:find('3 Comments',1,true) and html:find('4 Bookmarks',1,true))
for _,action in ipairs(actions) do action() end
assert(#calls==2 and calls[1][1]=='bookmarks' and calls[2][1]=='comments' and calls[1][2]==work)
local zero_html,zero_actions=View.html({id='9',title='Empty',comments='0',bookmarks='0'},{{'Empty'}},
    {stat_action=function() error('zero counts must not be clickable') end})
assert(#zero_actions==0 and zero_html:find('<b>0</b> Bookmarks',1,true) and zero_html:find('<b>0</b> Comments',1,true))
local zero_series,zero_series_actions=View.seriesHTML({id=42,title='Empty',bookmarks='0'},function() error('zero bookmarks') end)
assert(zero_series:find('0 Bookmarks',1,true) and #zero_series_actions==0)
local zero_rows=View.seriesRows({id=42,bookmarks='0'},function() error('zero bookmarks') end)
assert(not zero_rows[#zero_rows].callback)
local plain,no_actions=View.html({title='Unavailable',comments='2',bookmarks='3'},{{'Unavailable'}},
    {stat_action=function() error('missing ID must not be clickable') end})
assert(#no_actions==0 and plain:find('Comments',1,true))
package.loaded['ao3lib.ao3.network']={defer=function() return false end,run=function(fn) fn() end,wrap=function(fn) return fn end}
local series_request
local fakeClient={getSeriesBookmarks=function(_,id,page) series_request={id,page};return {success=true,bookmarks={}} end,
    getWorkBookmarks=function(_,_,page)
    return {success=true,bookmarks=page==1 and {
        {bookmarker='Reader',username='reader',pseud='Reader',date='25 Nov 2026',status='rec',tags={'Favorite'},collections={'Collection'},collection_ids={'example'},notes='Lovely <story>\n\nAgain'},
        {tags={},collections={}}} or {{bookmarker='Second',tags={},collections={}}},next_page=page==1 and 2 or nil}
end}
package.loaded['ao3lib.ao3.client']=fakeClient
package.loaded['ao3lib.ui.work_bookmarks']=nil
local BookmarkView=require('ao3lib.ui.work_bookmarks')
local Context
package.loaded['ao3lib.ui.comment_view']={show=function(_,context) Context=context;return context end}
local opened={}
local owner={menu_stack={},showUserInfo=function(_,user,pseud) opened.author={user,pseud} end,
    getWorksFromCollection=function(_,id) opened.collection=id;return true,{},'next' end,
    onShowFanficBrowser=function(_,works,next_page,title) opened.result={works,next_page,title} end}
BookmarkView.show(owner,work)
local page=Context.fetch(1)
local formatted,links=Context.html(Context.prepare(page)[1])
assert(formatted:find('Reader',1,true) and formatted:find('Recommendation',1,true)
    and formatted:find('Lovely &lt;story&gt;</p><p>Again',1,true) and formatted:find('Bookmark</h2>',1,true))
assert(Context.hide_actions and Context.page_label({page=2})=='Page 2'
    and Context.page_label({page=2,total_pages=10})=='Page 2 of 10')
assert(#links==2 and formatted:find('ao3%-comment:1') and formatted:find('ao3%-comment:2'))
Context.link_action(links[1]);assert(opened.author[1]=='reader' and opened.author[2]=='Reader')
package.loaded['ao3lib.ui.collection_list']={open=function(_,id,name) opened.collection={id,name} end}
Context.link_action(links[2]);assert(opened.collection[1]=='example' and opened.collection[2]=='Collection')
BookmarkView.show(owner,{id=42,title='Series'},'series')
Context.fetch(3);assert(series_request[1]==42 and series_request[2]==3)
BookmarkView.show(owner,work)
package.loaded['ao3lib.ui.comment_view']=nil
local CommentView=require('ao3lib.ui.comment_view')
local rendered={}
Context.present=function(state,body) rendered[#rendered+1]={page=state.page,html=body} end
local state=CommentView.new(Context)
state:load(1);assert(state:hasNext() and rendered[#rendered].page==1)
state:next();assert(state.page==2 and rendered[#rendered].html:find('Second',1,true))
state:previous();assert(state.page==1 and rendered[#rendered].html:find('Reader',1,true))
print('PASS: work bookmark short blurbs, pagination, safe request, and clickable rendered statistics')
