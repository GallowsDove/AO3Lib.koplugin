local UI=require('ui/uimanager')
local Network=require('ao3lib.ao3.network')
local ButtonDialog=require('ui/widget/buttondialog')
local InfoMessage=require('ui/widget/infomessage')
local InputDialog=require('ui/widget/inputdialog')
local _=require('gettext')
local M={}
local function report(result)
    if not result.success then UI:show(InfoMessage:new{text=result.error or _('Could not update muted users.')});return false end
    require('ao3lib.ao3.mute_cache').remember(result)
    return true
end
function M.change(name,muted,done)
    local dialog
    dialog=ButtonDialog:new{title=(muted and _('Mute user: ') or _('Unmute user: '))..name,buttons={{
        {text=_('Cancel'),callback=function() UI:close(dialog) end},
        {text=muted and _('Mute') or _('Unmute'),callback=Network.wrap(function()
            local result=require('ao3lib.ao3.client'):setMutedUser(name,muted)
            if report(result) then UI:close(dialog);if done then done() end end
        end)},
    }}}
    UI:show(dialog)
end
function M.show(owner)
    Network.run(function()
        local result=require('ao3lib.ao3.client'):getMutedUsers()
        if not report(result) then return end
        local menu=owner.menuWidget
        local render
        local function refresh()
            local updated=require('ao3lib.ao3.client'):getMutedUsers()
            if report(updated) then result=updated;menu:switchItemTable(nil,render());menu:updateItems() end
        end
        render=function()
            local rows={{text=_('Mute user…'),callback=function()
                local input
                input=InputDialog:new{title=_('AO3 username to mute'),input='',buttons={{
                    {text=_('Cancel'),callback=function() UI:close(input) end},
                    {text=_('Next'),callback=function()
                        local name=(input:getInputText() or ''):match('^%s*(.-)%s*$')
                        if name~='' then UI:close(input);M.change(name,true,refresh) end
                    end},
                }}}
                UI:show(input);input:onShowKeyboard()
            end}}
            for _,entry in ipairs(result.users) do
                local name=entry.name
                rows[#rows+1]={text=name,callback=function() M.change(name,false,refresh) end}
            end
            if #result.users==0 then rows[#rows+1]={text=_('No muted users.'),enabled=false} end
            return rows
        end
        menu:GoDownInMenu(_('Muted AO3 users'),render())
    end)
end
return M
