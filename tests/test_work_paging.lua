dofile('tests/test_work_view.lua')
local Paging=require('ao3lib.ao3.work_paging')
local View=require('ao3lib.ui.work_view')
local Browser=require('ao3lib.ui.work_browser')
local Config=package.loaded["ao3lib.core.config"]
local function batch(page,total)
    local works={total=total}
    for i=(page-1)*20+1,math.min(page*20,total) do works[#works+1]={id=i,title='Work '..i} end
    return works
end
local requested={}
local first=batch(1,247)
local nextBatch=function() error('Numbered navigation must never walk intermediate pages') end
local fail=false
Paging.attach(first,nextBatch,function(page)
    requested[#requested+1]=page
    if fail then return nil end
    return batch(page,247)
end)
local pager=Paging.get(nextBatch)
local pending,presented=nil,{}
local ctx={works=first,fetch=nextBatch,index=1,network=function(fn) pending=fn end,
    rows=function(work) return Browser:generateTable({}, {work},function() end,function() end) end,
    present=function(state) presented[#presented+1]=state.index end}
local state=View.new(ctx);state:render()
assert(state:pageCount()==247)
local overview_first=batch(1,247)
local overview_fetch=function() end
local overview_requests={}
Paging.attach(overview_first,overview_fetch,function(page) overview_requests[#overview_requests+1]=page;return batch(page,247) end)
local overview=View.new{works=overview_first,fetch=overview_fetch,series_info={title='Series',summary='Overview'},
    network=function(fn) fn() end,rows=ctx.rows,present=function(_,html,_,rows)
        if rows[1][1]=='Series' then assert(html:find('Overview',1,true)) end
    end}
overview:render();assert(overview:pageCount()==248 and overview.index==1)
overview:next();assert(overview.index==2 and overview.works[1].id==1)
overview:goTo(22);assert(overview.index==22 and overview_requests[1]==2 and overview.works[21].id==21)
overview:goTo(248);assert(overview.index==248 and overview_requests[2]==13)
overview:goTo(1);assert(overview.index==1)
local empty_overview=View.new{works={total=0},series_info={title='Empty'},rows=ctx.rows,present=function() end}
assert(empty_overview:pageCount()==1);empty_overview:next();assert(empty_overview.index==1)
state:goTo(123)
assert(state.index==1 and #requested==0 and pending,'Jump must retain the current work while connecting')
pending();pending=nil
assert(state.index==123 and #requested==1 and requested[1]==7)
state:goTo(124);assert(state.index==124 and #requested==1,'Neighbour in a cached batch fetched again')
state:goTo(1);assert(state.index==1 and #requested==1)
state:goTo(247);pending();pending=nil
assert(state.index==247 and #requested==2 and requested[2]==13)
state:next();assert(not pending and #requested==2,'Next fetched past the last work')
state:previous();assert(state.index==246)
fail=true;state:goTo(60);pending();pending=nil
assert(state.index==246,'Failure moved away from the current work')
fail=false;state:goTo(60);pending();pending=nil
assert(state.index==60 and requested[#requested]==3,'Retry skipped the requested result page')
local before=#requested
state:goTo(248);state:goTo(0);state:goTo(1.2);assert(#requested==before and not pending)
-- Closing or superseding a pending connection must not issue a request.
state:goTo(80);local abandoned=pending;pending=nil
state:goTo(1);abandoned()
assert(state.index==1 and #requested==before)
state:goTo(80);state.closed=true;pending();pending=nil
assert(#requested==before)
-- Native KeyValuePage:new invokes _populateItems during init; the headless
-- class adapter must do the same for this paged information window.
local Base=package.loaded['ui/widget/keyvaluepage']
local baseNew=Base.new
Base.new=function(class,args)
    local window=baseNew(class,args)
    if class.goToPage then window:_populateItems() end
    return window
end
-- Both actual work views share the numbered cache, total, and current index.
Config.readSetting=function(_,key,default) if key=='formatted_work_view' then return true end;return default end
local plugin={menu_stack={}}
local formatted=Browser:show({},first,nextBatch,function() end,function() end,function() end,plugin)
assert(formatted.window.page_buttons[3].text=='Page 1 of 247')
formatted.window.page_buttons[3].hold_input.callback('123')
assert(formatted.index==123 and #requested==before,'Formatted picker did not reuse the cached numbered batch')
Config.readSetting=function(_,key,default) if key=='formatted_work_view' then return false end;return default end
local listed=Browser:show({},first,nextBatch,function() end,function() end,function() end,plugin,nil,{index=123})
assert(listed.index==123 and listed.window.pages==247 and listed.window.show_page==123)
assert(listed.window.kv_pairs[(123-1)*15+1][1]=='Work 123')
listed.window:goToPage(247)
assert(listed.index==247 and listed.window.show_page==247 and #requested==before)
assert(listed.window.kv_pairs[(247-1)*15+1][1]=='Work 247')
local series_listed=Browser:show({},overview_first,overview_fetch,function() end,function() end,function() end,
    plugin,'Series',{series_info={title='Series',summary='Series summary'}})
assert(series_listed.index==1 and series_listed.window.pages==248 and series_listed.window.kv_pairs[1][1]=='Series')
series_listed:next()
assert(series_listed.index==2 and series_listed.window.kv_pairs[16][1]=='Work 1')
-- Snapshot query parameters when registering a native search fetcher.
local Fanfic=require('main')
local client=package.loaded["ao3lib.ao3.client"]
local calls={}
client.searchByParameters=function(_,params,page)
    calls[#calls+1]={query=params.query,sort=params.sort,page=page or 1}
    return {success=true,works=batch(page or 1,247)}
end
local query={query='dragons',sort='kudos'}
local ok,works,fetch=Fanfic:executeSearch(query)
assert(ok and #calls==1)
query.query='changed';query.sort='updated'
assert(Paging.get(fetch):load(123).id==123 and #calls==2)
assert(calls[2].page==7 and calls[2].query=='dragons' and calls[2].sort=='kudos')
-- Numbered requests must not advance the original sequential iterator.
fetch();assert(calls[3].page==2)
print('PASS: full counts; direct remote batch jumps; sparse cache shared across views; no intermediate loads; query snapshots; failures/retry; cancellation; boundaries; sequential iterator isolation')

-- A sparse cached page must not inflate the count when AO3 does not supply it.
local unknownFirst=batch(1,20);unknownFirst.total=nil
local unknownFetch=function() end
local unknownCalls=0
Paging.attach(unknownFirst,unknownFetch,function(page)
    unknownCalls=unknownCalls+1;assert(page==2)
    local works=batch(2,35);works.total=nil;return works
end)
local unknown=View.new{works=unknownFirst,fetch=unknownFetch,index=20,rows=ctx.rows,
    present=function() end,network=function(fn) fn() end}
unknown:next();assert(unknown.index==21 and unknown:pageCount()==35 and unknownCalls==1)
-- Exercise KOReader's actual row population and footer, not just the host
-- window adapter, with a sparse page far beyond the initial result batch.
local input=assert(io.open('../koreader/frontend/ui/widget/keyvaluepage.lua'))
local source=input:read('*a');input:close()
local body=assert(source:match('function KeyValuePage:_populateItems%(%)\n(.-)\nend\n'))
local rendered={}
local Text={new=function(_,args)
    return {text=args.text,setText=function(self,t) self.text=t end,
        getWidth=function(self) return #self.text*8 end,free=function() end}
end}
local env=setmetatable({_=function(s) return s end,
    TextWidget=Text,Font={getFace=function() return {} end},
    KeyValueItem={frame_padding=2,middle_padding=4,new=function(_,args)
        rendered[#rendered+1]=args;return args
    end},
    Size={line={thick=1}},LineWidget={new=function(_,args) return args end},
    Geom={new=function(_,args) return args end},Blitbuffer={COLOR_LIGHT_GRAY=0},
    FocusManager={FOCUS_ONLY_ON_NT=1,NOT_UNFOCUS=2},bit=require('bit'),
    UIManager={setDirty=function() end},T=package.loaded['ffi/util'].template,
},{__index=_G})
local load=assert(loadstring('return function(self)\n'..body..'\nend'));setfenv(load,env)
local window=listed.window
window.item_width=600;window.item_height=36;window.items_font_size=18;window.dimen={w=600,h=800}
local function button()
    return {resetLayout=function() end,show=function() end,hide=function() end,
        setText=function(self,t) self.text=t end,enable=function() end,
        disableWithoutDimming=function() end,enableDisable=function(self,v) self.enabled=v end}
end
window.page_info=button();window.return_button=button();window.page_info_text=button()
for _,key in ipairs({'left','right','first','last'}) do window['page_info_'..key..'_chev']=button() end
window.main_content={clear=function(t) for i=#t,1,-1 do t[i]=nil end end}
window.moveFocusTo=function() end
load()(window)
assert(#rendered==15 and rendered[1].key=='Work 247')
assert(window.page_info_text.text=='Page 247 of 247' and not window.page_info_right_chev.enabled)
print('PASS: native KOReader sparse information rows and full-count footer at the last remote work')
