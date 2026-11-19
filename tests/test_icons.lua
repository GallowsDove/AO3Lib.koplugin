package.path='./?.lua;'..package.path
-- Resolve the new name through KOReader's actual IconWidget initializer.
G_defaults={readSetting=function() return 24 end}
package.loaded.datastorage={getDataDir=function() return '/data' end}
package.loaded.device={screen={scaleBySize=function(_,size) return size end}}
package.loaded['libs/libkoreader-lfs']={attributes=function(path)
    if path=='resources/icons/mdlight/check.svg' then return 'file' end
end}
package.loaded['ui/widget/imagewidget']={extend=function(_,fields) return fields end}
local Icon=dofile('../koreader/frontend/ui/widget/iconwidget.lua')
package.loaded['ui/widget/iconwidget']=Icon
local user_items={{icon='custom',label='Custom'}}
local Picker={_scanUserIcons=function() return user_items end}
package.loaded['lib/bookshelf_icons_library']=Picker
local Icons=require('ao3lib.ui.icons')
assert(Icons.installBookshelf())
local init,scan=Icon.init,Picker._scanUserIcons
assert(Icons.installBookshelf() and Icon.init==init and Picker._scanUserIcons==scan)
local widget={icon='ao3'}
Icon.init(widget)
assert(widget.file==Icons.file and io.open(widget.file,'rb'):close())
widget={icon='check'};Icon.init(widget)
assert(widget.file=='resources/icons/mdlight/check.svg','Standard icon resolution changed')
widget={icon='ao3',file='/custom.svg'};Icon.init(widget)
assert(widget.file=='/custom.svg')
widget={icon='ao3',image={}};Icon.init(widget)
assert(widget.file==nil,'An explicitly supplied image was overwritten')
local items=Picker._scanUserIcons()
assert(#items==2 and #user_items==1)
assert(items[2].icon=='ao3' and items[2].insert_value=='[icon=ao3]' and items[2].is_image)
assert(#Picker._scanUserIcons()==2,'Repeated scans duplicated the AO3 icon')
user_items={{icon='ao3',label='User AO3'}}
assert(Picker._scanUserIcons()==user_items,'Existing picker entries must not be duplicated')
print('PASS: native icon resolution; plugin SVG asset; standard/explicit-image preservation; Bookshelf picker; idempotence; no duplicate icons or file installation')
