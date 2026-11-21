-- Keep review windows awake without changing the user's power settings.
local M={}
local owners=0
local previous_pause, share, standby_ui
function M.acquire()
    if owners==0 then
        local ok,value=pcall(require,'pluginshare')
        share=ok and value or nil
        if share then previous_pause=share.pause_auto_suspend;share.pause_auto_suspend=true end
        local UI=require('ui/uimanager')
        if UI.preventStandby and UI.allowStandby then UI:preventStandby();standby_ui=UI end
    end
    owners=owners+1
    local released=false
    return function()
        if released then return end
        released=true;owners=owners-1
        if owners==0 then
            if share then share.pause_auto_suspend=previous_pause end
            if standby_ui then standby_ui:allowStandby() end
            share,previous_pause,standby_ui=nil,nil,nil
        end
    end
end
return M
