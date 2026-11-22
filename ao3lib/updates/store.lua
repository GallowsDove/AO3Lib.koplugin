local Persistent=require("ao3lib.core.persistent")
local M={}
local generation=0
M.error=nil

local filename=Persistent.path("ao3_update_checks.bin")
local function path() return filename end
local function decode_file(filename)
    local file,err=io.open(filename,"rb")
    if not file then return nil,err end
    local data=file:read("*a");file:close()
    local ok,state=pcall(require("string.buffer").decode,data)
    if not ok or type(state)~="table" or state.version~=1 then return nil,"Invalid saved update-check data" end
    return state
end
local function write_atomic(state,filename)
    local encoded=require("string.buffer").encode(state)
    local tmp=filename .. ".tmp"
    local f,err=io.open(tmp,"wb");if not f then return nil,err end
    local ok,why=f:write(encoded)
    if not ok then f:close();os.remove(tmp);return nil,why end
    local closed,close_err=f:close();if not closed then os.remove(tmp);return nil,close_err end
    local moved,move_err=os.rename(tmp,filename)
    if not moved then os.remove(tmp);return nil,move_err end
    return true
end
function M.load()
    local state,err=decode_file(path())
    if err and not tostring(err):find("No such file",1,true) then M.error=err end
    if state then M.error=nil end
    return state
end
function M.flush(state)
    generation=generation+1
    local util=require("util")
    local home=filename:match('^(.*)/[^/]+$')
    if util.makePath and not util.makePath(home) then M.error="Could not create update-check storage directory";return nil,M.error end
    local ok,err=write_atomic(state,path())
    if not ok then M.error=tostring(err);return nil,M.error end
    M.error=nil;return true
end
function M.save(state)
    generation=generation+1
    local current=generation
    local util=require("util")
    local home=filename:match('^(.*)/[^/]+$')
    if util.makePath and not util.makePath(home) then M.error="Could not create update-check storage directory";return nil,M.error end
    local filename=path()
    local staging,err=require('ao3lib.core.tempfile').reserve(filename..'.ao3stage-')
    if not staging then M.error=tostring(err);return nil,M.error end
    local ok,err=require("ao3lib.ao3.background").run(function()
        local good,why=write_atomic(state,staging)
        if not good then error(why) end
        return true
    end,function(value,why)
        if current~=generation then os.remove(staging);return end
        if not value then M.error=tostring(why);os.remove(staging);return end
        local moved,move_err=os.rename(staging,filename)
        if not moved then M.error=tostring(move_err);os.remove(staging) else M.error=nil end
    end)
    if not ok then M.error=tostring(err);return nil,M.error end
    return true
end
return M
