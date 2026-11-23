dofile('tests/test_failures.lua')
local function findParser(fn,seen)
    seen=seen or {};if seen[fn] then return end;seen[fn]=true
    for i=1,100 do
        local name,value=debug.getupvalue(fn,i)
        if not name then break end
        if name=='AO3WebParser' then return value end
        if type(value)=='function' then local parser=findParser(value,seen);if parser then return parser end end
    end
end
local Parser=assert(findParser(require('ao3lib.ao3.client').getWorkMetadata))
local function node(content,attrs,selectors)
    return {attributes=attrs or {},getcontent=function() return content or '' end,
        select=function(_,s) return (selectors or {})[s] or {} end}
end
local title=node('Story',{href='/works/123'})
local toggle=node('Show warnings',{href='/tags/show_hidden?creation_id=123&amp;creation_type=Work&amp;tag_type=warnings'})
local symbol=node('',{title='Graphic Depictions Of Violence, Major Character Death'})
local hidden=node('',nil,{['h4.heading > a']={title},['.tags > .warnings strong > a']={toggle},['.required-tags .warnings']={symbol}})
local work=Parser:parseWorkElement(hidden)
assert(#work.warnings==0 and work.warnings_hidden)
local localized=node('Afficher les avertissements',toggle.attributes)
assert(#Parser:parseArchiveWarnings(hidden,{localized})==0)
local visible=node('No Archive Warnings Apply',{href='/tags/No%20Archive%20Warnings%20Apply/works'})
local warnings=Parser:parseArchiveWarnings(hidden,{visible,visible})
assert(#warnings==1 and warnings[1]=='No Archive Warnings Apply','Visible tags take precedence over symbols')
assert(#Parser:parseArchiveWarnings(node(),{toggle})==0,'Missing data must stay unknown rather than becoming a reveal label')
local detail=node('',nil,{['#workskin .title']={title},['.title']={title},['.warning > ul a']={visible}})
assert(Parser:parseWorkPage(detail).warnings[1]=='No Archive Warnings Apply')
local tags=node('',nil,{a={node('Fluff, with a comma',{href='/tags/fluff'}),node('Comfort',{href='/tags/comfort'})}})
local detail_tags=node('',nil,{['#workskin .title']={title},['.title']={title},['.freeform > ul']={tags}})
local exact=Parser:parseWorkPage(detail_tags)
assert(#exact.tag_names==2 and exact.tag_names[1]=='Fluff, with a comma' and exact.tag_names[2]=='Comfort',
    'Work metadata must retain individual tags, including commas in a name')
local freeform=node('Show additional tags',{href='/tags/show_hidden?creation_id=123&tag_type=freeforms'})
local tagset=node('',nil,{a={freeform}})
local both=node('',nil,{['h4.heading > a']={title},['.tags > .warnings strong > a']={toggle},['.tags > .freeforms']={tagset}})
local hidden_work=Parser:parseWorkElement(both)
assert(hidden_work.tags_hidden and hidden_work.warnings_hidden)
local detail_hidden=node('',nil,{['#workskin .title']={title},['.title']={title},['.warning > ul a']={toggle},['.freeform > ul']={tagset}})
assert(Parser:parseWorkPage(detail_hidden).tags_hidden and Parser:parseWorkPage(detail_hidden).warnings_hidden)
dofile('tests/test_network.lua')
local Browser=require('ao3lib.ui.work_browser')
local rows=Browser:generateTable({}, {work},function() end,function() end)
local html=require('ao3lib.ui.work_view').html(work,rows)
assert(not html:find('Graphic Depictions Of Violence',1,true) and html:find('Show warnings',1,true))
print('PASS: warning preference respected; visible tags preferred; localized reveal controls recognized; unknown preserved; rendered reveal link')

local Client=require('ao3lib.ao3.client')
local requests,reloads={},0
Browser.browse_window={reload=function() reloads=reloads+1 end}
Client.getHiddenTags=function(_,id,kind)
    requests[#requests+1]={id=id,kind=kind}
    return {success=true,tags=kind=='warnings' and {'Major Character Death'} or {'Slow Burn','Friends to Lovers'}}
end
local View=require('ao3lib.ui.work_view')
rows=Browser:generateTable({}, {hidden_work},function() end,function() end)
local actions
html,actions=View.html(hidden_work,rows)
assert(html:find('Show warnings',1,true) and html:find('Show additional tags',1,true))
assert(#actions==4) -- title, author, and the two reveal links
assert(not html:find('Major Character Death',1,true) and not html:find('Slow Burn',1,true))
actions[3]()
assert(requests[1].kind=='warnings' and not hidden_work.warnings_hidden and hidden_work.tags_hidden and reloads==1)
rows=Browser:generateTable({}, {hidden_work},function() end,function() end)
html,actions=View.html(hidden_work,rows)
assert(html:find('Major Character Death',1,true) and html:find('Show additional tags',1,true))
actions[3]()
assert(requests[2].kind=='freeforms' and not hidden_work.tags_hidden and reloads==2)
rows=Browser:generateTable({}, {hidden_work},function() end,function() end)
html=View.html(hidden_work,rows)
assert(html:find('Slow Burn',1,true) and html:find('Friends to Lovers',1,true) and not html:find('Show additional tags',1,true))
hidden_work.tags_hidden=true
Client.getHiddenTags=function() return {success=false,error='Maintenance'} end
rows=Browser:generateTable({}, {hidden_work},function() end,function() end)
for _,row in ipairs(rows) do if row[1]=='     Other Tags:' then row.callback() end end
assert(hidden_work.tags_hidden and reloads==2)
print('PASS: warnings and freeforms reveal independently; current page reloads; failed reveal keeps the control and hidden state')
