-- KOReader's file manager and Bookshelf report successful deletes to
-- ReadHistory. Its other history operations must never remove index entries.
local M={}
local function deleted(path)
    if type(path)~='string' or not path:lower():match('%.epub$') then return end
    local lfs=require('libs/libkoreader-lfs')
    local stat,err,code=lfs.attributes(path)
    if not stat and (code==2 or (type(err)=='string' and err:find('No such file',1,true))) then
        require('ao3lib.library.local_cache').removePath(path)
    end
end
local function safely(fn,...)
    local ok,err=pcall(fn,...)
    if not ok then
        local loaded,logger=pcall(require,'logger')
        if loaded and logger.warn then logger.warn('AO3 delete notification:',err) end
    end
end
function M.install()
    local ok,history=pcall(require,'readhistory')
    if not ok or type(history)~='table' then return false end
    if history._ao3_delete_hooks_installed then return true end
    if type(history.fileDeleted)=='function' then
        local original=history.fileDeleted
        history.fileDeleted=function(self,path,...)
            local function finished(...)
                if type(path)=='string' then safely(deleted,path) end
                return ...
            end
            return finished(original(self,path,...))
        end
    end
    if type(history.removeItems)=='function' then
        local original=history.removeItems
        history.removeItems=function(self,files,...)
            local function finished(...)
                if type(files)=='table' then for path in pairs(files) do safely(deleted,path) end end
                return ...
            end
            return finished(original(self,files,...))
        end
    end
    if type(history.folderDeleted)=='function' then
        local original=history.folderDeleted
        history.folderDeleted=function(self,path,...)
            local function finished(...)
                if type(path)=='string' then
                    safely(function() require('ao3lib.library.local_cache').removeMissingUnder(path) end)
                end
                return ...
            end
            return finished(original(self,path,...))
        end
    end
    history._ao3_delete_hooks_installed=true
    return true
end
return M
