dofile('tests/test_failures.lua')
local Client=require('ao3lib.ao3.client')
local Parser=require('ao3lib.ao3.subscriptions')
local function node(attrs,content,selectors)
    return {attributes=attrs or {},getcontent=function() return content or '' end,
        select=function(_,s) return (selectors or {})[s] or {} end}
end
local function targetForm(kind,id,subscription)
    return node({action='/users/Writer/subscriptions'..(subscription and '/'..subscription or '')},'',{
        input={node{name='subscription[subscribable_type]',value=kind},node{name='subscription[subscribable_id]',value=id}},
    })
end
local userRoot=node(nil,nil,{form={targetForm('User','17','45')}})
local seriesRoot=node(nil,nil,{form={targetForm('Series','21')}})
assert(Parser.form(userRoot,'User').subscription_id=='45')
assert(Parser.form(seriesRoot,'Series').target_id=='21' and not Parser.form(seriesRoot,'Series').subscription_id)
assert(not Parser.form(userRoot,'Series'))
assert(Parser.target('User','Writer')=='/users/Writer')
assert(not Parser.target('User','../Writer') and not Parser.target('Series','21?bad'))
local dt,dd={},{}
for i,kind in ipairs{'Work','Series','User','Unavailable'} do
    local href=({Work='/works/11',Series='/series/21',User='/users/Writer'})[kind]
    dt[i]=node(nil,'Deleted title', {a=href and {node({href=href},kind..' title')} or {}})
    dd[i]=node(nil,nil,{form={node{action='/users/Writer/subscriptions/'..i}}})
end
local list=node(nil,nil,{dt=dt,dd=dd})
local index=node(nil,nil,{['#main']={node()},['dl.subscription']={list},['a[rel="next"]']={node{href='/users/Writer/subscriptions?page=2'}}})
local decode=function(v) return v end
local parsed=Parser.list(index,decode,1)
assert(#parsed.subscriptions==4 and parsed.next_page==2)
assert(parsed.subscriptions[3].kind=='User' and parsed.subscriptions[3].target=='Writer')
assert(parsed.subscriptions[4].kind=='Unavailable' and parsed.subscriptions[4].subscription_id=='4')
assert(not Parser.list(node(),decode,1))
local empty=node(nil,nil,{['#main']={node()},['dl.subscription']={node(nil,nil,{dt={},dd={}})}})
assert(#Parser.list(empty,decode,1).subscriptions==0)
-- Exercise the real HTTP path and encoding, including account recovery flags.
local requests={}
local response_body,response_code='CREATED',201
local json=require('dkjson');local original_decode=json.decode
json.decode=function(value)
    if value=='CREATED' then return {item_id=88} end
    if value=='DELETED' then return {item_success_message='Unsubscribed'} end
    return original_decode(value)
end
local original_parse=require('htmlparser').parse
require('htmlparser').parse=function(body)
    if body=='USER' then return userRoot end
    if body=='SERIES' then return seriesRoot end
    if body=='INDEX' then return index end
    return original_parse(body)
end
require('ssl.https').request=function(req)
    requests[#requests+1]={url=req.url,method=req.method,body=req.source and req.source()}
    local body,code=response_body,response_code
    if req.url:match('/token_dispenser.json$') then body,code='TOKEN',200
    elseif req.url=='https://archiveofourown.org' then body,code='<body class="logged-in"></body>',200
    elseif req.method=='GET' then
        code=200;body=req.url:match('/series/') and 'SERIES' or req.url:match('/subscriptions') and 'INDEX' or 'USER'
    end
    req.sink(body);return 1,code,{}
end
for _,kind in ipairs{'User','Series','Work'} do
    local result=Client:setSubscription(kind,'17')
    assert(result.success and result.subscription_id=='88')
    local r=requests[#requests]
    assert(r.method=='POST' and r.body:find('subscription%%5Bsubscribable_type%%5D='..kind))
    assert(r.body:find('subscription%%5Bsubscribable_id%%5D=17'))
end
response_body,response_code='DELETED',200
assert(Client:deleteSubscription('45').success)
assert(requests[#requests].url:match('/subscriptions/45$') and requests[#requests].body:find('_method=delete',1,true))
assert(not requests[#requests].body:find('subscribable',1,true))
response_body,response_code='Unexpected login HTML',200
assert(not Client:deleteSubscription('45').success)
response_body,response_code='Maintenance',503
local before=#requests
assert(not Client:setSubscription('Series','17').success)
assert(#requests==before+3,'A failed POST must never be replayed')
assert(Client:getSubscriptionTarget('User','Writer').subscription_id=='45')
assert(Client:getSubscriptionTarget('Series','21').target_id=='21')
local subs=Client:getSubscriptions(2,'Series')
assert(subs.success and #subs.subscriptions==4)
assert(requests[#requests].url:find('page=2&type=series',1,true))
before=#requests
assert(not Client:setSubscription('Invalid','1').success and #requests==before)
print('PASS: subscription forms, mixed/deleted/empty lists, pagination, types, HTTP encoding, verified deletion, failed POST safety')
