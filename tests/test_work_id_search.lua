dofile('tests/test_network.lua')
local connected,pending,prompts=false,nil,0
package.loaded['ui/network/manager']={
    isConnected=function() return connected end,
    runWhenConnected=function(_,callback) pending=callback;prompts=prompts+1 end,
}
package.loaded.fanfic_network=nil
package.loaded.fanfic_search=nil
package.loaded.fanfic_menu=nil
local Menu=require('fanfic_menu')
local UI=require('ui/uimanager')
local shown,closed={},{}
UI.show=function(_,widget) shown[#shown+1]=widget end
UI.close=function(_,widget)
    closed[widget]=true
    if widget.onCloseWidget then widget:onCloseWidget() end
end
local calls,opened={},{}
local fail=true
require('AO3_downloader_client').getWorkMetadata=function(_,id)
    calls[#calls+1]=id
    if fail then return {success=false,error='AO3 maintenance'} end
    return {success=true,work_metadata={title='Found work',author='Writer',chapters='2/3'}}
end
Menu.fanfic={DownloadFanfic=function() error('Searching an ID must never download') end,
    onShowFanficBrowser=function(_,works,fetch,title)
        assert(fetch==nil and title=='AO3 work details' and works.total==1)
        opened[#opened+1]=works[1]
    end}
Menu.menuWidget={GoDownInMenu=function(self,_,items) self.item_table=items end}
Menu:onSearchFanficMenu()
local found=false
for _,item in ipairs(Menu.menuWidget.item_table) do
    if item.text=='Search work by ID' then found=true;item.callback();break end
end
assert(found)
local dialog=shown[#shown]
assert(dialog.title=='Search work by ID' and dialog.buttons[1][2].text=='Search')
for _,invalid in ipairs({'','abc','0','000','123/4'}) do
    dialog.input=invalid;dialog.buttons[1][2].callback()
    assert(prompts==0 and #calls==0 and not closed[dialog])
end
dialog.input=' 12345 ';dialog.buttons[1][2].callback()
assert(prompts==1 and pending and #calls==0 and not closed[dialog])
pending=nil -- Cancel Wi-Fi, leaving the input available for retry.
dialog.buttons[1][2].callback()
connected=true
local reconnect=pending;pending=nil;reconnect()
assert(#calls==1 and calls[1]=='12345' and not closed[dialog] and dialog.input==' 12345 ')
assert(shown[#shown].text:find('AO3 maintenance',1,true) and #opened==0)
fail=false;dialog.buttons[1][2].callback()
assert(#calls==2 and #opened==1 and opened[1].id=='12345' and opened[1].title=='Found work')
assert(closed[dialog])
connected=false
Menu:onShowFanficSearch();dialog=shown[#shown];dialog.input='67890'
dialog.buttons[1][2].callback();reconnect=pending;pending=nil
dialog.buttons[1][1].callback();connected=true;reconnect()
assert(#calls==2 and #opened==1,'Canceled ID search was revived by Wi-Fi continuation')
print('PASS: Search work by ID labels; valid IDs; offline retry; maintenance retains input; metadata opens details without download; closing cancels pending search')
