-- Shared fixed controls for paged library and update-review screens.
local VerticalGroup=require('ui/widget/verticalgroup')
local TitleBar=require('ui/widget/titlebar')
local TextBox=require('ui/widget/textboxwidget')
local ButtonTable=require('ui/widget/buttontable')
local Font=require('ui/font')
local Device=require('device')
local M={}
function M.new(title,close,left)
    local width=Device.screen:getWidth()
    local bar=TitleBar:new{width=width,fullscreen=true,title=title,align='center',
        left_icon='ao3',left_icon_tap_callback=left,close_callback=close,with_bottom_line=true}
    local header=VerticalGroup:new{align='center',bar}
    header._ao3_titlebar=bar
    function header:getHeight() return self:getSize().h end
    for _,method in ipairs({'setRightIcon','setLeftIcon','setTitle','setSubTitle'}) do
        header[method]=function(_,...) return bar[method](bar,...) end
    end
    function header:generateVerticalLayout()
        local rows=bar:generateVerticalLayout()
        for i=2,#self do
            for _,row in ipairs(self[i].buttons_layout or {}) do
                for _,button in ipairs(row) do rows[#rows+1]={button} end
            end
        end
        return rows
    end
    local function buttons(rows)
        local copied={}
        for i,row in ipairs(rows) do
            copied[i]={}
            for j,button in ipairs(row) do
                local definition={}
                for key,value in pairs(button) do definition[key]=value end
                -- Button:onTapSelectButton normally repaints its checkmark
                -- after the callback. Our callback may free/reposition that
                -- very button while rebuilding this header, so let the new
                -- header paint the checkmark instead of the stale widget.
                if definition.checked_func then definition.no_refresh_checkmark=true end
                copied[i][j]=definition
            end
        end
        return ButtonTable:new{width=width,buttons=copied}
    end
    function header:update(model)
        for i=#self,2,-1 do self[i]:free();self[i]=nil end
        local notice=model.summary..(model.notice~='' and ('\n'..model.notice) or '')
        self[#self+1]=TextBox:new{text=notice,width=width-Device.screen:scaleBySize(24),
            face=Font:getFace('smallinfofont',16),alignment='left'}
        if model.scope then self[#self+1]=buttons({{model.scope}}) end
        if model.buttons then self[#self+1]=buttons(model.buttons) end
        if model.filters then self[#self+1]=buttons({model.filters}) end
        if model.select_all then
            self[#self+1]=buttons({{model.select_all}})
        end
        self:resetLayout()
    end
    return header
end
return M
