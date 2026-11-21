-- Account operations work on metadata, independently of a downloaded EPUB.
local UI=require('ui/uimanager')
local Buttons=require('ui/widget/buttondialog')
local Info=require('ui/widget/infomessage')
local Network=require('ao3lib.ao3.network')
local _=require('gettext')
local M={}
function M.buttons(work,close,owner)
    local Reader=require('ao3lib.ui.reader')
    local current=require('ao3lib.core.table').deepCopy(work)
    -- Browsing comments target the work. Reader menus still offer chapters.
    current.chapter_data=nil
    local session=setmetatable({current_fanfic=current,account_only=true,plugin_owner=owner},{__index=Reader})
    local rows=session:workManagementButtons(close)
    local intended_subscribe=not current.subscriptionID
    -- Never toggle based on a stale subscription ID from a cached work.
    rows[2][1].callback=Network.wrap(function()
        close()
        local Client=require('ao3lib.ao3.client')
        local state=Client:getSubscriptionTarget('Work',current.id)
        if not state.success then UI:show(Info:new{text=state.error});return end
        local result={success=true,subscription_id=state.subscription_id}
        if intended_subscribe and not state.subscription_id then
            result=Client:setWorkSubscription(current.id)
        elseif not intended_subscribe and state.subscription_id then
            result=Client:setWorkSubscription(current.id,state.subscription_id)
        end
        if not result.success then UI:show(Info:new{text=result.error});return end
        current.subscriptionID=result.subscription_id or false
        work.subscriptionID=current.subscriptionID
        session:saveAccountState({"subscriptionID"})
        UI:show(Info:new{text=current.subscriptionID and _("Subscribed to work.") or _("Unsubscribed from work.")})
    end)
    -- Retain account state in the browsing record for subsequent menu opens.
    local save=session.saveAccountState
    session.saveAccountState=function(self,fields)
        for __,key in ipairs(fields) do work[key]=current[key] end
        save(self,fields)
    end
    local menu={}
    session:addToMainMenu(menu)
    menu.AO3Lib_read_comments.callback=Network.wrap(function()
        require("ao3lib.ui.comments").show(owner,work)
    end)
    for __,key in ipairs({'AO3Lib_kudos_work','AO3Lib_read_comments','AO3Lib_comment_work'}) do
        local item=menu[key]
        rows[#rows+1]={{text=item.text,callback=function() close();item.callback() end}}
    end
    return rows
end
function M.show(work,owner)
    local dialog
    local rows=M.buttons(work,function() UI:close(dialog) end,owner)
    rows[#rows+1]={{text=_("Cancel"),callback=function() UI:close(dialog) end}}
    dialog=Buttons:new{title=work.title,buttons=rows}
    UI:show(dialog)
    return dialog
end
return M
