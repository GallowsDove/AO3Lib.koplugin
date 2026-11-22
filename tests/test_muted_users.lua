dofile('tests/test_failures.lua')
local Client=require('ao3lib.ao3.client')
local Parser=require('ao3lib.ao3.muted_users')
local function node(attrs,content,selectors)
    return {attributes=attrs or {},getcontent=function() return content or '' end,
        select=function(_,key) return (selectors or {})[key] or {} end}
end
local function list(entries,next_page)
    local items={}
    for _,entry in ipairs(entries) do items[#items+1]=node(nil,nil,{a={
        node{href='/users/'..entry.name..'/pseuds/Pseud'},
        node{href='/users/Writer/muted/users/'..entry.id..'/confirm_unmute'},
    }}) end
    local nextlinks=next_page and {node({href='?page='..next_page,rel='next'},'Next')} or {}
    return node(nil,nil,{['#main']={node()},form={node{action='/users/Writer/muted/users/confirm_mute'}},
        ['li.user.pseud.blurb']=items,['ol.pagination a']=nextlinks})
end
local function confirm(action,delete)
    return node(nil,nil,{form={node({action=action},nil,{input=delete and {node{name='_method',value='delete'}} or {}})}})
end
local entries,next_page=Parser.page(list({{name='Muted',id='12'}},2),'Writer')
assert(entries[1].name=='Muted' and entries[1].id=='12' and next_page==2)
assert(not Parser.page(node(),'Writer'))
assert(Parser.confirm(confirm('/users/Writer/muted/users?muted_id=Muted'),'/users/Writer/muted/users',false))
assert(not Parser.confirm(confirm('/evil?muted_id=x'),'/users/Writer/muted/users',false))
local original=require('htmlparser').parse
local muted=false
require('htmlparser').parse=function(body)
    if body=='LIST' then return list(muted and {{name='Muted',id='12'}} or {}) end
    if body=='CONFIRM' then return confirm(muted and '/users/Writer/muted/users/12' or '/users/Writer/muted/users?muted_id=Muted',muted) end
    return original(body)
end
Client.GetSessionStatus=function() return {success=true,logged_in=true,username='Writer'} end
Client.requestAO3Token=function() return {success=true,token='csrf'} end
local requests={}
require('ssl.https').request=function(req)
    local body,code
    requests[#requests+1]={url=req.url,method=req.method,body=req.source and req.source()}
    if req.url:find('token_dispenser',1,true) then body,code='TOKEN',200
    elseif req.method=='POST' then muted=not muted;body,code='OK',200
    elseif req.url:find('confirm_',1,true) then body,code='CONFIRM',200
    else body,code='LIST',200 end
    req.sink(body);return 1,code,{}
end
local result=Client:setMutedUser('Muted',true)
assert(result.success and result.users[1].name=='Muted')
local posted
for _,req in ipairs(requests) do if req.method=='POST' then posted=req end end
assert(posted.url:find('muted_id=Muted',1,true) and posted.body:find('authenticity_token=csrf',1,true))
result=Client:setMutedUser('Muted',false)
assert(result.success and #result.users==0)
for _,req in ipairs(requests) do if req.method=='POST' then posted=req end end
assert(posted.url:match('/muted/users/12$') and posted.body:find('_method=delete',1,true))
assert(not Client:setMutedUser('../unsafe',true).success)
print('PASS: mute list parsing, pagination, confirmation validation, authenticated mute and unmute')
