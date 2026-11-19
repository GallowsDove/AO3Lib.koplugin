dofile('tests/test_network.lua')
local WorkView=require('ao3lib.ui.work_view')
local Browser=require('ao3lib.ui.work_browser')
local work={id='formatted',title='<Story & title>',author='Writer',rating='Explicit',category='M/M',
    warnings={'No Archive Warnings Apply'},chapters='2/?',words='12345',language='English',
    fandoms={'Fandom'},series={{id=12,title='Series',position='2'}},
    summary='First paragraph.\n\nSecond paragraph.\n<script>alert("x")</script>',tags={'First tag','Second tag'}}
local authors,series=0,0
Browser.showAuthorInfoCallback=function() authors=authors+1 end
Browser.Fanfic={getWorksFromSeries=function() series=series+1;return true,{} end,onShowFanficBrowser=function() end}
local function rows(w) return Browser:generateTable({}, {w},function() end,function() end) end
local html,actions=WorkView.html(work,rows(work))
assert(html:find('&lt;Story &amp; title&gt;',1,true) and not html:find('<script>',1,true))
assert(html:find('</p><p>Second paragraph.',1,true))
assert(html:find('category-slash.png',1,true) and html:find('rating-explicit.png',1,true)
    and html:find('warning-no.png',1,true) and html:find('complete-no.png',1,true))
