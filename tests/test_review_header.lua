-- Exercise the real fixed-header composition with lightweight native widgets.
package.path='./?.lua;'..package.path
local freed=0
local Widget={}
function Widget:new(t)
    t=t or {};setmetatable(t,{__index=self})
    if self.init then t:init() end
    return t
end
function Widget:getSize() return {w=self.width or 600,h=self.height or 40} end
function Widget:free() freed=freed+1 end
local Group=setmetatable({}, {__index=Widget})
function Group:getSize()
    local h=0;for _,w in ipairs(self) do h=h+w:getSize().h end
    return {w=600,h=h}
end
function Group:resetLayout() end
local Title=setmetatable({}, {__index=Widget})
function Title:generateVerticalLayout() return {{self}} end
for _,method in ipairs({'setRightIcon','setLeftIcon','setTitle','setSubTitle'}) do
    Title[method]=function(self,value) self[method..'_value']=value end
end
local Buttons=setmetatable({}, {__index=Widget})
function Buttons:init() self.buttons_layout=self.buttons end
package.loaded['ui/widget/verticalgroup']=Group
package.loaded['ui/widget/titlebar']=Title
package.loaded['ui/widget/textboxwidget']=Widget
package.loaded['ui/widget/buttontable']=Buttons
package.loaded['ui/font']={getFace=function() return {} end}
package.loaded.device={screen={getWidth=function() return 600 end,scaleBySize=function(_,n) return n end}}
local closed,left=false,false
local header=require('ao3lib.ui.update_review_header').new('Updates',function() closed=true end,function() left=true end)
local applied=false
local model={summary='42 of 60 checked · 8 updates found · 2 failed',notice='Checking 43 of 60',
    buttons={{{text='Stop checking'},{text='Update selected (8)',callback=function() applied=true end},{text='More…'}}},
    filters={{text='Updates (8)'},{text='Needs review (2)'},{text='All (60)'}},
    select_all={text='Select all updates'}}
header:update(model)
assert(#header==5 and header[2].text:find('Checking 43',1,true))
assert(header:getHeight()==200)
local layout=header:generateVerticalLayout()
assert(#layout==8,'Title, action buttons, filters and selection must all be keyboard reachable')
header:setRightIcon('close');header:setLeftIcon('ao3');header:setTitle('Changed');header:setSubTitle('Status')
assert(header[1].setRightIcon_value=='close' and header[1].setTitle_value=='Changed')
header[3].buttons[1][2].callback();assert(applied)
header[1].close_callback();header[1].left_icon_tap_callback();assert(closed and left)
model.select_all=nil;header:update(model)
assert(freed==4 and #header==4 and header:getHeight()==160)
model.scope={text='Scope: Author: Writer',callback=function() end}
header:update(model)
assert(#header==5 and header[3].buttons[1][1].text=='Scope: Author: Writer')
assert(#header:generateVerticalLayout()==8)
print('PASS: separate title/status/button/filter/selection widgets, focus layout, titlebar delegation and refresh cleanup')

-- Native Button repaints a checked label after invoking its callback unless
-- no_refresh_checkmark is set. A shrinking header must not repaint the freed
-- filter at its old position after the replacement header has been drawn.
local old_header=header
model.scope=nil
model.select_all={text='Select all updates',checked_func=function() return false end}
model.filters[1].checked_func=function() return true end
model.filters[1].callback=function()
    model.select_all=nil
    old_header:update(model)
end
old_header:update(model)
local old_filter=old_header[4].buttons[1][1]
local before_height=old_header:getHeight()
assert(old_header[5].buttons[1][1].no_refresh_checkmark)
assert(model.filters[1].no_refresh_checkmark==nil,'Rendering must not mutate shared control definitions')
old_filter.callback()
local stale_repaints=0
if old_filter.checked_func and not old_filter.no_refresh_checkmark then stale_repaints=stale_repaints+1 end
assert(stale_repaints==0 and old_header:getHeight()<before_height)
assert(old_header[4].buttons[1][1].no_refresh_checkmark)
print('PASS: header resize suppresses native post-callback checkmark repaints on stale filter/selection buttons')
local compact=require('ao3lib.ui.update_review_header').new('Downloaded Works',function() end,function() end)
compact:update{summary='3 works',notice='',buttons={{{text='View options…'}}}}
assert(#compact==3,'Downloaded view must omit persistent scope and filter rows')
print('PASS: compact downloaded header contains only summary and View options')
