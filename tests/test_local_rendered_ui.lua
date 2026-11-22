dofile('tests/test_network.lua')
local Class={}
function Class:extend(fields) return setmetatable(fields,{__index=self}) end
function Class:new(fields)
    fields=setmetatable(fields or {},{__index=self})
    if fields.init then fields:init() end
    return fields
end
function Class:getSize() return {w=self.width or 600,h=self.height or 32} end
function Class:getHeight() return self:getSize().h end
for _,name in ipairs({'ui/geometry','ui/widget/container/framecontainer','ui/widget/verticalgroup',
    'ui/widget/container/centercontainer','ui/widget/titlebar','ui/widget/focusmanager',
    'ui/widget/button','ui/widget/horizontalgroup','ui/widget/horizontalspan','ui/gesturerange'}) do package.loaded[name]=Class end
local scroll
package.loaded['ui/widget/scrollhtmlwidget']={new=function(_,fields)
    fields.htmlbox_widget={dimen={x=10,y=20,w=500,h=600},ges_events={},
        getPosFromAbsPos=function(_,pos) if pos.x<10 then return end;return {x=pos.x-10,y=pos.y-20} end,
        getLinkByPosition=function(_,pos)
            if pos.x==1 then return {uri='ao3-action:1'} end
            if pos.x==2 then return {uri='ao3-action:2'} end
        end}
    fields.getCurrentRatio=function(self) return self.ratio or 0 end
    fields.scrollToRatio=function(self,ratio) self.ratio=ratio end
    scroll=fields;return fields
end}
local mirrored=false
package.loaded['ui/bidi']={mirroredUILayout=function() return mirrored end,
    flipDirectionIfMirroredUILayout=function(direction)
        if mirrored then return direction=='west' and 'east' or direction=='east' and 'west' or direction end
        return direction
    end}
package.loaded.device={hasKeys=function() return false end,
    isTouchDevice=function() return true end,
    screen={getWidth=function() return 600 end,getHeight=function() return 800 end,scaleBySize=function(_,n) return n end}}
package.loaded['ffi/blitbuffer']={COLOR_WHITE=0}
local UI=require('ui/uimanager')
UI.show=function() end
UI.close=function(_,window) if window.onCloseWidget then window:onCloseWidget() end end
UI.setDirty=function() end
local held
local selected,options,author,menus=nil,0,0,0
local context={plugin={menu_stack={},ui={menu={onShowMenu=function() menus=menus+1 end}}},
    works={{id='one',title='One',fandoms={'Fav fandom'}},{id='two',title='Two'}},summary_html=true,
    rows=function(work) return {{work.title,callback=function() selected=work.id end,hold_callback=function() held=work.id end},
        {'Author:','Writer',callback=function() author=author+1 end}} end,
    list=function() options=options+1 end,
}
local state=require('ao3lib.ui.work_view').show({},context)
local window=state.window
assert(not window.work_action_buttons and #window.layout[1]==1)
assert(window.view_options_button.text=='View options…')
window.view_options_button.callback();assert(options==1)
window.titlebar.left_icon_tap_callback();assert(menus==1)
assert(scroll.html_body:find('<h1><a',1,true))
scroll.html_link_tapped_callback{uri='ao3-action:1'};assert(selected=='one')
scroll.html_link_tapped_callback{uri='ao3-action:2'};assert(author==1)
local box=scroll.htmlbox_widget
assert(box.ges_events.HoldAO3Title[1].ges=='hold')
assert(box:onHoldAO3Title(nil,{pos={x=11,y=20}}) and held=='one')
held=nil
assert(not box:onHoldAO3Title(nil,{pos={x=12,y=20}}) and not held)
assert(not box:onHoldAO3Title(nil,{pos={x=0,y=20}}) and not held)
scroll.ratio=0.5
require('ao3lib.ao3.favorite_cache').remember{success=true,username='Writer',tags={{name='Fav fandom'}}}
assert(scroll.html_body:find('&#9733;',1,true) and scroll.ratio==0.5,
    'Asynchronous favorite highlights must preserve the current scroll position')
window=state.window
assert(window.ges_events.SwipeWork[1].ges=='swipe')
assert(not window:onSwipeWork(nil,{direction='north'}) and state.index==1)
assert(window:onSwipeWork(nil,{direction='west'}) and state.index==2)
scroll.html_link_tapped_callback{uri='ao3-action:1'};assert(selected=='two','Title actions must follow the current page')
assert(scroll.htmlbox_widget:onHoldAO3Title(nil,{pos={x=11,y=20}}) and held=='two')
assert(#context.plugin._ao3_navigation==1,'Changing works must replace the existing rendered page')
assert(state.window:onSwipeWork(nil,{direction='east'}) and state.index==1)
mirrored=true
assert(state.window:onSwipeWork(nil,{direction='east'}) and state.index==2)
mirrored=false
state.window:onClose();assert(state.closed and #context.plugin._ao3_navigation==0)
print('PASS: title action menu; only View options visible; author link; menu icon; page-specific actions; focus layout and navigation cleanup')

local local_height=scroll.height
context.list=nil
local online=require('ao3lib.ui.work_view').show({},context)
assert(not online.window.view_options_button and #online.window.layout==1)
assert(scroll.height==local_height+32,'Removing the view selector must reclaim its vertical space')
online.window:onClose()
print('PASS: browsing has no view selector and reclaims its height; downloaded filters retain View options')
