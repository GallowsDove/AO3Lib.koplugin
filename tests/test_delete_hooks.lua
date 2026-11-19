package.path='./?.lua;'..package.path
local fs={['/books/kept.epub']='file',['/books2/other.epub']='file',
    ['/books/protected.epub']='denied'}
package.loaded['libs/libkoreader-lfs']={attributes=function(path)
    if fs[path]=='denied' then return nil,'Permission denied',13 end
    if fs[path] then return {mode=fs[path]} end
    return nil,'No such file or directory',2
end}
local removed={}
local indexed={
    a={id='a',path='/books/gone.epub'}, b={id='b',path='/books/kept.epub'},
    c={id='c',path='/books/protected.epub'}, d={id='d',path='/books2/other.epub'},
    e={id='e',path='/books/nested/gone.epub'},
}
package.loaded['ao3lib.library.epub']={indexWorks=function(roots)
    local out={};local prefix=roots[1]:gsub('/+$','')..'/'
    for id,work in pairs(indexed) do if work.path:sub(1,#prefix)==prefix then out[id]=work end end
    return out
end,invalidate=function(path,defer) removed[path]=(removed[path] or 0)+1;assert(defer) end}
local calls={}
local history={
    fileDeleted=function(_,path) calls[#calls+1]=path;return true,'original' end,
    folderDeleted=function(_,path) calls[#calls+1]=path end,
    removeItems=function(_,files) calls[#calls+1]=files;return 'batch' end,
    removeItemByPath=function(_,path) calls[#calls+1]=path end,
}
package.loaded.readhistory=history
local Cache=require('ao3lib.library.local_cache')
Cache.put({'/books'},indexed)
local Hooks=require('ao3lib.library.delete_hooks')
assert(Hooks.install());local wrapped=history.fileDeleted
assert(Hooks.install() and history.fileDeleted==wrapped,'Installation must be idempotent')
local ok,result=history:fileDeleted('/books/gone.epub')
assert(ok and result=='original' and removed['/books/gone.epub']==1)
assert(not Cache.get({'/books'}).a)
history:fileDeleted('/books/kept.epub') -- Bookshelf calls this even if os.remove failed.
history:fileDeleted('/books/protected.epub')
history:fileDeleted(2) -- KOReader passes history indices inside folder deletion.
history:removeItemByPath('/books/kept.epub') -- Removing from history is not deletion.
assert(not removed['/books/kept.epub'] and not removed['/books/protected.epub'])
assert(history:removeItems({['/books/nested/gone.epub']=true,['/books/kept.epub']=true})=='batch')
assert(removed['/books/nested/gone.epub']==1 and not Cache.get({'/books'}).e)
history:folderDeleted('/books/')
assert(removed['/books/gone.epub']==2 and not removed['/books/kept.epub'])
assert(not removed['/books/protected.epub'] and Cache.get({'/books'}).d,
    'Folder handling must preserve inaccessible files and sibling paths')
print('PASS: KOReader and Bookshelf deletion notifications, batch and folder deletes, failed deletes, history-only actions')
