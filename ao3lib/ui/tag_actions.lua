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
            local Nav=require('ao3lib.ui.navigation')
            local identity=Nav.key('tag',name)
            if Nav.isCurrent(plugin,identity) then return end
            require('ao3lib.ao3.network').run(function()
                if Nav.isCurrent(plugin,identity) then return end
                local success,works,nextPage=plugin:fetchFanficsByTag(name)
                if success and not Nav.isCurrent(plugin,identity) then plugin:onShowFanficBrowser(works,nextPage,name,{identity=identity}) end
            end)
        end}}
    end
    if kind then
        buttons[#buttons+1]={{text=_('AO3 favorite…'),callback=function()
            UI:close(dialog)
            require('ao3lib.ao3.network').run(function()
                local client=require('ao3lib.ao3.client')
                local state=client:getFavoriteTagState(name)
                if not state.success then UI:show(require('ui/widget/infomessage'):new{text=state.error});return end
                local favorite=state.favorite_id~=nil
                local choice
                choice=ButtonDialog:new{title=name,buttons={
                    {{text=favorite and _('Remove AO3 favorite') or _('Add AO3 favorite'),callback=function()
                        UI:close(choice)
                        require('ao3lib.ao3.network').run(function()
                            local result=client:setFavoriteTag(name,not favorite)
                            if result.success then require('ao3lib.ao3.favorite_cache').changed(name,not favorite) end
                            UI:show(require('ui/widget/infomessage'):new{text=result.success
                                and (favorite and _('Removed from AO3 favorites.') or _('Added to AO3 favorites.'))
                                or result.error})
                        end)
                    end}},
                    {{text=_('Cancel'),callback=function() UI:close(choice) end}},
                }}
                UI:show(choice)
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
