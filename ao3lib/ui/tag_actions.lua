local UI=require('ui/uimanager')
local ButtonDialog=require('ui/widget/buttondialog')
local _=require('gettext')
local M={}

function M.show(plugin,kind,name)
    if not name or name=='' then return end
    local blacklist=require('ao3lib.library.blacklist')
    local exists=blacklist.contains(kind,name)
    local dialog
    local buttons={}
    if plugin and plugin.fetchFanficsByTag then
        buttons[#buttons+1]={{text=_('Browse works'),callback=function()
            UI:close(dialog)
            require('ao3lib.ao3.network').run(function()
                local success,works,nextPage=plugin:fetchFanficsByTag(name)
                if success then plugin:onShowFanficBrowser(works,nextPage,name) end
            end)
        end}}
    end
    buttons[#buttons+1]={{text=exists and _('Already on blacklist') or _('Add to blacklist'),enabled=not exists,
        callback=function()
            blacklist.add(kind,name);UI:close(dialog)
            UI:show(require('ui/widget/infomessage'):new{text=_('Added to blacklist: ')..name,timeout=2})
        end}}
    buttons[#buttons+1]={{text=_('Cancel'),callback=function() UI:close(dialog) end}}
    dialog=ButtonDialog:new{title=name,buttons=buttons};UI:show(dialog)
    return dialog
end

return M
