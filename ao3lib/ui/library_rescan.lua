local UI=require('ui/uimanager')
local InfoMessage=require('ui/widget/infomessage')
local _=require('gettext')
local M={}

function M.show()
    local roots={}
    local function add(path)
        if type(path)=='string' and path~='' then roots[#roots+1]=path end
    end
    add(require('ao3lib.core.config'):readSetting('fanfic_folder_path'))
    add(require('apps/filemanager/filemanagerutil').getHomeFolder())
    local cancelled,scan=false,nil
    local dialog=InfoMessage:new{text=_('Scanning downloaded AO3 EPUBs…\n\nTap or press Back to cancel.'),
        dismiss_callback=function()
            cancelled=true
            if scan and scan.cancel then scan.cancel() end
        end}
    UI:show(dialog)
    scan=require('ao3lib.library.discovery').scan(roots,function(works,err)
        if cancelled then return end
        dialog.dismiss_callback=nil
        UI:close(dialog)
        if err then
            UI:show(InfoMessage:new{text=_('Could not finish the library scan: ')..err})
            return
        end
        require('ao3lib.library.local_cache').put(roots,works)
        local count=0;for _ in pairs(works) do count=count+1 end
        UI:show(InfoMessage:new{text=string.format(_('Library scan complete: %d AO3 works found.'),count)})
    end,function() return cancelled end)
    return dialog
end

return M
