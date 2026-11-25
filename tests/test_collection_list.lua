dofile('tests/test_network.lua')
local List=require('ao3lib.ui.collection_list')
local calls={}
local collection={id='my_collection',title='Collection <one>',author='Writer',authors={{name='Writer',username='account',pseud='Writer'}},
    type='Open, Moderated',summary='Full description\n\nSecond paragraph',tags={'Tag A','Tag B'},work_count=20,bookmark_count=3}
local html,actions=List.html(collection,{works=function() calls.works=true end,bookmarks=function() calls.bookmarks=true end,
    author=function() calls.author='account' end,tag=function(name) calls.tag=name end})
assert(html:find('Collection &lt;one&gt;',1,true) and html:find('Full description</p><p>Second paragraph',1,true))
assert(html:find('>20</a></b> works',1,true) and html:find('3 Bookmarks',1,true) and #actions==6)
actions[1].tap();actions[2].tap();actions[3].tap();actions[6].tap()
assert(calls.works and calls.bookmarks and calls.author=='account' and calls.tag=='Tag A')
local opened,held
local people={{name='Writer',username='account',pseud='Writer'},{name='Editor',username='editor',pseud='Editor'}}
local people_owner={showUserInfo=function(_,username) opened=username end}
package.loaded['ao3lib.ui.user_actions']={show=function(user) held=user.username end}
List.chooseAuthor(people_owner,{people[1]},false);assert(opened=='account')
List.chooseAuthor(people_owner,{people[1]},true);assert(held=='account')
local UI=require('ui/uimanager')
local previous_show=UI.show
local chooser
UI.show=function(_,dialog) chooser=dialog end
List.chooseAuthor(people_owner,people,false);chooser.buttons[2][1].callback();assert(opened=='editor')
List.chooseAuthor(people_owner,people,true);chooser.buttons[2][1].callback();assert(held=='editor')
UI.show=previous_show
local empty,empty_actions=List.html({id='empty',title='Empty',bookmark_count=0},{bookmarks=function() error('zero bookmarks') end})
assert(empty:find('0 Bookmarks',1,true) and #empty_actions==0)
local Context
package.loaded['ao3lib.ui.comment_view']={show=function(_,context) Context=context;return context end}
local owner={menu_stack={}}
local Browser=require('ao3lib.ui.user_browser')
Browser.Fanfic=owner;Browser.userData={username='Writer'}
Browser:openUserCollectionsList()
assert(Context.item_pages and Context.title=='Collections: Writer')
local fetched=0
require('ao3lib.ao3.client').getUserCollections=function(_,user,page)
    assert(user=='Writer' and page==1);fetched=fetched+1
    return {success=true,collections={collection,{id='next',title='Second'}},total_items=2,total_pages=1}
end
package.loaded['ao3lib.ui.comment_view']=nil
local View=require('ao3lib.ui.comment_view')
Context.network=function(fn) fn() end
Context.present=function(state,text) state.rendered=text end
local state=View.new(Context)
state:load(1);assert(state.rendered:find('Collection &lt;one&gt;',1,true) and Context.page_label(state)=='Page 1 of 2')
state:next();assert(state.index==2 and state.rendered:find('Second',1,true))
state:previous();assert(state.index==1 and fetched==1)
print('PASS: collection rendered details, individual pagination, clickable works/bookmarks/tags/authors')
