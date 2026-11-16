-- Run from the plugin directory: luajit tests/test_config.lua
package.path='./?.lua;'..package.path
local function copy(t)
    if type(t)~='table' then return t end
    local out={};for k,v in pairs(t) do out[k]=copy(v) end;return out
end
local function stub(n,v) package.loaded[n]=v end
local disk,exists,generation={version=1,AO3_domain='https://archiveofourown.org',cookies={session='secret'}},true,1
local opens,flushes,closes=0,0,0
stub('datastorage',{getSettingsDir=function() return '/settings' end})
stub('logger',{})
stub('FanficPaths',{getHomeDirectory=function() return '/fanfic' end})
stub('downloaded_fanfics',{updateDownloadFile_1=function() error('Unexpected migration') end})
stub('frontend/util',{fileExists=function() return exists end,makePath=function() end,tableDeepCopy=copy})
stub('libs/libkoreader-lfs',{attributes=function()
    if exists then return {size=100,modification=generation,change=generation} end
end})
stub('luasettings',{open=function()
    opens=opens+1
    local data=copy(disk)
    local store={
        readSetting=function(_,key,default) if data[key]==nil then data[key]=default end;return data[key] end,
        saveSetting=function(_,key,value) data[key]=value end,
        flush=function() disk=copy(data);exists=true;generation=generation+1;flushes=flushes+1 end,
    }
    function store:close() closes=closes+1;self:flush() end
    return store
end})
local Config=require('fanfic_config')
local initial_opens,initial_flushes=opens,flushes
for _=1,1000 do assert(Config:readSetting('AO3_domain')=='https://archiveofourown.org') end
assert(opens==initial_opens and flushes==initial_flushes and closes==0,
    'Repeated settings reads must not reopen or rewrite the file')
assert(Config:readSetting('missing')==nil)
assert(Config:readSetting('show_adult_warning',false)==false,'Explicit false default must be respected')
assert(Config:readSetting('show_adult_warning')==true)
assert(flushes==initial_flushes,'Reading missing defaults must not write settings')
-- Neither returned tables, defaults, nor saved inputs may mutate the cache.
local cookies=Config:readSetting('cookies');cookies.session='edited'
assert(Config:readSetting('cookies').session=='secret')
local default={nested={value='default'}}
local value=Config:readSetting('missing',default);value.nested.value='changed'
assert(default.nested.value=='default')
Config:saveSetting('cookies',cookies)
assert(flushes==initial_flushes+1 and closes==0)
cookies.session='later edit'
assert(Config:readSetting('cookies').session=='edited' and disk.cookies.session=='edited')
Config:saveSetting('show_adult_warning',false)
assert(Config:readSetting('show_adult_warning')==false)
-- Edits made from a PC are still picked up when filesystem stamps change.
disk.AO3_domain='https://example.test';generation=generation+1
local before=opens
assert(Config:readSetting('AO3_domain')=='https://example.test' and opens==before+1)
assert(flushes==initial_flushes+2)
-- Fresh install writes defaults once, rather than flush + close (another flush).
package.loaded.fanfic_config=nil;disk={};exists=false
before=flushes
Config=require('fanfic_config')
assert(flushes==before+1 and Config:readSetting('author_folders')==true)
assert(disk.filename_template=='%I' and disk.version==1)
print('PASS: 1000 setting reads use one cached load and zero writes; single explicit saves; external edits; false defaults; table isolation; fresh install')
