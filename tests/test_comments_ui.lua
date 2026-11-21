dofile('tests/test_network.lua')
local Class={}
function Class:extend(fields) return setmetatable(fields,{__index=self}) end
function Class:new(fields)
    fields=setmetatable(fields or {},{__index=self})
    if fields.width then assert(fields.width>0,'Widget width must be positive') end
    if fields.height then assert(fields.height>0,'Widget height must be positive') end
    if fields.init then fields:init() end
    return fields
end
function Class:getSize() return {w=self.width or 240,h=self.height or 32} end
function Class:getHeight() return self:getSize().h end
for _,name in ipairs({'ui/geometry','ui/widget/container/framecontainer','ui/widget/verticalgroup',
    'ui/widget/container/centercontainer','ui/widget/titlebar','ui/widget/focusmanager',
    'ui/widget/button','ui/widget/horizontalgroup'}) do package.loaded[name]=Class end
local can_scroll_down,can_scroll_up=false,false
package.loaded['ui/widget/scrollhtmlwidget']={new=function(_,fields)
    assert(fields.width>0 and fields.height>0)
    fields.key_events={ScrollDown={},ScrollUp={}}
    fields.onScrollDown=function() return can_scroll_down end
    fields.onScrollUp=function() return can_scroll_up end
    return fields
end}
package.loaded.device={hasKeys=function() return true end,input={group={PgFwd='PageForward',PgBack='PageBack'}},
    screen={getWidth=function() return 240 end,getHeight=function() return 600 end,scaleBySize=function(_,n) return n end}}
