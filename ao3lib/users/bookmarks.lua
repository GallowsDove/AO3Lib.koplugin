-- Bookmarks are stored as legacy display strings, but identified by account.
local Config=require('ao3lib.core.config')
local M={}
local function trim(value) return tostring(value or ''):match('^%s*(.-)%s*$') end
function M.parse(value)
    if type(value)~='string' then return nil end
    local pseud,username=value:match('^(.-)%s*%(([^()]*)%)%s*$')
    username=trim(username or value);pseud=trim(pseud or username)
    if username=='' then return nil end
    if pseud=='' then pseud=username end
    return {username=username,pseud=pseud,display=pseud~=username and pseud..' ('..username..')' or username}
end
function M.list()
    local result,seen={},{}
    for _,value in ipairs(Config:readSetting('bookmarkedUsers',{}) or {}) do
        local user=M.parse(value)
        local key=user and user.username:lower()
        if key and not seen[key] then result[#result+1]=user;seen[key]=true end
    end
    return result
end
function M.contains(username)
    username=trim(username):lower()
    for _,user in ipairs(M.list()) do if user.username:lower()==username then return true end end
    return false
end
function M.set(username,pseud,want)
    username=trim(username);pseud=trim(pseud)
    if username=='' then return false end
    local original=Config:readSetting('bookmarkedUsers',{}) or {}
    local output,found={},false
    for _,value in ipairs(original) do
        local user=M.parse(value)
        if user and user.username:lower()==username:lower() then
            if want and not found then output[#output+1]=value end
            found=true
        else output[#output+1]=value end
    end
    if want and not found then output[#output+1]=M.parse((pseud~='' and pseud~=username) and pseud..' ('..username..')' or username).display end
    if (want and not found) or (not want and found) or #output~=#original then
        Config:saveSetting('bookmarkedUsers',output)
    end
    return true
end
return M
