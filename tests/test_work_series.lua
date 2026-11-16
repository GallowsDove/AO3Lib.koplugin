dofile('tests/test_failures.lua')
-- Find the existing private parser without exposing a production test API.
local function findParser(fn,seen)
    seen=seen or {};if seen[fn] then return end;seen[fn]=true
    for i=1,100 do
        local name,value=debug.getupvalue(fn,i)
        if not name then break end
        if name=='AO3WebParser' then return value end
        if type(value)=='function' then local found=findParser(value,seen);if found then return found end end
    end
end
local Parser=assert(findParser(require('AO3_downloader_client').getWorkMetadata))
local function node(content,attrs,selectors)
    return {attributes=attrs or {},getcontent=function() return content or '' end,
        select=function(_,selector) return (selectors or {})[selector] or {} end}
end
local function membership(id,title,position)
    local link=node(title,{href='/series/'..id})
    return node((position and 'Part <strong>'..position..'</strong> of ' or '')..'<a href="/series/'..id..'">'..title..'</a>',nil,{a={link}})
end
local a=membership(12,'Salt &amp; <em>Sea</em>','2')
local b=membership(34,'Companion stories','1.5')
local title=node('Story',{href='/works/123'})
local listing=node('',nil,{['h4.heading > a']={title},['ul.series > li']={a,b,a}})
local work=assert(Parser:parseWorkElement(listing))
assert(#work.series==2 and work.series[1].id==12)
assert(work.series[1].title=='Salt & Sea' and work.series[1].position=='2')
assert(work.series[2].position=='1.5')
local page=node('',nil,{['#workskin .title']={title},['.title']={title},['dd.series .position']={a,b}})
local detail=Parser:parseWorkPage(page)
assert(#detail.series==2 and detail.series[2].title=='Companion stories')
local without=Parser:parseWorkElement(node('',nil,{['h4.heading > a']={title}}))
assert(#without.series==0)
local fallback=Parser:parseWorkSeries(node('',nil,{['dd.series']={membership(56,'Unnumbered stories')}}))
assert(#fallback==1 and fallback[1].position==nil)
-- Render through the real work browser, including older records with no series.
dofile('tests/test_network.lua')
local Browser=require('fanficbrowser')
local function seriesRows(record)
    local out={}
    for _,row in ipairs(Browser:generateTable({}, {record},function() end,function() end)) do
        if row[1]=='     Series:' then out[#out+1]=row[2] end
    end
    return out
end
local rows=seriesRows(work)
assert(#rows==1 and rows[1]=='#2 Salt & Sea; #1.5 Companion stories')
assert(seriesRows(without)[1]=='None')
work.series=fallback
assert(seriesRows(work)[1]=='Unnumbered stories')
work.series=nil
assert(seriesRows(work)[1]=='None')
print('PASS: series in work listings and full metadata; multiple memberships; positions; HTML decoding; absent/older metadata; browser series rows')

-- A mixed result set must retain the same page boundaries on initial load,
-- pagination append and reload, including multi-series and deleted works.
work.series={{id=12,title='Salt & Sea',position='2'},{id=34,title='Companions',position='1'}}
work.words='1200';work.language='English'
local mixed=Browser:generateTable({}, {without,work,{is_deleted=true}},function() end,function() end)
assert(#mixed==45)
assert(mixed[1][1]=='Story' and mixed[16][1]=='Story' and mixed[31][1]=='DELETED WORK')
assert(mixed[15].separator and mixed[30].separator and mixed[45].separator)
assert(mixed[18][1]=='     Series:' and mixed[18].callback)
assert(mixed[27][1]=='     Language:' and mixed[27][2]=='English')
assert(mixed[28][1]=='     Words:' and mixed[28][2]=='1200')
Browser:generateTable(mixed,{work},function() end,function() end)
assert(#mixed==60 and mixed[46][1]=='Story' and mixed[60].separator)
local one=Browser:generateTable({}, {work},function() end,function() end)
assert(#one==15 and one[3][1]=='     Series:' and one[15].separator)
print('PASS: fixed 15-row layout for no/single/multiple series and deleted works; words/language preserved; append and reload boundaries')
