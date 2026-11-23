-- Passive progress overlay: placement, input transparency and popup stacking.
package.path='./?.lua;'..package.path
local function stub(name,value) package.loaded[name]=value end
local stack,tasks={},{}
local shown,closed=0,0
local input={disable_double_tap=false,tap_interval_override=0.4}
local UI={_window_stack=stack}
function UI:getTopmostVisibleWidget() return stack[#stack] and stack[#stack].widget end
function UI:show(w,mode,rect,x,y)
    shown=shown+1;stack[#stack+1]={widget=w,x=x,y=y,rect=rect,mode=mode}
    if w.toast then input.disable_double_tap=true;input.tap_interval_override=nil end
end
function UI:close(w)
    closed=closed+1
    for i=#stack,1,-1 do if stack[i].widget==w then table.remove(stack,i) end end
end
function UI:nextTick(fn) tasks[#tasks+1]=fn end
local function drain() while #tasks>0 do table.remove(tasks,1)() end end
local function top() return stack[#stack] end
stub('ui/uimanager',UI)
local values={}
stub('ao3lib.core.config',{readSetting=function(_,key,default) if values[key]~=nil then return values[key] end;return default end})
stub('device',{input=input,screen={scaleBySize=function(_,n) return n end,getWidth=function() return 600 end,getHeight=function() return 800 end}})
stub('gettext',function(s) return s end)
stub('ffi/blitbuffer',{COLOR_WHITE=0,COLOR_BLACK=1,COLOR_LIGHT_GRAY=2})
stub('ui/font',{getFace=function(_,name,size) assert(size==10);return name end})
stub('ui/geometry',{new=function(_,v) return v end})
local Class={}
function Class:extend(v) return setmetatable(v or {},{__index=self}) end
function Class:new(v) v=setmetatable(v or {},{__index=self});if v.init then v:init() end;return v end
function Class:getSize() return {w=82,h=25} end
for _,name in ipairs({'ui/widget/container/widgetcontainer','ui/widget/container/framecontainer',
    'ui/widget/horizontalgroup','ui/widget/horizontalspan','ui/widget/textwidget','ui/widget/progresswidget'}) do stub(name,Class) end
local done,total,paused
local callback
local S={overlayState=function() return done,total,paused end,subscribe=function(fn) callback=fn end}
local O=require('ao3lib.ui.update_overlay')
local bookshelf={covers_fullscreen=true}
UI:show(bookshelf);O.attach(S)
assert(#stack==1)
done,total=2,100;callback()
assert(#stack==2 and top().widget.toast and top().widget.label=='2/100')
local frame=top().widget[1]
assert(frame.bordersize==0 and frame[1][1].width==40 and frame[1][1].bordersize==0)
assert(UI:getTopmostVisibleWidget()==bookshelf,'Passive overlay must not make Bookshelf appear covered')
assert(top().widget.fraction==0.02 and top().x==516 and top().y==2 and top().mode=='ui')
assert(input.disable_double_tap==false and input.tap_interval_override==0.4,'Overlay must preserve global input settings')
assert(top().widget:handleEvent({handler='onGesture'})==false,'Overlay must never consume input')
local initial=shown;callback();assert(shown==initial,'Identical progress must not cause a repaint')
done=3;callback();assert(top().widget.label=='3/100' and shown==initial+1)
values.update_progress_corner='top_left';O.refresh();assert(top().x==2)
local overlay=top().widget
local dialog={buttons={}}
UI:show(dialog);assert(top().widget==dialog and #stack==2,'Dialogs must hide the overlay')
done=4;callback();assert(top().widget==dialog)
local keyboard={modal=true};UI:show(keyboard);UI:close(keyboard);drain();assert(top().widget==dialog)
UI:close(dialog);drain();assert(top().widget.toast and top().widget.label=='4/100')
-- Unknown non-fullscreen popups also cover the indicator, without relying on widget type.
local popup={};UI:show(popup);assert(top().widget==popup);UI:close(popup);drain();assert(top().widget.toast)
paused=true;callback();assert(top().widget.label=='4/100')
values.update_progress_overlay=false;O.refresh();assert(#stack==1)
values.update_progress_overlay=true;O.refresh();assert(top().widget.toast)
done=nil;callback();assert(#stack==1,'Completed or stopped checks must remove the indicator')
assert(closed>0)
print('PASS: compact passive overlay; progress, pause, settings, unchanged repaint, nested dialogs and keyboard')
