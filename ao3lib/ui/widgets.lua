-- Shared presentation for AO3's full-page lists. Keep dialogs independent:
-- confirmations and text entry should retain KOReader's normal popup style.
local M={}
function M.menu(options)
    local defaults={is_borderless=true,is_popout=false,covers_fullscreen=true,
        with_bottom_line=true,linesize=0,title_bar_left_icon='ao3'}
    local out={}
    for key,value in pairs(defaults) do out[key]=value end
    for key,value in pairs(options or {}) do out[key]=value end
    return out
end
return M
