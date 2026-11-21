-- An explicit view action in information lists, independent of the AO3 logo.
local M={}
function M.restore(window)
    if window._ao3_view_padded_height and window.item_height==window._ao3_view_padded_height then
        window.item_height=window._ao3_view_base_height
    end
end
function M.reserve(window,callback)
    window.switch_work_view=callback
    -- Native KeyValuePage creates main_content before populating its rows.
    if not window.main_content then return end
    local button=require('ui/widget/button'):new{text=require('gettext')('Rendered view'),
        width=window.item_width,bordersize=0,show_parent=window,callback=callback}
    window._ao3_view_button=button
    window._ao3_view_base_height=window.item_height
    window.item_height=math.max(1,window.item_height-math.ceil(button:getSize().h/window.items_per_page))
    window._ao3_view_padded_height=window.item_height
end
function M.insert(window)
    local button=window._ao3_view_button
    if not button then return end
    table.insert(window.main_content,1,button)
    window.main_content:resetLayout()
    table.insert(window.layout,1,{button})
end
return M
