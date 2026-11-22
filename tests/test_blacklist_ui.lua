package.path='./?.lua;'..package.path
local saved={}
package.loaded['gettext']=function(s) return s end
package.loaded['ao3lib.core.config']={readSetting=function(_,key,default) return saved[key] or default end,
    saveSetting=function(_,key,value) saved[key]=value end}
local shown
package.loaded['ui/uimanager']={show=function(_,dialog) shown=dialog end,close=function() end}
package.loaded['ui/widget/buttondialog']={new=function(_,options) return options end}
package.loaded['ui/widget/inputdialog']={new=function(_,options) return options end}
package.loaded['ao3lib.ao3.network']={wrap=function(fn) return fn end}
package.loaded['ui/widget/infomessage']={new=function(_,options) return options end}
local menu={paths={}}
function menu:GoDownInMenu(title,rows) self.paths[#self.paths+1]=self.rows;self.title,self.rows=title,rows end
function menu:onReturn() self.rows=table.remove(self.paths) end
function menu:switchItemTable(_,rows) self.rows=rows end
function menu:updateItems() end
local ui=require('ao3lib.ui.blacklist')
ui.show{menuWidget=menu,fanfic={}}
for _,choice in ipairs({{index=5,name='Explicit'},{index=6,name='M/M'},{index=7,name='Major Character Death'}}) do
    menu.rows[1].callback()
    shown.buttons[choice.index][1].callback()
    local found
    for _,row in ipairs(menu.rows) do if row.text==choice.name then found=row end end
    assert(found,'Missing fixed blacklist option '..choice.name)
    found.callback()
    assert(saved.tag_blacklist[#saved.tag_blacklist].name==choice.name)
end
local actions=require('ao3lib.ui.tag_actions')
local dialog=actions.show(nil,'Freeform','A new tag')
assert(dialog.buttons[1][1].text=='Add to blacklist')
dialog.buttons[1][1].callback()
assert(saved.tag_blacklist[#saved.tag_blacklist].name=='A new tag')
dialog=actions.show(nil,'Freeform','a NEW tag')
assert(dialog.buttons[1][1].enabled==false)
print('PASS: blacklist rating, category and archive warning selection')
