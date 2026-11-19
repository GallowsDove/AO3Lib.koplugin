package.path='./?.lua;'..package.path
local H=dofile('tests/support/async.lua')
local Buffer=require('string.buffer')
local directory=os.tmpname();os.remove(directory)
assert(os.execute('mkdir '..directory)==0)
local fail=false
package.loaded["ao3lib.core.paths"]={getHomeDirectory=function() return directory end}
package.loaded.util={makePath=function(path) assert(path==directory);return not fail end}
local Store=require('ao3lib.updates.store')
local state={version=1,entries={{work={id='1',path='/books/1.epub'},status='update'}},pending={'1\n/books/1.epub'}}
Store.save(state)
assert(H.forks==1 and not Store.load(),'Staged snapshot published before worker finished')
state={version=1,entries={{work={id='2',path='/books/2.epub'},status='current'}},pending={}}
Store.save(state);H.drain()
assert(Store.load().entries[1].work.id=='2' and not Store.error)
-- A shutdown checkpoint cancels stale writers; their completions cannot
-- replace the newer synchronous checkpoint after a resume.
Store.save{version=1,entries={{work={id='stale'}}}}
assert(Store.flush{version=1,entries={{work={id='checkpoint'}}}})
H.drain()
assert(Store.load().entries[1].work.id=='checkpoint')
fail=true;Store.save(state);H.drain()
assert(Store.error and Store.load().entries[1].work.id=='checkpoint','Failed save destroyed the previous checkpoint')
fail=false;Store.save(state);H.drain();assert(not Store.error)
local path=directory..'/ao3_update_checks.bin'
local file=assert(io.open(path,'wb'));file:write('corrupt');file:close()
assert(not Store.load() and Store.error)
assert(Store.flush(state) and Store.load().entries[1].work.id=='2')
local tmpname=os.tmpname
os.tmpname=function() error('temporary directory unavailable') end
Store.save(state);assert(Store.error:find('temporary directory unavailable',1,true))
assert(not Store.flush(state))
os.tmpname=tmpname
assert(Store.flush(state))
os.remove(path)
assert(os.execute('rmdir '..directory)==0,'Worker left stale staging files')
print('PASS: real forked persistence; coalesced snapshots; atomic publication; shutdown supersedes stale workers; corrupt/failed saves; recovery; temporary-file cleanup')
