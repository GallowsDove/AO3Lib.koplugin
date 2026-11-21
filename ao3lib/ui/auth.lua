-- Suspend the caller before any account submission, then continue it only
-- after an explicit successful login. No password is saved on disk.
local M = {}
local pending=false
function M.recover(client)
    if pending then return false end
    -- A fresh GET sends persistent remember-me cookies and accepts any new
    -- session cookie AO3 issues. Unavailability must never trigger a prompt.
    local status=client:GetSessionStatus()
    if not status.success then return false end
    if status.logged_in then return true end
    local co=coroutine.running()
    if not co then return false end
    pending=true
    local UI=require('ui/uimanager')
    local dialog,remember
    local finished=false
    local function finish(ok)
        if finished then return end
        finished=true;pending=false
        UI:close(dialog)
        UI:nextTick(function()
            local resumed,err=coroutine.resume(co,ok)
            if not resumed then require('logger').warn('AO3 login continuation failed:',err) end
        end)
    end
    dialog=require('ui/widget/multiinputdialog'):new{
        title='Sign in to continue',
        fields={{text='',hint='Username'},{text='',hint='Password',text_type='password'}},
        buttons={{{text='Cancel',id='close',callback=function() finish(false) end},
            {text='Login',callback=require('ao3lib.ao3.network').wrap(function()
                local fields=dialog:getFields()
                local result=client:startLoggedInSession(fields[1],fields[2],remember.checked)
                if result.success then finish(true)
                else UI:show(require('ui/widget/infomessage'):new{text=result.error}) end
            end)}}},
    }
    remember=require('ui/widget/checkbutton'):new{text='Keep me signed in',checked=true,parent=dialog}
    dialog:addWidget(remember)
    -- Physical Back follows the same cancellation path as the Cancel button.
    dialog.onClose=function() finish(false);return true end
    UI:show(dialog);dialog:onShowKeyboard()
    return coroutine.yield()
end
return M
