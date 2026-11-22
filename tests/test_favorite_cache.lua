package.path='./?.lua;'..package.path
local jobs,fetches,notices={},0,0
local domain='https://archiveofourown.org'
local connected=true
local next_result={success=true,username='Alice',tags={{name='Slow Burn'},{name='Fandom & Co'}}}
package.loaded['ao3lib.core.config']={readSetting=function(_,key) if key=='AO3_domain' then return domain end end}
package.loaded['ui/network/manager']={isConnected=function() return connected end}
package.loaded['ui/uimanager']={nextTick=function(_,fn) jobs[#jobs+1]=fn end}
package.loaded['ao3lib.ao3.background']={available=function() return true end,
    wrap=function(fn,options) assert(options.silent and options.detached);fn() end}
package.loaded['ao3lib.ao3.client']={getFavoriteTags=function(_,silent)
    assert(silent);fetches=fetches+1;return next_result
end}
package.loaded.logger={warn=function(_,err) error(tostring(err)) end}
local Cache=require('ao3lib.ao3.favorite_cache')
local owner={}
Cache.watch(owner,function() notices=notices+1 end)
Cache.ensure();Cache.ensure()
assert(fetches==0 and #jobs==1,'Loading should be deferred and shared')
table.remove(jobs,1)()
assert(fetches==1 and Cache.contains('  SLOW   BURN ') and Cache.contains('Fandom & Co'))
Cache.ensure();assert(#jobs==0 and fetches==1,'Page turns must reuse the account cache')
Cache.changed('Slow Burn',false);Cache.changed('A New Tag',true)
assert(not Cache.contains('Slow Burn') and Cache.contains('A New Tag'))
Cache.observeSession{success=true,logged_in=true,username='Bob'}
assert(not Cache.contains('A New Tag'),'Changing accounts must discard old favorites')
Cache.ensure();assert(#jobs==1)
Cache.invalidate();table.remove(jobs,1)()
assert(fetches==1 and not Cache.contains('Slow Burn'),'An invalidated request must not repopulate the cache')
connected=false;Cache.ensure();assert(#jobs==0,'Offline highlighting must not prompt for Wi-Fi')
connected=true;Cache.ensure();table.remove(jobs,1)()
assert(fetches==2 and Cache.contains('Slow Burn'))
domain='https://another.example';assert(not Cache.contains('Slow Burn'))
Cache.ensure();assert(#jobs==1);table.remove(jobs,1)()
Cache.observeSession{success=true,logged_in=false}
assert(not Cache.contains('Slow Burn'))
Cache.unwatch(owner)
assert(notices>0)
print('PASS: deferred shared favorites, updates, offline behavior, account/domain invalidation and stale-request protection')
