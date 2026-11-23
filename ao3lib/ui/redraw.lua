-- Defer replacement of a full-screen view until covering widgets close.
local UI=require('ui/uimanager')
local M={}

function M.defer(window,owner,callback)
    local found=false
    for _,entry in ipairs(UI._window_stack or {}) do
        local widget=entry.widget
        if widget==window then found=true
        elseif found and widget and not widget.toast and not widget.invisible then
            local watchers=widget._ao3_redraw_watchers
            if not watchers then
                watchers=setmetatable({},{__mode='k'})
                widget._ao3_redraw_watchers=watchers
                local close=widget.onCloseWidget
                widget.onCloseWidget=function(dialog,...)
                    local result
                    if close then result=close(dialog,...) end
                    UI:nextTick(function()
                        for target,notify in pairs(watchers) do notify(target) end
                    end)
                    return result
                end
            end
            watchers[owner]=callback
            return true
        end
    end
    return false
end
return M
