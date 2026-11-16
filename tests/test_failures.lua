-- Run from the plugin directory: luajit tests/test_failures.lua
package.path = './?.lua;' .. package.path
local function stub(name, value) package.loaded[name] = value end
local queue, calls, resets, parses, warnings = {}, {}, 0, 0, 0
local function enqueue(...) for _,r in ipairs({...}) do queue[#queue+1] = r end end
local function response(status, body, headers) return {status=status,body=body or '',headers=headers or {}} end
stub('ssl.https', {request=function(req)
    assert(req.redirect == false)
    calls[#calls+1] = {url=req.url,method=req.method}
    local r = assert(table.remove(queue,1), 'unexpected request')
    if r.throw then error('TLS exception') end
    if r.body then assert(req.sink(r.body)) end
    if r.after then r.after() end
    if r.timeout then return nil, 'timeout' end
    return 1, r.status, r.headers
end})
stub('socketutil', {FILE_BLOCK_TIMEOUT=15,FILE_TOTAL_TIMEOUT=60,
    set_timeout=function() end, reset_timeout=function() resets=resets+1 end})
stub('socket.url', {absolute=function(base,rel)
    if rel:match('^https?://') then return rel end
    return base:match('^https?://[^/]+') .. rel
end})
stub('ffi/util', {template=function(s,...)
    local args={...}; return (s:gsub('%%(%d)',function(i) return tostring(args[tonumber(i)]) end))
end})
stub('logger',{dbg=function() end,warn=function() warnings=warnings+1 end})
local settings={cookies={}}
stub('fanfic_config',{readSetting=function(_,key)
    if key=='AO3_domain' then return 'https://archiveofourown.org' end
    return settings[key]
end,saveSetting=function(_,key,value) settings[key]=value end})
stub('util',{})
stub('ltn12',{sink={table=function(t) return function(chunk) if chunk then t[#t+1]=chunk end; return 1 end end},
    source={string=function(s) local sent=false; return function() if not sent then sent=true; return s end end end}})
stub('dkjson',{decode=function(s)
    if s=='TOKEN' then return {token='csrf'} end
    if s=='COLLECTIONS' then return {{name='Collection'}} end
    return nil,1,'invalid JSON'
end})
local function element(content, attrs) return {getcontent=function() return content end, attributes=attrs or {}} end
stub('htmlparser',{parse=function(body)
    parses=parses+1
    if body=='PARSER EXCEPTION' then error('malformed HTML') end
    return {select=function(_,selector)
        if (body=='PROFILE' or body=='BROKEN PROFILE') and selector=='div.primary > h2.heading' then return {element('Writer')} end
        if body=='PROFILE' and selector=="[href$='Writer/bookmarks']" then return {element('My Bookmarks')} end
        if body=='BROKEN PROFILE' and selector=='div #user-fandoms > ol > li' then
            return {{select=function() return {} end}}
        end
        if (body=='SEARCH' or body=='SESSION' or body:find('logged%-in')) and selector=='#main' then return {element('main')} end
        if body=='SEARCH' and selector=='#main > h3' then return {element('0 Found')} end
        if body:find('logged%-in') and selector=='body.logged-in' then return {element('body')} end
        if body:find('logged%-in') and selector=='a[href^="/users/"]' then return {element('Writer',{href='/users/Writer'})} end
        return {}
    end}
end})
local Client=require('AO3_downloader_client')
local function fails(result, match)
    assert(result.success==false and type(result.error)=='string')
    if match then assert(result.error:find(match,1,true), result.error) end
end
local maintenance='<html><title>AO3 is undergoing maintenance</title><body>Try later</body></html>'
local before=parses
enqueue(response(503,maintenance))
fails(Client:getUserData('Writer','Writer'),'maintenance')
assert(parses==before and #queue==0)
enqueue(response(200,maintenance))
fails(Client:getUserData('Writer','Writer'),'maintenance')
assert(parses==before)
enqueue(response(500,'error'))
fails(Client:searchByTag('tag','title'),'500')
enqueue(response(429,'rate limit'))
fails(Client:searchForUsers('Writer'),'429')
enqueue(response(404,'not found'))
fails(Client:getUserData('Writer','Writer'),'not found')
enqueue({throw=true})
fails(Client:getUserData('Writer','Writer'),'connect')
enqueue({timeout=true,body='partial response'})
fails(Client:getUserData('Writer','Writer'),'connect')
assert(resets==#calls, 'socket timeouts must be reset after every request')
-- Unknown layouts, optional profile sections, and parser exceptions.
enqueue(response(200,'unexpected page'))
fails(Client:getUserData('Writer','Writer'),'unexpected response')
enqueue(response(200,'PARSER EXCEPTION'))
fails(Client:getUserData('Writer','Writer'),'unexpected response')
enqueue(response(200,'BROKEN PROFILE'))
fails(Client:getUserData('Writer','Writer'),'unexpected response')
enqueue(response(200,'PROFILE'))
local user=Client:getUserData('Writer','Writer')
assert(user.success and user.user_data.username=='Writer' and user.user_data.total_bookmarks==0)
enqueue(response(200,'unexpected work page'))
fails(Client:getWorkMetadata('123'),'unexpected response')
enqueue(response(429,'rate limit',{['retry-after']='120'}))
local limited=Client:getWorkMetadata('123')
assert(not limited.success and limited.status==429 and limited.retry_later and limited.response_headers['retry-after']=='120')
enqueue(response(404,'missing work'))
local missing=Client:getWorkMetadata('123')
assert(not missing.success and missing.status==404 and not missing.retry_later)
enqueue(response(200,maintenance))
assert(Client:getWorkMetadata('123').retry_later)
enqueue(response(200,'unexpected search page'))
fails(Client:searchForUsers('Writer'),'unexpected response')
enqueue(response(200,'SEARCH'))
assert(Client:searchByTag('tag','title').success)
enqueue(response(200,'bad JSON'))
fails(Client:searchForCollections('Collection'),'parse collection')
enqueue(response(200,'COLLECTIONS'))
assert(Client:searchForCollections('Collection').collections[1].name=='Collection')
-- Redirect bodies must not contaminate the actual HTML response.
enqueue(response(301,'old page',{location='/moved'}),response(302,'other page',{location='/new'}),response(200,'PROFILE'))
assert(Client:getUserData('Writer','Writer').success)
assert(calls[#calls].url=='https://archiveofourown.org/new')
for i=1,6 do enqueue(response(301,'loop',{location='/loop'})) end
fails(Client:getUserData('Writer','Writer'),'too many')
enqueue(response(301,'missing destination'))
fails(Client:getUserData('Writer','Writer'),'destination')
-- POST failures are never replayed, and intentional login 302s remain visible.
local Http=require('fanfic_http')
local handler={get_default_headers=function() return {} end,getCookies=function() return '' end,setCookies=function() end}
local data={}
before=#calls
enqueue({timeout=true})
fails(Http.request({url='https://archiveofourown.org/comments',method='POST',sink=function(s) data[#data+1]=s; return 1 end},handler,3))
assert(#calls==before+1 and #data==0)
enqueue(response(302,'',{location='https://archiveofourown.org/users/Writer'}))
local posted=Http.request({url='https://archiveofourown.org/users/login',method='POST',sink=function() return 1 end},handler)
assert(posted.success and posted.status==302)
enqueue(response(200,'SESSION'),response(200,'TOKEN'),response(302,'',{location='https://archiveofourown.org/users/Writer'}),response(200,'<body class="logged-in"></body>'))
assert(Client:startLoggedInSession('Writer','password').success)
enqueue(response(200,'<body class="logged-in"></body>'),response(200,'TOKEN'),response(503,maintenance))
fails(Client:setWorkSubscription('123',nil),'maintenance')
-- Downloads are staged: failures, maintenance pages, invalid ZIPs, and partial
-- transfers must preserve an existing book and clean up the staging file.
local partials={}
local realOpen=io.open
io.open=function(path,mode)
    if path:find('.ao3-',1,true) then partials[path]=true end
    return realOpen(path,mode)
end
local Reader={}
function Reader:new() return setmetatable({}, {__index=self}) end
function Reader:open(path)
    local file=assert(realOpen(path,'rb')); local content=file:read('*a'); file:close()
    self.valid=content=='PK\003\004VALID EPUB'
    self.entries=self.valid and {['META-INF/container.xml']={},mimetype={}} or {}
    return self.valid
end
function Reader:iterate() return function() return nil end end
function Reader:extractToMemory() return 'application/epub+zip' end
function Reader:close() end
stub('ffi/archiver',{Reader=Reader})
local destination=os.tmpname()
local function writeOld()
    local file=assert(realOpen(destination,'wb')); file:write('EXISTING BOOK'); file:close()
end
local function content()
    local file=assert(realOpen(destination,'rb')); local s=file:read('*a'); file:close(); return s
end
writeOld()
enqueue(response(200,'PK\003\004VALID EPUB'))
fails(Client:downloadEpub('https://archiveofourown.org/downloads/123.epub',destination,true,
    function() return nil,'Source changed during download' end),'Source changed')
assert(content()=='EXISTING BOOK')
for path in pairs(partials) do assert(realOpen(path,'rb')==nil) end
for _,r in ipairs({response(503,maintenance),response(200,maintenance),response(200,'<html>Login required</html>'),
    response(200,'PK\003\004TRUNCATED ZIP'),{timeout=true,body='PK\003\004partial'}, {throw=true}}) do
    enqueue(r)
    fails(Client:downloadEpub('https://archiveofourown.org/downloads/123.epub',destination))
    assert(content()=='EXISTING BOOK')
    for path in pairs(partials) do assert(realOpen(path,'rb')==nil, 'staging file leaked') end
end
enqueue(response(302,'redirect body',{location='/downloads/new.epub'}),response(200,'PK\003\004VALID EPUB'))
assert(Client:downloadEpub('https://archiveofourown.org/downloads/123.epub',destination).success)
assert(content()=='PK\003\004VALID EPUB')
for path in pairs(partials) do assert(realOpen(path,'rb')==nil) end
-- A new download may not overwrite a file that appears after path planning.
stub('libs/libkoreader-lfs',{attributes=function(path)
    local f=realOpen(path,'rb'); if f then f:close(); return 'file' end
end})
before=#calls
fails(Client:downloadEpub('https://archiveofourown.org/downloads/123.epub',destination,false),'occupied')
assert(#calls==before)
os.remove(destination)
local late=response(200,'PK\003\004VALID EPUB')
late.after=writeOld
enqueue(late)
fails(Client:downloadEpub('https://archiveofourown.org/downloads/123.epub',destination,false),'occupied')
assert(content()=='EXISTING BOOK')
for path in pairs(partials) do assert(realOpen(path,'rb')==nil) end
io.open=realOpen
os.remove(destination)
assert(#queue==0 and resets==#calls)
assert(warnings>0)
print('PASS: 503/500/429/404; maintenance HTML; malformed profiles/search/JSON; parser/TLS failures; timeout cleanup; bounded redirects; POST safety; atomic EPUB updates')
