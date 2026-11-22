package.path='./?.lua;'..package.path
local values={tag_blacklist_enabled=true,tag_blacklist={
    {type='Freeform',name='A tag, with commas'},
    {type='Relationship',name='Alice/Bob'},
}}
package.loaded['ao3lib.core.config']={readSetting=function(_,key,default)
    if values[key]~=nil then return values[key] end;return default
end}
package.loaded.gettext=function(s) return s end
package.loaded['ao3lib.ao3.work_paging']={get=function() end}
local Blacklist=require('ao3lib.library.blacklist')
local excluded=Blacklist.exclusions({'Other','alice/bob'})
assert(#excluded==3 and excluded[1]=='Other' and excluded[3]=='A tag, with commas')
local work={id=42,title='Secret',tag_names={'A tag, with commas'},tags='A tag, with commas, Another',relationships={}}
assert(Blacklist.match(work)[1]=='A tag, with commas')
assert(#Blacklist.match{tag_names={'A tag, with commas and more'}}==0)
assert(Blacklist.match{relationships={'ALICE/BOB'}}[1]=='Alice/Bob')
local conflicts=Blacklist.conflicts{additional_tags={'a TAG, WITH commas'},relationships={'ALICE/BOB'}}
assert(#conflicts==2 and conflicts[1]=='A tag, with commas' and conflicts[2]=='Alice/Bob')
values.tag_blacklist_enabled=false
assert(#Blacklist.match(work)==0 and #Blacklist.exclusions({'Other'})==1)
assert(#Blacklist.conflicts{relationships={'Alice/Bob'}}==0)
values.tag_blacklist_enabled=true
values.tag_blacklist={
    {type='Rating',name='Explicit'},{type='Category',name='M/M'},
    {type='Warning',name='Creator Chose Not To Use Archive Warnings'},
    {type='Freeform',name='A tag, with commas'},{type='Relationship',name='Alice/Bob'},
}
local special=Blacklist.match{rating='Explicit',category='F/M, M/M',
    warnings={'Creator Choose Not To Use Archive Warnings'}}
assert(#special==3 and special[1]=='Explicit' and special[2]=='M/M')
assert(#Blacklist.match{rating='Mature',category='F/M',warnings={'No Archive Warnings Apply'}}==0)
assert(#Blacklist.conflicts{rating='13',categories={'23'},warnings={'14'}}==3)
local special_excluded=Blacklist.exclusions({})
assert(special_excluded[1]=='Explicit' and special_excluded[2]=='M/M')
work.relationships={'Alice/Bob'}
assert(#Blacklist.match(work)==2)
local view=require('ao3lib.ui.work_view')
local calls,shown=0
local context={works={work},blacklist=true,rows=function()
    calls=calls+1;return {{'Visible title',''}}
end,present=function(_,html,actions,rows) shown={html=html,actions=actions,rows=rows} end}
local state=view.new(context);state:render()
assert(calls==0 and not shown.html:find('Secret',1,true) and shown.html:find('A tag, with commas',1,true))
assert(shown.html:find('Alice/Bob',1,true) and shown.rows[1][2]:find('Alice/Bob',1,true))
assert(shown.rows[1].callback and shown.actions[1])
shown.actions[1]();assert(calls==1 and not shown.html:find('Hidden work',1,true))
state:render();assert(calls==2,'Revealed work should stay visible during browsing')
context.blacklist=false;state=view.new(context);state:render()
assert(calls==3,'Downloaded/local views must bypass the blacklist')
print('PASS: blacklist matching, exclusions, visibility, reveal and local-work bypass')
