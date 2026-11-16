-- Exercise completion with KOReader's actual notification timer/close handlers.
dofile('tests/test_reader_tracking.lua')
local Notification=package.loaded['ui/widget/notification']
local UI=package.loaded['ui/uimanager']
local Class={extend=function(_,fields) return fields end}
for _,name in ipairs({'ffi/blitbuffer','ui/widget/container/centercontainer',
    'ui/widget/container/framecontainer','ui/geometry','ui/gesturerange',
    'ui/widget/rectspan','ui/widget/textwidget','ui/widget/verticalgroup'}) do
    package.loaded[name]={}
end
package.loaded.device={screen={},input={}}
package.loaded['ui/font']={getFace=function() return {} end}
package.loaded['ui/size']={margin={default=1},padding={default=1}}
package.loaded['ui/widget/container/inputcontainer']=Class
package.loaded['ui/time']={s=function(seconds) return seconds end}
package.loaded.gettext=function(s) return s end
local Native=dofile('../koreader/frontend/ui/widget/notification.lua')
Notification.onShow=Native.onShow
Notification.onCloseWidget=Native.onCloseWidget
Notification._cleanShownStack=Native._cleanShownStack
Notification._past_messages={}
local now,visible,timers,repaints,closed=0,{}, {},0,0
function UI:getTime() return now end
function UI:setDirty(widget,refresh)
    if type(refresh)=='function' then refresh() end
    if widget==nil and refresh=='ui' then repaints=repaints+1 end
end
function UI:scheduleIn(delay,callback) timers[callback]=now+delay end
function UI:unschedule(callback) timers[callback]=nil end
function UI:show(widget)
    visible[widget]=true
    widget.frame={dimen={x=0,y=0,w=100,h=20}}
    widget:onShow()
end
function UI:close(widget)
    assert(visible[widget], 'Closed a stale notification twice')
    visible[widget]=nil;closed=closed+1
    widget:onCloseWidget()
end
local function advance(seconds)
    now=now+seconds
    for callback,due in pairs(timers) do
        if due<=now then timers[callback]=nil;callback() end
    end
end
local Reader=require('fanfic_reader')
Reader.current_fanfic={id='2',chapter_data={{name='Last',read=false}}}
Reader:onFinishChapter(1)
local toast=next(visible)
assert(toast and toast.text=='Finished chapter: Last' and toast.timeout==2)
Reader:onFinishChapter(1)
advance(1.9)
assert(visible[toast] and closed==0)
advance(0.1)
assert(not next(visible) and not next(timers) and closed==1 and repaints==1,
    'Chapter toast must disappear and repaint without any page or input event')
Reader.current_fanfic={id='3',title='Imported work',read=false}
Reader:onFinishSingleChapterWork()
assert(next(visible).text=='Finished work: Imported work')
Reader:onFinishSingleChapterWork()
advance(2)
assert(not next(visible) and closed==2 and repaints==2)
Reader.current_fanfic.chapter_data={{name='Another',read=false}}
Reader:onFinishChapter(1)
toast=next(visible)
UI:close(toast) -- Input can dismiss it before expiry.
assert(not next(timers), 'Early dismissal must cancel the expiry callback')
advance(3)
assert(closed==3 and repaints==3)
print('PASS: native two-second notification expiry; chapter/work completion; repaint without input; duplicate suppression; early dismissal cancels timer')