assert(html:find('#2 Series',1,true) and html:find('First tag</span>',1,true) and html:find('Second tag</span>',1,true))
assert(html:find('Work in progress',1,true)<html:find('Additional tags',1,true))
assert(#actions==3);actions[2]();actions[3]()
assert(authors==1 and series==1)
-- Paging is lazy; closed or superseded views cannot consume a network result.
local pending,fetches,presented=nil,0,{}
local ctx={works={work,total=3},rows=rows,
    network=function(fn) pending=fn end,
    fetch=function() fetches=fetches+1;return {{id='two',title='Two'},{id='three',title='Three'}} end,
    present=function(state,body,links) presented[#presented+1]={index=state.index,body=body,links=links} end}
local state=WorkView.new(ctx);state:render()
assert(#presented==1 and fetches==0)
state:next();assert(fetches==0 and pending)
pending=nil -- cancelled connection, retry must retain the same destination
state:next();pending();pending=nil
assert(state.index==2 and #state.works==3 and fetches==1)
state:next();assert(state.index==3 and not pending)
state:previous();assert(state.index==2)
state.closed=true;local count=#presented
state:next();state:previous();state:render();assert(#presented==count)
local late=WorkView.new(ctx);late:next();late.closed=true;pending();pending=nil
assert(fetches==1,'Closing before Wi-Fi connected still fetched a page')
local during=WorkView.new{works={work},rows=rows,network=function(fn) fn() end,
    fetch=function() state.closed=true;return {{title='Stale'}} end,present=function() error('Rendered a stale result') end}
state=during;during:next();assert(during.index==1 and #during.works==1)
-- A failed fetch retains the current page and can be retried.
local fail=true
local retry=WorkView.new{works={work},rows=rows,network=function(fn) fn() end,
    fetch=function() if fail then error('failed') end;return {{title='Retry'}} end,present=function() end}
assert(not pcall(function() retry:next() end) and not retry.loading and retry.index==1)
fail=false;retry:next();assert(retry.index==2)
local empty=WorkView.new{works={},rows=rows,present=function(_,body) assert(body:find('No works found.',1,true)) end}
empty:render()
assert(WorkView.html({is_deleted=true},{ }):find('Deleted work',1,true))
-- Exercise the native view assembly with widget adapters, including header,
-- HTML resource base, footer actions, live switching, replacement and close.
local UI=package.loaded['ui/uimanager']
local visible={}
UI.show=function(_,window) visible[window]=true;if window.onShow then window:onShow() end end
UI.close=function(_,window) visible[window]=nil;if window.onCloseWidget then window:onCloseWidget() end end
UI.setDirty=function() end
local Class={}
function Class:extend(fields) return setmetatable(fields,{__index=self}) end
function Class:new(fields)
    fields=setmetatable(fields or {},{__index=self})
    if fields.init then fields:init() end
    return fields
end
function Class:getSize() return {w=self.width or 600,h=self.height or 90} end
function Class:getHeight() return 45 end
-- Drive the native InputContainer key dispatcher through a child-first widget
-- tree, so a scroller stealing PgFwd/PgBack would fail the navigation test.
local native=assert(io.open('../koreader/frontend/ui/widget/container/inputcontainer.lua'))
local source=native:read('*a');native:close()
local body=assert(source:match('function InputContainer:onKeyPress%(key%)\n(.-)\nend'))
local load=assert(loadstring('return function(self,key)\n'..body..'\nend'))
setfenv(load,setmetatable({Event={new=function(_,name,...)
    return {handler='on'..name,args={...}}
end}},{__index=_G}))
local nativeKey=load()
function Class:onKeyPress(key) if self.key_events then return nativeKey(self,key) end end
Class.onKeyRepeat=Class.onKeyPress
function Class:handleEvent(event)
    for _,child in ipairs(self) do
        if child.handleEvent and child:handleEvent(event) then return true end
    end
    if self[event.handler] then return self[event.handler](self,unpack(event.args)) end
end
local function press(window,name,repeatKey)
    local function contains(value)
        if type(value)=='string' then return value==name end
        for _,part in ipairs(value) do if contains(part) then return true end end
        return false
    end
    return window:handleEvent{handler=repeatKey and 'onKeyRepeat' or 'onKeyPress',
        args={{match=function(_,seq) return contains(seq) end}}}
end

for _,name in ipairs({'ui/geometry','ui/widget/container/framecontainer','ui/widget/verticalgroup',
    'ui/widget/container/centercontainer','ui/widget/titlebar','ui/widget/focusmanager',
    'ui/widget/button','ui/widget/horizontalgroup','ui/widget/horizontalspan'}) do package.loaded[name]=Class end
local scrollers={}
local innerScrolls=0
package.loaded['ui/widget/scrollhtmlwidget']={new=function(_,fields)
    local keys=package.loaded.device.input.group
    fields.key_events={ScrollDown={{keys.PgFwd}},ScrollUp={{keys.PgBack}}}
    fields.onScrollDown=function() innerScrolls=innerScrolls+1;return true end
    fields.onScrollUp=fields.onScrollDown
    scrollers[#scrollers+1]=fields
    return setmetatable(fields,{__index=Class})
end}
package.loaded['ui/bidi']={mirroredUILayout=function() return false end}
package.loaded.device={hasKeys=function() return true end,
    input={group={PgFwd={'LPgFwd','RPgFwd'},PgBack={'LPgBack','RPgBack'}}},screen={getWidth=function() return 600 end,getHeight=function() return 800 end,
    scaleBySize=function(_,n) return n end}}
package.loaded['ffi/blitbuffer']={COLOR_WHITE=0}
local Config=package.loaded["ao3lib.core.config"]
local formatted,fontSize=true,nil
Config.readSetting=function(_,key,default)
    if key=='formatted_work_view' then return formatted end
    if key=='work_view_font_size' then return fontSize or default end
    return default
end
Config.saveSetting=function(_,key,value)
    if key=='work_view_font_size' then fontSize=value else assert(key=='formatted_work_view');formatted=value end
end
local plugin={menu_stack={}}
local old=Browser:show({}, {work,{id='next',title='Next'},total=2},nil,
    function() end,function() end,function() authors=authors+1 end,plugin,'Test browser')
assert(old and old.window and visible[old.window] and old.index==1)
assert(scrollers[1].html_resource_directory:match('assets/$') and scrollers[1].height>0)
assert(scrollers[1].default_font_size==18,'Default text size must preserve the existing rendering')
scrollers[1].html_link_tapped_callback{uri='ao3-action:2'}
assert(authors==2)
assert(old.window.key_events.NextWork and old.window.key_events.PreviousWork)
assert(not scrollers[1].key_events.ScrollDown and not scrollers[1].key_events.ScrollUp)
assert(press(old.window,'RPgFwd') and old.index==2 and innerScrolls==0)
assert(press(old.window,'LPgBack') and old.index==1 and innerScrolls==0)
assert(press(old.window,'LPgFwd',true) and old.index==2 and innerScrolls==0)
assert(press(old.window,'RPgFwd') and old.index==2 and innerScrolls==0,'Last work must not scroll or wrap')
assert(press(old.window,'RPgBack') and old.index==1 and innerScrolls==0)
assert(press(old.window,'LPgBack') and old.index==1 and innerScrolls==0,'First work must not scroll or wrap')
scrollers[#scrollers]:onScrollDown() -- Touch scrolling remains available.
assert(innerScrolls==1)
old.window.page_buttons[4].callback()
assert(old.index==2 and not old.closed and visible[old.window])
assert(old.window~=nil and old.window==Browser.browse_window)
assert(#old.window.page_buttons==5 and #old.window.layout==1)
assert(old.window.page_buttons[1].icon=='chevron.first' and old.window.page_buttons[2].icon=='chevron.left')
assert(old.window.page_buttons[3].text=='Page 2 of 2' and old.window.page_buttons[3].text_font_face=='pgfont')
assert(old.window.page_buttons[4].icon=='chevron.right' and old.window.page_buttons[5].icon=='chevron.last')
for _,button in ipairs(old.window.page_buttons) do assert(button.bordersize==0) end
old.window.page_buttons[1].callback();assert(old.index==1)
old.window.page_buttons[5].callback();assert(old.index==2)
old.window.page_buttons[3].hold_input.callback('1');assert(old.index==1)
old.window.page_buttons[3].hold_input.callback('999');assert(old.index==1)
old.window.page_buttons[3].hold_input.callback('1.5');assert(old.index==1)
old.window.page_buttons[3].hold_input.callback('2');assert(old.index==2)
local new=old.window
old.window.titlebar.left_icon_tap_callback() -- Information list; preserve the current work.
assert(not formatted and old.closed and not visible[new])
assert(Browser.browse_window.show_page==2 and #Browser.browse_window.kv_pairs==30)
Browser.browse_window.title_bar_left_icon_tap_callback()
assert(formatted and Browser.browse_window~=new and visible[Browser.browse_window])
-- Page repainting and switching views must replace one navigation frame.
assert(#plugin._ao3_navigation==1)
local parentWindow=Browser.browse_window
local parentAuthor=Browser.showAuthorInfoCallback
local child=Browser:show({},{{id='nested',title='Nested work'},total=1},nil,
    function() end,function() end,function() end,plugin,'Nested works')
assert(#plugin._ao3_navigation==2 and visible[parentWindow])
local topMenus=0
plugin.ui={menu={onShowMenu=function() topMenus=topMenus+1 end}}
assert(press(child.window,'Menu') and topMenus==1, 'PocketBook Menu did not open KOReader top menu')
assert(not child.closed and visible[child.window] and #plugin._ao3_navigation==2)

assert(press(child.window,'Back') and child.closed and not visible[child.window])
assert(#plugin._ao3_navigation==1 and Browser.browse_window==parentWindow)
assert(Browser.showAuthorInfoCallback==parentAuthor and visible[parentWindow])
local homeChild=Browser:show({},{{id='home-key',title='Home key'},total=1},nil,
    function() end,function() end,function() end,plugin,'Home key test')
assert(press(homeChild.window,'Home') and homeChild.closed and not visible[homeChild.window])
assert(#plugin._ao3_navigation==1 and Browser.browse_window==parentWindow)

-- The settings picker persists the chosen base size, with Reset to 18.
local Menu=require('ao3lib.ui.menu')
local settings,spin
local read=Config.readSetting
Config.readSetting=function(self,key,default)
    if key=='AO3_domain' then return 'https://archiveofourown.org' end
    if key=='filename_template' then return '%I' end
    return read(self,key,default)
end
Menu.menuWidget={GoDownInMenu=function(_,_,items) settings=items end,
    switchItemTable=function(_,_,items) settings=items end,updateItems=function() end}
package.loaded['ui/widget/spinwidget']={new=function(_,args) spin=args;return args end}
Menu:onOpenSettings()
for _,item in ipairs(settings) do
    if item.text=='Formatted view text size: 18' then item.callback() end
end
assert(spin and spin.value==18 and spin.default_value==18 and spin.value_min==12 and spin.value_max==32)
spin.callback{value=22}
Browser.browse_window:reload()
assert(fontSize==22 and scrollers[#scrollers].default_font_size==22)
spin.callback{value=18}
Browser.browse_window:reload()
assert(scrollers[#scrollers].default_font_size==18)
fontSize='invalid';assert(WorkView.baseTextSize()==18)
fontSize=99;assert(WorkView.baseTextSize()==32)
fontSize=1;assert(WorkView.baseTextSize()==12)
fontSize=nil;Config.readSetting=read
package.loaded['ui/bidi'].mirroredUILayout=function() return true end
Browser.browse_window:reload()
assert(Browser.browse_window.page_buttons[1].icon=='chevron.last')
assert(Browser.browse_window.page_buttons[2].icon=='chevron.right')
assert(Browser.browse_window.page_buttons[4].icon=='chevron.left')
Browser.browse_window:onClose()
assert(not next(plugin.menu_stack))
assert(html:find('class="work-facts"',1,true) and html:find('class="chip"',1,true))
assert(not html:find('<b>Fandom:',1,true) and not html:find('<b>Rating:',1,true))
print('PASS: physical page keys/repeats navigate works through native dispatcher; touch scrolling preserved; formatted HTML; escaping; local AO3 square; live author/series actions; lazy paging; Wi-Fi cancellation; failures/retry; close safety; layout; persisted view switching and work position')

assert(not html:find('class="metrics"',1,true))
assert(html:find('<b>12345</b> words &#183; <b>2/?</b> chapters &#183; English',1,true))
assert(html:find('<div class="footnote"><p><b>0</b> Hits &#183; <b>0</b> Kudos',1,true))
