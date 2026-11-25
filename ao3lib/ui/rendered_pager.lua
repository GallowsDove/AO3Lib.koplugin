-- Shared bottom navigation for rendered AO3 screens.
local _=require('gettext')
local T=require('ffi/util').template
local M={}
function M.new(owner,options)
    local Button=require('ui/widget/button')
    local Horizontal=require('ui/widget/horizontalgroup')
    local Span=require('ui/widget/horizontalspan')
    local Screen=require('device').screen
    local mirrored=require('ui/bidi').mirroredUILayout()
    local first=Button:new{icon=mirrored and 'chevron.last' or 'chevron.first',bordersize=0,
        show_parent=owner,enabled=options.has_previous,callback=options.first}
    local previous=Button:new{icon=mirrored and 'chevron.right' or 'chevron.left',bordersize=0,
        show_parent=owner,enabled=options.has_previous,callback=options.previous}
    local page=Button:new{text=options.label,bordersize=0,text_font_face='pgfont',text_font_bold=false,
        enabled=options.total and options.total>1 or false,show_parent=owner,call_hold_input_on_tap=true,
        hold_input={title=_('Enter page number'),input_type='number',
            hint_func=function() return T('(1 - %1)',options.total) end,
            ok_text=_('Go to page'),callback=function(input) options.go_to(tonumber(input)) end}}
    local following=Button:new{icon=mirrored and 'chevron.left' or 'chevron.right',bordersize=0,
        show_parent=owner,enabled=options.has_next,callback=options.next}
    local last=Button:new{icon=mirrored and 'chevron.first' or 'chevron.last',bordersize=0,
        show_parent=owner,enabled=options.has_last,callback=options.last}
    local buttons={first,previous,page,following,last}
    local used=0
    for _,button in ipairs(buttons) do used=used+button:getSize().w end
    local gap=math.max(0,math.min(Screen:scaleBySize(32),math.floor((options.width-used)/4)))
    return Horizontal:new{first,Span:new{width=gap},previous,Span:new{width=gap},page,
        Span:new{width=gap},following,Span:new{width=gap},last},buttons
end
return M
