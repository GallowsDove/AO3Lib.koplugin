dofile('tests/test_network.lua')
local Browser=require('ao3lib.ui.user_browser')
local series={id=12,title='First <series>',fandoms={'Fandom','Other'},work_count=3,word_count='84,250',bookmark_count=42,
    author='Writer',author_username='account',author_pseud='Writer',characters={'Character'},tags={'Tag'},summary=string.rep('á',230)}
local more={id=34,title='Second series',fandoms={},work_count=2,word_count='12,345',author='Writer'}
local fetches,details={},{}
local client=require('ao3lib.ao3.client')
client.getUserSeries=function(_,username,pseud,page)
    assert(username=='Writer' and pseud=='Pseud');fetches[#fetches+1]=page
    return {success=true,series=page==1 and {series,more} or {},total_pages=1,total_items=2}
end
client.getWorksFromSeries=function(_,id)
    details[#details+1]=id
    return {success=true,works={series_info={notes='Complete notes',complete='No'}}}
end
local Context
package.loaded['ao3lib.ui.comment_view']={show=function(_,context) Context=context;return context end}
local owner={menu_stack={}}
Browser.Fanfic=owner;Browser.userData={username='Writer',pseud='Pseud'}
Browser:openUserSeriesList()
assert(Context.title=='Series: Pseud' and Context.hide_actions and Context.item_pages)
local subscriptions=require('ao3lib.ui.subscriptions')
local opened,managed
subscriptions.openSeries=function(_,id,title,count,known,options) opened={id,title,count,known,options} end
subscriptions.manage=function(_,kind,id,title) managed={kind,id,title} end
package.loaded['ao3lib.ui.series_actions']={show=function(_,item) managed={'Series',item.id,item.title} end}
local tag,bookmarks,author
package.loaded['ao3lib.ui.tag_actions']={show=function(_,kind,name) tag={kind,name} end}
package.loaded['ao3lib.ui.work_bookmarks']={show=function(_,item,kind) bookmarks={item,kind} end}
owner.showUserInfo=function(_,username,pseud) author={username,pseud} end
package.loaded['ao3lib.ui.comment_view']=nil
local View=require('ao3lib.ui.comment_view')
Context.network=function(fn) fn() end
Context.present=function(state,html,links) state.rendered=html;state.links=links end
local state=View.new(Context)
state:load(1)
assert(state.rendered:find('First &lt;series&gt;',1,true) and not state.rendered:find('Second series',1,true))
assert(state.rendered:find(string.rep('á',230),1,true) and state.rendered:find('Complete notes',1,true))
assert(state.rendered:find('42 Bookmarks',1,true) and state.rendered:find('In progress',1,true))
assert(Context.page_label(state)=='Page 1 of 2')
-- The links are emitted in title, author, fandoms, tags and bookmarks order.
Context.link_action(state.links[1]);assert(opened[1]==12 and opened[5].skip_overview)
Context.link_hold(state.links[1]);assert(managed[1]=='Series' and managed[2]==12)
Context.link_action(state.links[2]);assert(author[1]=='account' and author[2]=='Writer')
Context.link_action(state.links[3]);assert(tag[1]=='Fandom' and tag[2]=='Fandom')
Context.link_action(state.links[#state.links]);assert(bookmarks[1]==series and bookmarks[2]=='series')
state:next();assert(state.index==2 and state.rendered:find('Second',1,true) and #details==2)
state:previous();assert(state.index==1 and #details==2 and #fetches==1)
state:goToItem(2);assert(state.index==2)
state:goToItem(3);assert(state.index==2)
print('PASS: shared series detail layout; full metadata; individual pagination; actions and skip overview')
