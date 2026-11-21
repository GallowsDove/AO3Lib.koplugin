dofile('tests/test_failures.lua')
local Hidden=require('ao3lib.ao3.hidden_tags')
local js='$j("#work_123_category_freeforms").replaceWith("<li class=\\"freeforms\\"><a class=\\"tag\\" href=\\"/tags/Slow%20Burn/works\\">Slow Burn<\\/a><\\/li>");'
local fragment=assert(Hidden.fragment(js,'123','freeforms'))
assert(fragment=='<li class="freeforms"><a class="tag" href="/tags/Slow%20Burn/works">Slow Burn</a></li>')
assert(not Hidden.fragment(js,'124','freeforms'))
assert(not Hidden.fragment(js..'alert(1);','123','freeforms'))
assert(not Hidden.fragment('Unexpected response','123','freeforms'))
assert(Hidden.fragment('$j("#work_123_category_warnings").replaceWith("");','123','warnings')=='')
local Client=require('ao3lib.ao3.client')
local parse=require('htmlparser').parse
require('htmlparser').parse=function(html)
    if html==fragment then return {select=function(_,selector)
        assert(selector=='li.freeforms a.tag')
        return {{getcontent=function() return 'Slow Burn' end}}
    end} end
    return parse(html)
end
local requests={}
local response,status=js,200
require('ssl.https').request=function(req)
    requests[#requests+1]=req
    -- Rails rejects JavaScript GET responses unless the request is XHR.
    if req.headers['X-Requested-With']~='XMLHttpRequest' then
        req.sink('Invalid cross-origin JavaScript request');return 1,422,{}
    end
    req.sink(response);return 1,status,{}
end
local tags=Client:getHiddenTags('123','freeforms')
assert(tags.success and tags.tags[1]=='Slow Burn')
assert(requests[1].url=='https://archiveofourown.org/tags/show_hidden.js?creation_type=Work&creation_id=123&tag_type=freeforms')
assert(requests[1].method=='GET' and requests[1].headers.Accept=='text/javascript')
assert(requests[1].headers['X-Requested-With']=='XMLHttpRequest')
response='$j("#work_123_category_warnings").replaceWith("");'
local warnings=Client:getHiddenTags('123','warnings')
assert(warnings.success and #warnings.tags==0)
assert(requests[2].headers['X-Requested-With']=='XMLHttpRequest' and requests[2].url:find('tag_type=warnings',1,true))
status=422
local rejected=Client:getHiddenTags('123','warnings')
assert(not rejected.success and rejected.status==422 and not rejected.auth_required)
status=200
response='<title>Maintenance</title>'
local result=Client:getHiddenTags('123','warnings')
assert(not result.success and not result.auth_required)
response='Invalid response'
assert(not Client:getHiddenTags('123','freeforms').success)
local count=#requests
assert(not Client:getHiddenTags('../123','freeforms').success and #requests==count)
assert(not Client:getHiddenTags('123','unknown').success and #requests==count)
print('PASS: AO3 replacement response decoded without JS execution; response/target validation; read-only requests; unavailable responses; invalid inputs')
