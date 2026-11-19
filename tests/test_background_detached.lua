package.path='./?.lua;'..package.path
local H=dofile('tests/support/async.lua')
local B=require('ao3lib.ao3.background')
local origin={item_table={}}
H.UI:show(origin)
local foreground,quiet
B.wrap(function() foreground=B.await(function() H.sleep(25);return 'foreground' end) end)
H.tick()
assert(H.forks==1 and #H.stack==2)
B.wrap(function() quiet=B.await(function() H.sleep(10);return 'quiet' end) end,
    {silent=true,detached=true})
while H.forks<2 do H.tick() end
assert(#H.stack==2,'Silent checks displayed another network overlay')
H.drain()
assert(foreground=='foreground' and quiet=='quiet','Detached request canceled a foreground request')
assert(#H.stack==1)
-- An unrelated foreground request, navigation and changing menu contents must
-- never cancel a background check already in flight.
quiet=nil;foreground=nil
B.wrap(function() quiet=B.await(function() H.sleep(30);return 'quiet again' end) end,
    {silent=true,detached=true})
H.tick()
H.UI:close(origin)
local reader={item_table={}}
H.UI:show(reader)
B.wrap(function() foreground=B.await(function() return 'search' end) end)
H.drain()
assert(quiet=='quiet again' and foreground=='search' and #H.stack==1 and H.stack[1]==reader)
local valid,canceled=true,false
quiet=nil
B.wrap(function() quiet=B.await(function() H.sleep(100);return 'too late' end) end,
    {silent=true,detached=true,valid=function() return valid end,on_cancel=function() canceled=true end})
H.tick();valid=false;H.drain()
assert(canceled and not quiet and #H.stack==1)
print('PASS: real worker requests coexist; checks have no overlay, survive screen changes and foreground requests, and still support explicit cancellation/reaping')
