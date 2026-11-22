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
function M.row(user,owner,text,changed)
    local function open() owner.fanfic:showUserInfo(user.username,user.pseud,owner.menuWidget) end
    return {text=text,callback=open,hold_callback=function()
        local dialog
        dialog=Buttons:new{title=text,buttons={{
            {text=_('View user profile'),callback=function() UI:close(dialog);open() end},
            {text=Bookmarks.contains(user.username) and _('Unbookmark User') or _('Bookmark User'),callback=function()
                UI:close(dialog);M.toggle(user,changed)
            end},
        }}}
        UI:show(dialog)
    end}
end
return M
