local UI=require('ui/uimanager')
local Buttons=require('ui/widget/buttondialog')
local Info=require('ui/widget/infomessage')
local Bookmarks=require('ao3lib.users.bookmarks')
local T=require('ffi/util').template
local _=require('gettext')
local M={}
function M.toggle(user,changed)
    local was=Bookmarks.contains(user.username)
    Bookmarks.set(user.username,user.pseud,not was)
    UI:show(Info:new{text=was and T(_("User: '%1' has been removed from your bookmarks."),user.username)
        or T(_("User: '%1' has been added to your bookmarks."),user.username)})
    if changed then changed() end
end
function M.show(user,owner,changed)
    local dialog
    dialog=Buttons:new{title=user.pseud~=user.username and (user.pseud..' ('..user.username..')') or user.username,buttons={
        {{text=Bookmarks.contains(user.username) and _('Unbookmark User') or _('Bookmark User'),callback=function()
            UI:close(dialog);M.toggle(user,changed)
        end}},
        {{text=_('Manage subscription'),callback=function()
            UI:close(dialog)
            require('ao3lib.ui.subscriptions').manage(owner,'User',user.username,user.pseud)
        end}},
        {{text=_('Manage AO3 mute'),callback=require('ao3lib.ao3.network').wrap(function()
            local result=require('ao3lib.ao3.client'):getMutedUsers()
            if not result.success then UI:show(Info:new{text=result.error});return end
            local muted=false
            for __,entry in ipairs(result.users) do
                if entry.name:lower()==user.username:lower() then muted=true;break end
            end
            require('ao3lib.ao3.mute_cache').remember(result)
            UI:close(dialog)
            require('ao3lib.ui.muted_users').change(user.username,not muted,changed)
        end)}},
        {{text=_('Cancel'),callback=function() UI:close(dialog) end}},
    }}
    UI:show(dialog)
    return dialog
end
function M.row(user,owner,text,changed)
    local function open() owner.fanfic:showUserInfo(user.username,user.pseud,owner.menuWidget) end
    return {text=text,callback=open,hold_callback=function() M.show(user,owner.fanfic,changed) end}
end
return M
