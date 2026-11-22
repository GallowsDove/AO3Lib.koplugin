dofile('tests/test_failures.lua')
local Client=require('ao3lib.ao3.client')
local Parser=require('ao3lib.ao3.favorite_tags')
local function node(attrs,content,selectors)
    return {attributes=attrs or {},getcontent=function() return content or '' end,
        select=function(_,selector) return (selectors or {})[selector] or {} end}
end
local function form(id,tag_id)
    local inputs={node{name='favorite_tag[tag_id]',value=tag_id or '123'}}
    if id then inputs[#inputs+1]=node{name='_method',value='delete'} end
    return node({action='/users/Writer/favorite_tags'..(id and '/'..id or '')},nil,{input=inputs})
end
local function formRoot(id) return node(nil,nil,{['#main']={node()},form={form(id)}}) end
local links={node({href='/tags/A%20Fandom/works'},'A Fandom'),node({href='/tags/Slow%20Burn/works'},'Slow Burn')}
local home=node(nil,nil,{['#main']={node()},['body.logged-in']={node()},
    ['div.favorite.module']={node(nil,nil,{a=links})},['a[href^="/users/"]']={node{href='/users/Writer'}}})
local empty=node(nil,nil,{['#main']={node()},['body.logged-in']={node()},['div.browse.module']={node()}})
assert(#Parser.list(home,function(s) return s end)==2)
assert(#Parser.list(empty,function(s) return s end)==0 and not Parser.list(node(),function(s) return s end))
assert(Parser.form(formRoot(nil),'Writer').tag_id=='123')
assert(Parser.form(formRoot('45'),'Writer').favorite_id=='45')
assert(not Parser.form(formRoot('45'),'SomeoneElse') and not Parser.form(formRoot(nil),'../Writer'))
local requests={}
local active_favorite=false
local fail_code
local original_parse=require('htmlparser').parse
require('htmlparser').parse=function(body)
    if body=='FAVORITE HOME' then return home end
    if body=='FAVORITE FORM' then return formRoot(active_favorite and '45' or nil) end
    return original_parse(body)
end
local json=require('dkjson');local original_decode=json.decode
json.decode=function(body)
    if body=='CREATED' then return {item_id=45} end
    if body=='DELETED' then return {item_success_message='Removed'} end
    return original_decode(body)
end
require('ssl.https').request=function(req)
    requests[#requests+1]={url=req.url,method=req.method,body=req.source and req.source()}
    local body,code
    if req.url:find('token_dispenser',1,true) then body,code='TOKEN',200
    elseif req.method=='POST' then body,code=active_favorite and 'DELETED' or 'CREATED',fail_code or (active_favorite and 200 or 201)
    elseif req.url=='https://archiveofourown.org' then body,code='FAVORITE HOME',200
    else body,code='FAVORITE FORM',200 end
    req.sink(body);return 1,code,{}
end
local result=Client:getFavoriteTags()
assert(result.success and #result.tags==2 and result.tags[1].name=='A Fandom')
result=Client:setFavoriteTag('A/B & C',true)
assert(result.success and result.favorited)
local request=requests[#requests]
assert(request.url=='https://archiveofourown.org/users/Writer/favorite_tags' and request.method=='POST')
assert(request.body:find('favorite_tag%%5Btag_id%%5D=123') and request.body:find('authenticity_token=csrf',1,true))
local page
for _,item in ipairs(requests) do if item.url:find('/tags/',1,true) then page=item.url end end
assert(page:find('A%2As%2AB%20%2Aa%2A%20C',1,true),'AO3 tag path must escape slashes and ampersands')
active_favorite=true
assert(Client:setFavoriteTag('A/B & C',false).success)
request=requests[#requests]
assert(request.url:match('/favorite_tags/45$') and request.body:find('_method=delete',1,true))
active_favorite=false;fail_code=422
result=Client:setFavoriteTag('A Fandom',true)
assert(not result.success and result.error:find('20 favorites',1,true))
Client.GetSessionStatus=function() return {success=true,logged_in=false} end
result=Client:getFavoriteTags(true)
assert(not result.success and not result.auth_required,'Silent highlighting must not prompt for login')
result=Client:getFavoriteTags()
assert(not result.success and result.auth_required,'Explicit favorite browsing must still offer login')
print('PASS: AO3 favorites homepage, empty state, authenticated create/delete, encoded tag paths and limit errors')
