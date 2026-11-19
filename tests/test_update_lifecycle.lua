dofile('tests/test_network.lua')
local Fanfic=require('main')
local suspended,resumed,flushed=0,0,0
package.loaded["ao3lib.updates.service"]={
    suspend=function() suspended=suspended+1 end,
    resume=function() resumed=resumed+1 end,
    flush=function() flushed=flushed+1;return true end,
}
Fanfic:onSuspend()
assert(suspended==1 and flushed==1)
Fanfic:onResume();Fanfic:onNetworkConnected()
assert(resumed==2)
Fanfic:onFlushSettings();assert(flushed==2)
package.loaded["ao3lib.updates.service"]=nil
Fanfic:onSuspend();Fanfic:onResume();Fanfic:onNetworkConnected();Fanfic:onFlushSettings()
assert(suspended==1 and resumed==2 and flushed==2,'Lifecycle hooks loaded a check service that had never been used')
print('PASS: reader/FileManager lifecycle pauses checks before suspend checkpoint, resumes on wake/reconnect, flushes state, and does not eagerly load an unused service')
