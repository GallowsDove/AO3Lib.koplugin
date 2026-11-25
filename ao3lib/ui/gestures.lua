-- Relay KOReader's configured touch zones through AO3's top-level windows.
local UI=require('ui/uimanager')
local M={}
local active=0
local broadcasting=0
local suspended=0
local function hostFor(owner)
    local host=owner and owner.ui
    if type(host)=='table' and type(host.handleEvent)=='function' then return host end
end
local function isTop(window)
    if not UI._window_stack then return true end
    -- KOReader shows the virtual keyboard as a separate window above its
    -- input dialog. Taps outside the keyboard must still reach that dialog.
    local keyboard=window._input_widget and window._input_widget.keyboard
    for i=#UI._window_stack,1,-1 do
        local candidate=UI._window_stack[i].widget
        if candidate and not candidate.toast and candidate~=keyboard then return candidate==window end
    end
    return false
end
local function zoneLists(host)
    local result={}
    if host._ordered_touch_zones then result[#result+1]={zones=host._ordered_touch_zones,root=true} end
    for _,child in ipairs(host) do
        if child~=host.file_chooser and type(child)=='table' and child._ordered_touch_zones then
            result[#result+1]={zones=child._ordered_touch_zones}
        end
    end
    return result
end
local function configured(host,id)
    local settings=host.gestures and host.gestures.gestures or {}
    if settings[id]~=nil then return true end
    local base=id:match('^(.-)_pan_release$') or id:match('^(.-)_pan$')
    if base and settings[base]~=nil then return true end
    if id=='multiswipe' and host.gestures and host.gestures.multiswipes_enabled then return true end
    return false
end
local function dispatchZone(zone,gesture)
    -- Dispatcher can broadcast events as well as send them. Mark broadcasts
    -- while a zone runs so the host does not receive them twice.
    local original=UI.broadcastEvent
    if original then UI.broadcastEvent=function(self,...)
        broadcasting=broadcasting+1
        local result={pcall(original,self,...)}
        broadcasting=broadcasting-1
        if not result[1] then error(result[2],0) end
        return unpack(result,2)
    end end
    active=active+1
    local ok,result=pcall(zone.handler,gesture)
    active=active-1
    if original then UI.broadcastEvent=original end
    if not ok then require('logger').warn('AO3Lib gesture handler failed:',result) end
    return ok and result and true or false
end
local function tryZones(host,gesture,user_first)
    if not gesture then return false end
    for _,list in ipairs(zoneLists(host)) do
        for _,zone in ipairs(list.zones) do
            local id=zone.def and zone.def.id
            if type(id)=='string' then
                local is_configured=configured(host,id)
                local live_light=id:match('^livelight_')~=nil
                local system_menu=not list.root and (id:match('^filemanager_') or id:match('^readermenu_'))
                -- AO3 has its own header controls; a missed tap should not
                -- activate the FileManager's large default menu tap zone.
                -- Explicitly configured gestures and menu swipes still work.
                local menu_tap=id=='filemanager_tap' or id=='filemanager_ext_tap'
                    or id=='readermenu_tap' or id=='readermenu_ext_tap'
                local allowed=user_first and (is_configured or live_light) or
                    (not user_first and not is_configured and not live_light and system_menu and not menu_tap)
                if allowed and zone.gs_range and zone.gs_range:match(gesture) and dispatchZone(zone,gesture) then return true end
            end
        end
    end
    return false
end
local neverForward={onClose=true,onCloseWidget=true,onShow=true,onFlushSettings=true}
local function forward(host,event,window)
    if not host or host==window or neverForward[event.handler] or broadcasting>0 then return false end
    local saved=rawget(host,'onClose')
    if event.handler~='onExit' and event.handler~='onRestart' then host.onClose=function() return true end end
    local ok,result=pcall(host.handleEvent,host,event)
    host.onClose=saved
    if not ok then require('logger').warn('AO3Lib gesture action failed:',result) end
    return ok and result and true or false
end
function M.attach(owner,window)
    if not window or window._ao3_gesture_owner or type(window.handleEvent)~='function' then return window end
    window._ao3_gesture_owner=owner
    local base=window.handleEvent
    window.handleEvent=function(self,event)
        local host=hostFor(self._ao3_gesture_owner)
        -- KOReader sends unhandled gestures to active windows underneath the
        -- top window. Those AO3 screens must never react to a tap intended
        -- for a child screen or dialog.
        if not isTop(self) then
            if event.handler=='onGesture' then return true end
            return base(self,event)
        end
        if not host then return base(self,event) end
        if active>0 and event.handler~='onGesture' then
            if broadcasting>0 then return base(self,event) end
            if forward(host,event,self) then return true end
            return base(self,event)
        end
        if event.handler=='onGesture' then
            local device=require('device')
            if device.screen_saver_lock then return base(self,event) end
            local gesture=event.args and event.args[1]
            if tryZones(host,gesture,true) then return true end
            if base(self,event) then return true end
            return tryZones(host,gesture,false)
        end
        return base(self,event)
    end
    return window
end
function M.suspend(callback)
    suspended=suspended+1
    local result={pcall(callback)}
    suspended=suspended-1
    if not result[1] then error(result[2],0) end
    return unpack(result,2)
end

-- Attach temporary AO3 dialogs too, but leave KOReader menus and any windows
-- opened by a KOReader gesture under KOReader's own event handling.
function M.installDialogs()
    if UI._ao3_gesture_show then return end
    local show=UI.show
    UI._ao3_gesture_show=show
    UI.show=function(self,window,...)
        if active==0 and suspended==0 and window and not window.toast
                and (window.buttons or window.ok_callback or window._input_widget or window.value_min) then
            local top=self.getTopmostVisibleWidget and self:getTopmostVisibleWidget()
            if top and top.toast and self._window_stack then
                for i=#self._window_stack,1,-1 do
                    local candidate=self._window_stack[i].widget
                    if candidate and not candidate.toast and not candidate.invisible then top=candidate;break end
                end
            end
            local owner=top and top._ao3_gesture_owner
            local host=hostFor(owner)
            if owner and host and window~=host and window~=host.menu then M.attach(owner,window) end
        end
        return show(self,window,...)
    end
end
return M
