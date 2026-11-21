dofile('tests/test_failures.lua')
local Client=require('ao3lib.ao3.client')
local Parser=require('ao3lib.ao3.comments')
local function node(attrs,content,selectors,parent)
    return {attributes=attrs or {},parent=parent,getcontent=function() return content or '' end,
        select=function(_,s) return (selectors or {})[s] or {} end}
end
local function formRoot(path,id,multiple)
    local inputs={node{name='authenticity_token',value='csrf'}}
    if not multiple then inputs[#inputs+1]=node{name='comment[pseud_id]',value='7'} end
    local select=multiple and {node({name='comment[pseud_id]'},nil,{option={node{value='8'},node{value='9',selected='selected'}}})} or {}
    local form=node({action=path},nil,{input=inputs,select=select})
    return node(nil,nil,{['#comment_for_'..id]={form}})
end
assert(Parser.path('12','34','56')=='/comments/56/comments')
assert(not Parser.path('12/../34'))
local form=Parser.form(formRoot('/works/12/comments','12',true),'12','/works/12/comments')
assert(form.token=='csrf' and form.pseud_id=='9')
assert(not Parser.form(formRoot('/works/13/comments','12'),'12','/works/12/comments'))
local outer=node{class='thread'}
local nested=node({class='thread'},nil,nil,outer)
local comment=node({id='comment_56'},nil,{
    ['h4.byline']={node(nil,'Reader on Chapter 2 · Today',{a={node({href='/users/Reader/pseuds/Reader%20Name'},'Reader Name')}})},['blockquote.userstuff']={node(nil,'Full comment')},
    ['.posted']={node(nil,'Today')},['.parent']={node(nil,'Chapter 2')},['#add_comment_reply_link_56']={node()},
},outer)
local reply=node({id='comment_57'},nil,{['h4.byline']={node(nil,'Author')},['blockquote.userstuff']={node(nil,'Reply')}},nested)
local deleted=node({id='comment_58'},'(Previous comment deleted.)')
local more=node(nil,nil,{a={node({href='/comments/99'},'More comments')}})
local scope=node(nil,nil,{['li.comment']={comment,reply,deleted,more},['a[rel="next"]']={node{href='/works/12/comments?show_comments=true&page=2#comments'}}})
local root=node(nil,nil,{['#main']={node()},['#comments_placeholder']={scope}})
local decode=function(s) return s end
local parsed=Parser.list(root,decode,1)
assert(#parsed.comments==4 and parsed.next_page==2)
assert(parsed.comments[1].username=='Reader' and parsed.comments[1].pseud=='Reader Name' and parsed.comments[1].author=='Reader Name')
assert(parsed.comments[1].can_reply and parsed.comments[1].depth==0)
assert(parsed.comments[2].depth==1 and not parsed.comments[2].can_reply)
assert(parsed.comments[3].text=='(Previous comment deleted.)' and not parsed.comments[3].can_reply)
assert(parsed.comments[4].thread_id=='99')
assert(not Parser.list(node(),decode,1))
local empty=node(nil,nil,{['#main']={node()},['#comments_placeholder']={node(nil,nil,{['li.comment']={}})}})
assert(#Parser.list(empty,decode,1).comments==0)
local original_parse=require('htmlparser').parse
require('htmlparser').parse=function(body)
    if body=='COMMENTS' then return root end
    if body=='FORM' then return formRoot('/works/12/comments','12') end
    if body=='CHAPTER FORM' then return formRoot('/chapters/34/comments','34',true) end
    if body=='REPLY FORM' then return formRoot('/comments/56/comments','56') end
    if body=='LOGIN' then return node(nil,nil,{['body.logged-out']={node()},['#main form']={node{action='/users/login'}}}) end
    return original_parse(body)
end
local requests={}
local code,location,postbody=302,'/comments/101',''
local getbody='COMMENTS'
local outage=false
require('ssl.https').request=function(req)
    local data=req.source and req.source()
    requests[#requests+1]={url=req.url,method=req.method,body=data,headers=req.headers}
    if outage then req.sink('Maintenance');return 1,503,{} end
    if req.url=='https://archiveofourown.org' then req.sink('<body class="logged-in"></body>');return 1,200,{} end
    if req.method=='POST' then req.sink(postbody);return 1,code,{location=location} end
    local b=getbody
    if req.url:find('/new',1,true) then
        b=req.url:find('/chapters/',1,true) and 'CHAPTER FORM' or req.url:find('/comments/56/',1,true) and 'REPLY FORM' or 'FORM'
    end
    req.sink(b);return 1,200,{}
end
local result=Client:getComments('12',nil,2)
assert(result.success and requests[#requests].url:find('show_comments=true&page=2',1,true))
getbody='LOGIN';assert(Client:getComments('12').auth_required)
getbody='unexpected';assert(not Client:getComments('12').auth_required)
getbody='COMMENTS'
for _,args in ipairs{{'Hello & thanks','12'},{'Chapter comment','12','34'},{'A reply','12',nil,'56'}} do
    result=Client:commentOnWork(unpack(args,1,4))
    assert(result.success and result.comment_id=='101')
    local r=requests[#requests]
    assert(r.method=='POST' and r.headers.Referer:match('/comments/new$'))
    assert(not r.headers.Cookie:find('user_credentials=1',1,true))
end
assert(requests[#requests].url:match('/comments/56/comments$'))
code,location=302,'/users/login'
assert(not Client:commentOnWork('Not accepted','12').success)
code,location,postbody=200,nil,'Validation error'
assert(not Client:commentOnWork('Not accepted','12').success)
code=503
local before=#requests
result=Client:commentOnWork('Ambiguous','12')
assert(not result.success and result.submission_uncertain and #requests==before+3)
outage=true
result=Client:getComments('12')
assert(not result.success and not result.auth_required)
local count=#requests
assert(not Client:commentOnWork('  ','12').success and #requests==count)
assert(not Client:commentOnWork(string.rep('á',10001),'12').success and #requests==count)
print('PASS: comment/reply/deleted/thread parsing; pagination; empty pages; form defaults; posting targets; confirmed success only; no POST replay; outages and Unicode length')
