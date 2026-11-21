-- Tell the host a file's contents changed, including when a download replaces
-- an old file at the same path. Optional integrations fail independently.
local M={}
function M.notify(path)
    local UI=require('ui/uimanager')
    local Event=require('ui/event')
    pcall(function() UI:broadcastEvent(Event:new('InvalidateMetadataCache',path)) end)
    local ok,Repo=pcall(require,'lib/bookshelf_book_repository')
    if ok then
        if Repo.forgetBook then pcall(Repo.forgetBook,path) end
        if Repo.invalidateWalkCache then pcall(Repo.invalidateWalkCache) end
    end
    -- Bookshelf clears its rendered metadata records and refreshes on return,
    -- even if the underlying KOReader metadata cache already has a summary.
    pcall(function() UI:broadcastEvent(Event:new('BookMetadataChanged')) end)
end
return M
