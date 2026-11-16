dofile('tests/test_network.lua')
local Browser=require('AO3_user_browser')
local series={id=12,title='First series',fandoms={'Fandom'},work_count=3,word_count='84,250',
    author='Writer',date_posted='2026-11-16',summary='A summary'}
local more={id=34,title='Second series',fandoms={},work_count=2,word_count='12,345',author='Writer'}
local fetched,opened=0,0
Browser.Fanfic={menu_stack={},getSeriesFromUserPage=function()
    return true,{series},function() fetched=fetched+1;return {more} end
end,getWorksFromSeries=function(_,id) assert(id==12);return true,{} end,
    onShowFanficBrowser=function(_,works) opened=opened+1;assert(works.total==3) end}
Browser.userData={username='Writer',pseud='Writer'}
Browser.menu_layers={}
Browser.AO3UserWindow={title='Writer',kv_pairs={},show_page=1}
Browser:openUserSeriesList()
local window=Browser.AO3UserWindow
assert(window._ao3_compact and window.kv_pairs._ao3_compact)
local stats=0
for _,row in ipairs(window.kv_pairs) do
    assert(row[1]~='Work count:' and row[1]~='Word count:')
    if row[1]=='Stats:' then stats=stats+1;assert(row[2]=='3 works · 84,250 words') end
end
assert(stats==1)
window.kv_pairs[2].callback();assert(opened==1)
-- Reduce row height while keeping the original text size and total space.
window.item_height=80;window.items_per_page=10;window.items_font_size=22
window:_populateItems()
assert(window.item_height==61 and window.items_per_page==13 and window.items_font_size==22)
window:_populateItems();assert(window.item_height==61,'Repeated redraws compounded the spacing reduction')
window.kv_pairs[#window.kv_pairs].callback()
assert(fetched==1 and Browser.AO3UserWindow._ao3_compact)
local values={}
for _,row in ipairs(Browser.AO3UserWindow.kv_pairs) do
    if row[1]=='Stats:' then values[#values+1]=row[2] end
end
assert(#values==2 and values[2]=='2 works · 12,345 words')
Browser:GoUpInMenu()
window=Browser.AO3UserWindow
assert(not window._ao3_compact and window.title=='Writer')
window.item_height=80;window.items_per_page=10;window.items_font_size=22
window:_populateItems()
assert(window.item_height==80 and window.items_per_page==10)
print('PASS: merged series work/word counts; tighter spacing without smaller text; redraw stability; paginated series; opening works; unchanged profile spacing')
