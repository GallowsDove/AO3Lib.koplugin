package.path='./?.lua;'..package.path
local values,shown,closed={},nil,{}
package.loaded.gettext=function(s) return s end
package.loaded['ao3lib.core.config']={readSetting=function(_,key,default) if values[key]~=nil then return values[key] end return default end,
    saveSetting=function(_,key,value) values[key]=value end}
package.loaded['ui/uimanager']={show=function(_,widget) shown=widget end,close=function(_,widget) closed[widget]=true end}
package.loaded['ui/widget/buttondialog']={new=function(_,args) return args end}
local Help=require('ao3lib.ui.work_view_help')
local first=Help.showIfNeeded()
assert(first==shown and first.title:find('Hold an author',1,true))
first.buttons[1][1].callback()
assert(closed[first] and not values.work_view_controls_seen)
local later=Help.showIfNeeded();assert(later~=first)
later.buttons[1][2].callback()
assert(closed[later] and values.work_view_controls_seen)
assert(not Help.showIfNeeded())
local manual=Help.show();assert(manual==shown)
print('PASS: first-use help, later, persistent acknowledgement and manual reopening')
