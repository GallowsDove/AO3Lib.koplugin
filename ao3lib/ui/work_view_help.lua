local UI=require('ui/uimanager')
local Config=require('ao3lib.core.config')
local ButtonDialog=require('ui/widget/buttondialog')
local _=require('gettext')
local M={}
function M.show()
    local dialog
    dialog=ButtonDialog:new{title=_('Work view controls')..'\n\n'..
        _('Tap the title to download or manage the work. Hold it for AO3 account actions.')..'\n\n'..
        _('Tap an author to open their profile. Hold an author for bookmark, subscription and mute actions.')..'\n\n'..
        _('Swipe left or right, or use the page buttons, to browse works. Tap a series to browse it; hold it to manage its subscription. Tap tags for more options.'),buttons={{
        {text=_('Show again later'),callback=function() UI:close(dialog) end},
        {text=_('Got it'),callback=function() Config:saveSetting('work_view_controls_seen',true);UI:close(dialog) end},
    }}}
    UI:show(dialog)
    return dialog
end
function M.showIfNeeded()
    if not Config:readSetting('work_view_controls_seen',false) then return M.show() end
end
return M