package.loaded['ffi/blitbuffer']={COLOR_WHITE=0}
local UI=require('ui/uimanager')
UI.setDirty=function() end
local shown,closed
UI.show=function(_,w) shown=w end
UI.close=function(_,w) closed=w;if w.onCloseWidget then w:onCloseWidget() end end
local Client=require('ao3lib.ao3.client')
local Comments=require('ao3lib.ui.comments')
local work={id='12',title='A story',chapter_data={{id='34',name='First chapter'},{id='35',name='Second chapter'}}}
local requests,posts={},{}
local fail,post_fail=false,false
local comment_body=string.rep('Very long comment á 👀 ',1000)..'\n\n<script>literal markup</script>'
Client.getComments=function(_,work_id,chapter,page,thread)
    requests[#requests+1]={work=work_id,chapter=chapter,page=page,thread=thread}
    if fail then return {success=false,error='Maintenance'} end
    local comments=page==1 and {{id='56',heading='Reader · Today',author='Reader',username='Reader',pseud='Reading',date='Sat 21 Nov 2026 09:22PM UTC',text=comment_body,can_reply=true,depth=0},
        {id='60',heading='Reply author',text='Reply in the same conversation',can_reply=true,depth=1},
        {id='57',heading='Deleted comment',text='(Deleted)',can_reply=false,depth=0}}
        or {{id='80',heading='Another reader',text='Second AO3 batch',can_reply=true}}
    return {success=true,comments=comments,next_page=page==1 and 2 or nil}
end
Client.commentOnWork=function(_,content,id,chapter,parent)
    posts[#posts+1]={text=content,id=id,chapter=chapter,parent=parent}
    return post_fail and {success=false,error='Try later'} or {success=true,comment_id='99'}
end
local profile
local owner={menu_stack={},showUserInfo=function(_,user,pseud) profile={user,pseud} end}
local state=Comments.show(owner,work)
assert(#requests==1 and state:current().id=='56')
assert(state.window.scroll.html_body:find('Very long comment',1,true))
assert(not state.window.scroll.html_body:find('(Deleted)',1,true),'Only one thread may render at a time')
assert(state.window.scroll.html_body:find('&lt;script&gt;',1,true) and not state.window.scroll.html_body:find('<script>',1,true))
assert(state.window.page_buttons[2].text=='Thread 1/2 · Page 1')
assert(state.window.scroll.html_body:find('Reply in the same conversation',1,true))
assert(state.window.scroll.html_body:find('21 Nov 2026 · 21:22 UTC',1,true))
state.window.scroll.html_link_tapped_callback{uri='ao3-comment:1'}
assert(profile[1]=='Reader' and profile[2]=='Reading')
-- Replies within a thread retain their own reply targets.
state.window.scroll.html_link_tapped_callback{uri='ao3-comment:3'}
shown.input='Nested reply';shown.buttons[1][2].callback()
assert(posts[#posts].parent=='60')
local fetched=#requests
assert(not state.window.scroll.key_events.ScrollDown and state.window.key_events.NextComment)
can_scroll_down=true;state.window:onNextComment();assert(state.index==1)
can_scroll_down=false;state.window:onNextComment();assert(state.index==2 and #requests==fetched)
assert(state.window.scroll.html_body:find('(Deleted)',1,true) and not state.window.action_buttons[2].enabled)
state.window.page_buttons[3].callback();assert(state.page==2 and state.index==1 and #requests==fetched+1)
assert(state.window.scroll.html_body:find('Second AO3 batch',1,true))
state.window.page_buttons[1].callback();assert(state.page==1 and state.index==2 and #requests==fetched+1)
state:next();assert(state.page==2 and #requests==fetched+1,'Revisiting a fetched batch must use its cache')
state:previous();state:previous();assert(state:current().id=='56')
-- Reply directly from the reading page, retaining text on failure.
state.window.action_buttons[2].callback()
local composer=shown
assert(not composer.buttons[2], 'Replies stay attached to the original comment')
composer.input='A reply';post_fail=true
composer.buttons[1][2].callback()
assert(posts[#posts].parent=='56' and composer.input=='A reply' and shown.text=='Try later' and closed~=composer)
post_fail=false;composer.buttons[1][2].callback()
assert(state:current().id=='56' and not state.closed)
-- More opens a nested thread, preserving the parent's reading position.
state.window.action_buttons[3].callback();shown.buttons[1][1].callback()
assert(requests[#requests].thread=='56')
shown:onCloseWithKey();assert(not state.closed and #owner._ao3_navigation==1)
-- Failed refreshes keep the displayed comment. Chapter selection resets
-- pagination only after a successful fetch.
local previous=state.window
fail=true;state:refresh();assert(state.window==previous and shown.text=='Maintenance')
fail=false
state.window.action_buttons[3].callback();shown.buttons[3][1].callback()
shown.buttons[2][1].callback()
assert(state.chapter=='34' and state.page==1 and state.index==1)
state.window.action_buttons[1].callback();composer=shown
assert(composer.description:find('Posting to: First chapter',1,true))
composer.input='Chapter comment'
composer.buttons[2][1].callback()
assert(shown.title=='Post comment on')
shown.buttons[3][1].callback();composer=shown
assert(composer.input=='Chapter comment' and composer.description:find('Posting to: Second chapter',1,true))
composer.buttons[1][2].callback()
assert(posts[#posts].chapter=='35' and not posts[#posts].parent)
-- Closing preserves drafts, whitespace never submits, and cancelling while
-- Wi-Fi is pending cannot later submit a hidden composer.
composer=Comments.compose(owner,work)
composer.input='Unsaved draft';composer.buttons[1][1].callback()
composer=Comments.compose(owner,work);assert(composer.input=='Unsaved draft')
local count=#posts
composer.input='  ';composer.buttons[1][2].callback();assert(#posts==count)
local Network=require('ao3lib.ao3.network');local run=Network.run
local pending
Network.run=function(fn) assert(not pending);pending=fn end
composer.input='Deferred';composer.buttons[1][2].callback();composer.buttons[1][2].callback()
composer.buttons[1][1].callback();pending();pending=nil
assert(#posts==count)
Network.run=run
-- Browsing results may lack chapter metadata. Fetch it only when the
-- composer asks for chapter selection, while retaining the typed draft.
local metadata_fetches=0
Client.getWorkMetadata=function(_,id)
    assert(id=='12');metadata_fetches=metadata_fetches+1
    return {success=true,work_metadata={chapterData={work.chapter_data[1],work.chapter_data[2],{id="36",name="Third chapter"}}}}
end
composer=Comments.compose(owner,{id='12',title='A story'})
assert(composer.description:find('Posting to: Latest posted chapter',1,true))
composer.input='Pick a chapter';composer.buttons[2][1].callback()
assert(metadata_fetches==1 and #shown.buttons==5, 'Metadata chapterData must populate all three chapter choices')
shown.buttons[2][1].callback();composer=shown
assert(composer.input=='Pick a chapter' and composer.description:find('First chapter',1,true))
composer.buttons[1][1].callback()
-- Once Back closes the reader, late navigation cannot fetch or display data.
state.window:onCloseWithKey()
local before=#requests;state:next();state:refresh();assert(#requests==before and state.closed)
print('PASS: rendered comment threads; long text; narrow widths; lazy batches/cache; hardware scrolling; threads/Back; chapter scope; failures; composer drafts and cancellation')
