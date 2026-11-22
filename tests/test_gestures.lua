package.path='./?.lua;'..package.path
local stack={}
local UI={_window_stack=stack}
function UI:getTopmostVisibleWidget() return stack[#stack] and stack[#stack].widget end
function UI:show(w) stack[#stack+1]={widget=w} end
function UI:broadcastEvent(event)
    for i=#stack,1,-1 do stack[i].widget:handleEvent(event) end
end
package.loaded['ui/uimanager']=UI
package.loaded.device={screen_saver_lock=false}
package.loaded.logger={warn=function(_,err) error(tostring(err)) end}
local G=require('ao3lib.ui.gestures')
local matches,host_calls,base_calls={}, {},{}
local host={gestures={gestures={edge=true,corner=true,broadcast=true}},file_chooser={},menu={}}
local function zone(id,fn)
    return {def={id=id},gs_range={match=function(_,event) return event.id==id end},handler=fn}
end
function host:handleEvent(event)
    host_calls[#host_calls+1]=event.handler
    if event.handler=='onCloseWidget' then error('Must not forward lifecycle') end
    return true
end
host._ordered_touch_zones={
    zone('edge',function()
        matches[#matches+1]='edge'
        local top=UI:getTopmostVisibleWidget()
        assert(top:handleEvent{handler='onIncreaseFlIntensity'})
        return true
    end),
    zone('corner',function() matches[#matches+1]='corner';return true end),
    zone('broadcast',function()
        UI:broadcastEvent{handler='onToggleNightMode'}
        return true
    end),
    zone('filemanager_swipe',function() error('Must not page hidden file browser') end),
}
host[1]={_ordered_touch_zones={zone('filemanager_tap',function() matches[#matches+1]='menu';return true end)}}
local owner={ui=host}
local function window()
    return {handleEvent=function(_,event)
        base_calls[#base_calls+1]=event.handler
        return event.handler=='onGesture' and event.args[1].id=='local'
    end}
end
local screen=window();G.attach(owner,screen);G.installDialogs();UI:show(host);UI:show(screen)
assert(screen:handleEvent{handler='onGesture',args={{id='edge',ges='swipe'}}})
assert(matches[1]=='edge' and host_calls[1]=='onIncreaseFlIntensity' and #base_calls==0)
assert(screen:handleEvent{handler='onGesture',args={{id='broadcast',ges='swipe'}}})
assert(host_calls[2]=='onToggleNightMode' and #host_calls==2,'Broadcast action must reach the host exactly once')
assert(screen:handleEvent{handler='onGesture',args={{id='local',ges='swipe'}}})
assert(screen:handleEvent{handler='onGesture',args={{id='filemanager_tap',ges='tap'}}})
assert(matches[#matches]=='menu')
assert(not screen:handleEvent{handler='onGesture',args={{id='filemanager_swipe',ges='swipe'}}})
screen:handleEvent{handler='onCloseWidget'};assert(#host_calls==2)
local dialog=window();dialog.buttons={};UI:show(dialog)
assert(dialog._ao3_gesture_owner==owner)
assert(dialog:handleEvent{handler='onGesture',args={{id='corner',ges='tap'}}})
assert(matches[#matches]=='corner')
local builtin=window();builtin.buttons={}
G.suspend(function() UI:show(builtin) end)
assert(not builtin._ao3_gesture_owner)
print('PASS: configured gestures precede AO3 controls, host actions forward, menus and dialogs, hidden file browser and lifecycle protected')
