-- Reserve names atomically, including on Android where os.tmpname may fail.
local ffi=require('ffi')
ffi.cdef[[int mkstemp(char *); int close(int);]]
local M={}
function M.reserve(prefix)
    local ok,path,err=pcall(function()
        if not prefix then
            local named,value=pcall(os.tmpname)
            if named and type(value)=='string' and value~='' then return value end
            local dir=require('datastorage'):getDataDir()..'/cache'
            local lfs=require('libs/libkoreader-lfs')
            if lfs.attributes(dir,'mode')~='directory' then
                local made,why=lfs.mkdir(dir)
                if not made and lfs.attributes(dir,'mode')~='directory' then return nil,why end
            end
            prefix=dir..'/ao3lib-'
        end
        local buffer=ffi.new('char[?]',#prefix+7,prefix..'XXXXXX')
        local fd=ffi.C.mkstemp(buffer)
        if fd<0 then return nil,'Could not reserve a temporary file (errno '..ffi.errno()..').' end
        local name=ffi.string(buffer)
        if ffi.C.close(fd)~=0 then os.remove(name);return nil,'Could not close temporary file.' end
        return name
    end)
    if not ok then return nil,tostring(path) end
    return path,err
end
return M
