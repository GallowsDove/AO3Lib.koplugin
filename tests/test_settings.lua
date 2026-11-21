dofile('tests/test_network.lua')
local UI=require('ui/uimanager')
local Config=require('ao3lib.core.config')
local Menu=require('ao3lib.ui.menu')
local values={work_view_font_size=22,update_check_delay_seconds=9,filename_template='%I',author_folders=true,
    formatted_work_view=true,AO3_domain='https://archiveofourown.org',fanfic_folder_path='/books'}
Config.readSetting=function(_,key,default) if values[key]~=nil then return values[key] end;return default end
local saves=0
Config.saveSetting=function(_,key,value) saves=saves+1;values[key]=value end
local owner={GoDownInMenu=function(self,title,rows) self.title,self.item_table=title,rows end,
    switchItemTable=function(self,_,rows) self.item_table=rows end,updateItems=function() end}
Menu.menuWidget=owner
local shown,show_count
show_count=0
UI.show=function(_,widget) shown=widget;show_count=show_count+1 end
UI.close=function() end
package.loaded['ui/widget/spinwidget']={new=function(_,args) return args end}
local function find(text)
    for _,row in ipairs(owner.item_table) do if row.text==text then return row end end
    error('Missing setting: '..text)
end
Menu:onOpenSettings()
assert(#owner.item_table==5)
for _,row in ipairs(owner.item_table) do assert(row.mandatory==nil) end
find('Update checks').callback()
local delay=find('Delay between checks')
assert(delay.mandatory=='9 s')
delay.callback()
assert(shown.value==9 and shown.value_min==1 and shown.value_max==120 and shown.default_value==4)
local spin=shown
spin.callback{value=15}
assert(values.update_check_delay_seconds==15 and find('Delay between checks').mandatory=='15 s')
assert(show_count==1,'Saving an option must not show a success popup')
local before=saves
spin.callback{value=0};assert(saves==before)
spin.callback{value=121};assert(saves==before)
spin.callback{value=1.5};assert(saves==before)
Menu:onOpenSettings();find('Reading and display').callback()
find('Formatted view text size').callback()
assert(shown.value==22 and shown.value_min==12 and shown.value_max==32,'Numeric settings must use their own values and bounds')
shown.callback{value=24}
assert(values.work_view_font_size==24 and values.update_check_delay_seconds==15)
Menu:onOpenSettings();find('Downloads').callback()
assert(find('Download layout').mandatory=='Author/Title')
find('HTML download fallback').callback()
assert(shown.title=='HTML download fallback')
local before_show=show_count
shown.buttons[1][1].callback()
assert(values.html_download_fallback==true and find('HTML download fallback').mandatory=='On')
assert(show_count==before_show,'Boolean settings must refresh inline without success popups')
Menu:onOpenSettings();find('Library maintenance…').callback()
assert(shown.title=='Library maintenance' and #shown.buttons==3)
assert(shown.buttons[1][1].text=='Rescan library')
assert(shown.buttons[2][1].text=='Organize downloaded works…')
local Pacing=require('ao3lib.updates.pacing')
assert(Pacing.delay('check')==15)
assert(Pacing.seconds(nil)==4 and Pacing.seconds('invalid')==4 and Pacing.seconds(0/0)==4)
assert(Pacing.seconds(-1)==1 and Pacing.seconds(999)==120 and Pacing.seconds(5.9)==5)
local download_delay=Pacing.delay('update')
assert(download_delay>=3 and download_delay<=5,'Check delay must not alter download pacing')
print('PASS: grouped options, maintenance buttons, inline values, no save popups, independent numeric settings, delay persistence/bounds and pacing')

Menu:onOpenSettings();find('Reading and display').callback()
assert(find('Downloaded works view').mandatory=='List')
find('Downloaded works view').callback();shown.buttons[1][1].callback()
assert(values.downloaded_rendered_view==true and find('Downloaded works view').mandatory=='Rendered')
find('Downloaded works view').callback();shown.buttons[2][1].callback()
assert(values.downloaded_rendered_view==false and find('Downloaded works view').mandatory=='List')
print('PASS: downloaded-work rendering is selected explicitly in Settings')
