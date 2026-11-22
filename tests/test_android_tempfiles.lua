package.path='./?.lua;'..package.path
local H=dofile('tests/support/async.lua')
local root=os.tmpname();os.remove(root)
assert(os.execute('mkdir '..root)==0)
package.loaded.datastorage={getDataDir=function() return root end}
package.loaded['libs/libkoreader-lfs']={
    attributes=function(path,mode)
        if path==root..'/cache' then local f=io.open(path..'/.probe','w');if f then f:close();os.remove(path..'/.probe');return 'directory' end end
    end,
    mkdir=function(path) return os.execute('mkdir '..path)==0 end,
}
local Temp=require('ao3lib.core.tempfile')
local original=os.tmpname
os.tmpname=function() error('Android has no writable system temp directory') end
local a=assert(Temp.reserve());local b=assert(Temp.reserve())
assert(a~=b and a:find(root..'/cache/',1,true)==1)
assert(io.open(a,'rb') and io.open(b,'rb'))
os.remove(a);os.remove(b)
local Background=require('ao3lib.ao3.background')
local first,second,canceled
Background.run(function() H.sleep(40);return 'first' end,function(value) first=value end)
local job=Background.run(function() H.sleep(100);return 'second' end,function(value,err) second=value;canceled=Background.isCancelled(err) end)
H.tick();job:cancel();H.drain()
assert(first=='first' and not second and canceled)
os.tmpname=original
assert(os.execute('rmdir '..root..'/cache')==0,'Fallback files leaked after completion or cancellation')
assert(os.execute('rmdir '..root)==0)
print('PASS: Android temp fallback, atomic unique reservation, concurrent workers, cancellation and cleanup')
