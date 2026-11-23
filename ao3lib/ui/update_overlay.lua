-- A passive, compact progress indicator for detached AO3 update checks.
local UI=require('ui/uimanager')
local Config=require('ao3lib.core.config')
local Screen=require('device').screen
local Widget=require('ui/widget/container/widgetcontainer')
local Frame=require('ui/widget/container/framecontainer')
local Horizontal=require('ui/widget/horizontalgroup')
local Span=require('ui/widget/horizontalspan')
local Text=require('ui/widget/textwidget')
local Progress=require('ui/widget/progresswidget')
local Font=require('ui/font')
local Geom=require('ui/geometry')
local Blitbuffer=require('ffi/blitbuffer')
local _=require('gettext')
local M={}
local service,widget,signature,rect,scheduled
local installed=false

local Overlay=Widget:extend{toast=true}
function Overlay:init()
    local width=Screen:scaleBySize(40)
    local label=Text:new{text=self.label,face=Font:getFace('smallinfofont',10),padding=0}
    local bar=Progress:new{width=width,height=Screen:scaleBySize(4),percentage=self.fraction,
        margin_h=0,margin_v=0,radius=0,bordersize=0,fillcolor=Blitbuffer.COLOR_BLACK,bgcolor=Blitbuffer.COLOR_LIGHT_GRAY,
        allow_mirroring=false}
    self[1]=Frame:new{padding=Screen:scaleBySize(1),margin=0,bordersize=0,
        background=Blitbuffer.COLOR_WHITE,Horizontal:new{align='center',allow_mirroring=false,bar,Span:new{width=Screen:scaleBySize(2)},label}}
end
-- Toasts are painted above other windows but never receive input.
function Overlay:handleEvent(event)
    if event and event.handler=='onSetDimensions' and UI.nextTick then UI:nextTick(M.refresh) end
    return false
end

local function isDialog(w)
    if not w or w.toast or w.invisible then return false end
    return w.modal or w._input_widget or w.buttons or w.buttons_table or w.ok_callback
        or w.value_min or w.is_popout==true or w.dismiss_callback
end
local function covered()
    local top,count=nil,0
    for i=#(UI._window_stack or {}),1,-1 do
        local candidate=UI._window_stack[i].widget
        if candidate and candidate~=widget and not candidate.toast and not candidate.invisible then
            top=top or candidate;count=count+1
        end
    end
    return top and (not not isDialog(top) or (count>1 and not top.covers_fullscreen)) or false
end
local rawShow,rawClose,rawTop
local function remove()
    if widget then
        local old,oldrect=widget,rect
        widget,rect,signature=nil,nil,nil
        rawClose(UI,old,'ui',oldrect)
        if old.free then old:free() end
    end
end
function M.refresh()
    if not service then return end
    local done,total,paused=service.overlayState()
    if not Config:readSetting('update_progress_overlay',true) or done==nil or covered() then remove();return end
    local corner=Config:readSetting('update_progress_corner','top_right')
    if corner~='top_left' then corner='top_right' end
    done=math.max(0,tonumber(done) or 0);total=math.max(0,tonumber(total) or 0)
    local text=(paused and (_('Paused')..' ') or '')..string.format('%d/%d',done,total)
    local key=corner..'|'..text..'|'..done..'|'..total..'|'..Screen:getWidth()..'|'..Screen:getHeight()
    if widget and key==signature then return end
    remove()
    local fraction=total>0 and math.min(1,done/total) or 0
    local next_widget=Overlay:new{label=text,fraction=fraction}
    local size=next_widget:getSize()
    local margin=Screen:scaleBySize(2)
    local x=corner=='top_left' and margin or math.max(0,Screen:getWidth()-size.w-margin)
    local y=margin
    local next_rect=Geom:new{x=x,y=y,w=size.w,h=size.h}
    widget,rect,signature=next_widget,next_rect,key
    -- UIManager:show changes these global input settings even for toasts.
    -- This indicator must not change the active screen's gesture behavior.
    local input=require('device').input
    local double_tap=input and input.disable_double_tap
    local tap_interval=input and input.tap_interval_override
    rawShow(UI,widget,'ui',rect,x,y)
    if input then input.disable_double_tap=double_tap;input.tap_interval_override=tap_interval end
end
local function scheduleRefresh()
    if scheduled or not service or not UI.nextTick then return end
    scheduled=true
    UI:nextTick(function() scheduled=false;M.refresh() end)
end
local function install()
    if installed then return end
    installed=true
    rawShow,rawClose,rawTop=UI.show,UI.close,UI.getTopmostVisibleWidget
    if rawTop then
        UI.getTopmostVisibleWidget=function(self,...)
            local top=rawTop(self,...)
            if top~=widget or not widget then return top end
            -- Many KOReader and Bookshelf paths use this to decide whether
            -- their full-screen view is covered. This passive toast is not a
            -- covering view and must not suspend their normal behavior.
            for i=#(self._window_stack or {}),1,-1 do
                local candidate=self._window_stack[i].widget
                if candidate and candidate~=widget and not candidate.invisible then return candidate end
            end
        end
    end
    UI.show=function(self,w,...)
        if not widget and service.overlayState()==nil then return rawShow(self,w,...) end
        if w~=widget and isDialog(w) then remove() end
        local result=rawShow(self,w,...)
        if w~=widget then
            if covered() then remove() else scheduleRefresh() end
        end
        return result
    end
    UI.close=function(self,w,...)
        if not widget and service.overlayState()==nil then return rawClose(self,w,...) end
        local result=rawClose(self,w,...)
        if w~=widget then scheduleRefresh() end
        return result
    end
end
function M.attach(checks)
    if service==checks then return end
    service=checks
    install()
    checks.subscribe(M.refresh)
    M.refresh()
end
return M
