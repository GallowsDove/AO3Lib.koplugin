-- Reuse failure/EPUB validation fixtures, then enable real subprocesses.
package.path='./?.lua;'..package.path
dofile('tests/test_failures.lua')
local H=dofile('tests/support/async.lua')
package.loaded["ao3lib.ao3.background"]=nil
package.loaded["ao3lib.ao3.network"]=nil
package.loaded['ui/network/manager']={isConnected=function() return true end}
local Network=require('ao3lib.ao3.network')
local Client=require('ao3lib.ao3.client')
local Config=require('ao3lib.core.config')
local cookies,saves={},0
Config.readSetting=function(_,key,default)
    if key=='AO3_domain' then return 'https://archiveofourown.org' end
    if key=='cookies' then return cookies end
    return default
end
Config.saveSetting=function(_,key,value)
    assert(not H.inChild(),'The worker must not write settings')
    assert(key=='cookies');cookies=value;saves=saves+1
end
local function element(s) return {getcontent=function() return s end} end
package.loaded.htmlparser.parse=function()
    assert(H.inChild(),'HTML parsing ran in the UI process')
    local user={select=function(_,sel)
        if sel=='h4.heading > a' then return {element('Writer')} end
        if sel:find('/works',1,true) then return {element('2 works')} end
        if sel:find('/bookmarks',1,true) then return {element('1 bookmarks')} end
        return {}
    end}
    return {select=function(_,sel)
        if sel=='#main' then return {{}} elseif sel=='li.user' then return {user} end
        return {}
    end}
end
local requests=os.tmpname()
local function log(line) local f=assert(io.open(requests,'ab'));f:write(line..'\n');f:close() end
local slow,status,body=false,200,'SEARCH'
local cookie_value='updated'
package.loaded['ssl.https'].request=function(req)
    assert(H.inChild(),'HTTPS ran in the UI process')
    log(req.method)
    if slow then H.sleep(80) end
    assert(req.sink(body));req.sink(nil)
    return 1,status,{['set-cookie']='session='..cookie_value..'; Path=/; HttpOnly'}
end
local origin={input='Writer',item_table={}}
H.UI:show(origin)
local result
Network.run(function() result=Client:searchForUsers(origin.input) end)
assert(result==nil)
H.drain()
assert(result.success and result.result_users[1].username=='Writer')
assert(cookies['https://archiveofourown.org'].session.value=='updated' and saves==1)
-- Cancelled searches leave the input and cookies untouched, and do not resume.
slow=true;result=nil
Network.run(function() result=Client:searchForUsers(origin.input) end)
H.tick();H.UI:close(H.stack[#H.stack]);H.drain()
assert(not result and origin.input=='Writer' and saves==1)
slow=false;result=nil
Network.schedule(0,function() result=Client:searchForUsers(origin.input) end)
H.drain()
assert(result.success,'Legacy delayed menu callbacks must keep a network continuation')
-- Account POSTs are attempted only once, including an error response.
Client.GetSessionStatus=function() return {success=true,logged_in=true} end
Client.requestAO3Token=function() return {success=true,token='token'} end
slow=false;status=503;body='<title>Maintenance</title>'
local before=H.read(requests)
Network.run(function() result=Client:markForLaterWork('123',false) end);H.drain()
assert(not result.success)
local sent=H.read(requests):sub(#before+1);assert(sent=='POST\n','A mutating request must never be retried')
-- Downloads commit only in the parent, after the fresh before_commit check.
local destination=os.tmpname()
local function write(s) local f=assert(io.open(destination,'wb'));f:write(s);f:close() end
slow=true;status=200;body='PK\003\004VALID EPUB'
write('OLD')
Network.run(function() result=Client:downloadEpub('https://archiveofourown.org/download/123',destination,true,function()
    assert(not H.inChild(),'before_commit must run against current parent state')
    return H.read(destination)=='OLD','Book changed'
end) end)
H.tick();write('CHANGED');H.drain()
assert(not result.success and H.read(destination)=='CHANGED')
slow=false;write('OLD')
Network.run(function() result=Client:downloadEpub('https://archiveofourown.org/download/123',destination,true,function()
    assert(not H.inChild());return true
end) end);H.drain()
assert(result.success and H.read(destination)==body)
slow=true;write('KEEP');result=nil
Network.run(function() result=Client:downloadEpub('https://archiveofourown.org/download/123',destination,true) end)
H.tick();H.UI:close(H.stack[#H.stack]);H.drain()
assert(not result and H.read(destination)=='KEEP')
-- Use the actual client wrapper in silent scopes, alongside ordinary AO3
-- browsing. Old background cookies must never undo newer foreground cookies.
local Background=require('ao3lib.ao3.background')
local quiet,foreground
local initial_stack=#H.stack
slow=true;status=200;body='SEARCH';cookie_value='older'
Background.wrap(function() quiet=Client:searchForUsers('background') end,{silent=true,detached=true})
local forks=H.forks
while H.forks==forks do H.tick() end
assert(#H.stack==initial_stack,'A detached client request displayed a modal overlay')
slow=false;cookie_value='fresh'
Network.run(function() foreground=Client:searchForUsers('foreground') end)
H.drain()
assert(quiet.success and foreground.success and cookies['https://archiveofourown.org'].session.value=='fresh')
assert(#H.stack==initial_stack)
quiet=nil;foreground=nil
slow=true;cookie_value='foreground'
Network.run(function() foreground=Client:searchForUsers('foreground') end)
forks=H.forks
while H.forks==forks do H.tick() end
slow=false;cookie_value='background'
Background.wrap(function() quiet=Client:searchForUsers('background') end,{silent=true,detached=true})
H.drain()
assert(quiet.success and foreground.success and cookies['https://archiveofourown.org'].session.value=='foreground')
os.remove(requests);os.remove(destination)
assert(#H.warnings==0,'An asynchronous continuation failed')
print('PASS: HTTPS and parsing in real workers; cookies applied only by parent; search cancellation preserves input; POST once; staged downloads recheck/commit only in parent; cancel keeps existing EPUB')
