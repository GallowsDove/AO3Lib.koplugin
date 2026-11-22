-- Mutes are account data: never persist them between KOReader sessions.
local M={}
local values,username,domain,loaded_at,loading,last_attempt=nil,nil,nil,nil,false,nil
local generation=0
local listeners=setmetatable({}, {__mode='k'})
local function normalize(name)
    return tostring(name or ''):gsub('%s+',' '):match('^%s*(.-)%s*$'):lower()
end
local function currentDomain()
    return require('ao3lib.core.config'):readSetting('AO3_domain')
end
local function notify()
    for owner,callback in pairs(listeners) do
        local ok,err=pcall(callback,owner)
        if not ok then require('logger').warn('AO3 mute refresh failed:',err) end
    end
end
function M.watch(owner,callback) listeners[owner]=callback end
function M.unwatch(owner) listeners[owner]=nil end
function M.invalidate()
    generation=generation+1;values=nil;username=nil;domain=nil;loaded_at=nil;loading=false;last_attempt=nil
    notify()
end
function M.remember(result)
    if not result or not result.success or type(result.users)~='table' or not result.username then return end
    local users={}
    for _,user in ipairs(result.users) do if user.name then users[normalize(user.name)]=user.name end end
    generation=generation+1;values=users;username=result.username;domain=currentDomain();loaded_at=os.time();loading=false
    notify()
end
function M.contains(name)
    return values~=nil and domain==currentDomain() and values[normalize(name)]~=nil
end
function M.observeSession(status)
    if values and status and status.success and (not status.logged_in or status.username~=username) then M.invalidate() end
end
function M.match(work)
    local out={}
    for _,name in ipairs(work.author_accounts or {}) do
        if values and domain==currentDomain() and values[normalize(name)] then out[#out+1]=values[normalize(name)] end
    end
    return out
end
function M.ensure()
    local active_domain=currentDomain()
    if domain and domain~=active_domain then M.invalidate() end
    if loading or (values and loaded_at and os.time()-loaded_at<300)
            or (not values and last_attempt and os.time()-last_attempt<60) then return end
    local ok,network=pcall(require,'ui/network/manager')
    if not ok or not network.isConnected or not network:isConnected() then return end
    local background=require('ao3lib.ao3.background')
    if not background.available() then return end
    loading=true;last_attempt=os.time()
    local ticket=generation
    require('ui/uimanager'):nextTick(function()
        if ticket~=generation then return end
        background.wrap(function()
            local ok,result=pcall(function() return require('ao3lib.ao3.client'):getMutedUsers(true) end)
            if ticket~=generation then return end
            loading=false
            if ok and result and result.success then M.remember(result) end
        end,{silent=true,detached=true})
    end)
end
return M
