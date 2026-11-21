dofile('tests/test_network.lua')
local UI=require('ui/uimanager')
UI.setDirty=function() end
local Nav=require('ao3lib.ui.navigation')
local calls,wrong=0,0
local owner={menu_stack={},ui={menu={onShowMenu=function() calls=calls+1 end}}}
-- Native Menu, KeyValuePage and rendered pages all bind their logo alike.
for _,kind in ipairs({'menu','keyvalue','rendered','review'}) do
    local bar={left_button={callback=function() wrong=wrong+1 end},
        left_icon_tap_callback=function() wrong=wrong+1 end,
        setRightIcon=function() end}
    local window={key_events={},title_bar_left_icon_tap_callback=function() wrong=wrong+1 end}
    if kind=='rendered' then window.titlebar=bar
    elseif kind=='review' then window.title_bar={_ao3_titlebar=bar,setRightIcon=function() end}
    else window.title_bar=bar end
    Nav.bind(owner,window)
    local before=calls
    window:onLeftButtonTap();window.title_bar_left_icon_tap_callback();bar.left_button.callback()
    bar.left_icon_tap_callback();window:onAO3Menu()
    assert(calls==before+5 and wrong==0 and window._ao3_navigation)
    -- Reinitializing the native titlebar uses this updated callback too.
    bar.left_button={callback=bar.left_icon_tap_callback}
    bar.left_button.callback();assert(calls==before+6)
end
assert(#owner._ao3_navigation==4,'Logo taps must preserve screens and navigation state')
print('PASS: consistent logo action on menus, lists, rendered pages and review headers; physical Menu parity')
