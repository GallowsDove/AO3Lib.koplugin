package.path='./?.lua;'..package.path
local jobs={}
local domain='https://archiveofourown.org'
package.loaded['ao3lib.core.config']={readSetting=function(_,key) if key=='AO3_domain' then return domain end end}
package.loaded['ui/network/manager']={isConnected=function() return true end}
package.loaded['ui/uimanager']={nextTick=function(_,fn) jobs[#jobs+1]=fn end}
package.loaded['ao3lib.ao3.background']={available=function() return true end,wrap=function(fn) fn() end}
package.loaded['ao3lib.ao3.client']={getMutedUsers=function() return {success=true,username='Me',users={{name='Writer'},{name='Other'}}} end}
package.loaded.logger={warn=function(_,err) error(err) end}
local cache=require('ao3lib.ao3.mute_cache')
cache.ensure();cache.ensure();assert(#jobs==1);table.remove(jobs,1)()
local matches=cache.match{author_accounts={'Coauthor','writer','Other'}}
assert(#matches==2 and matches[1]=='Writer' and matches[2]=='Other')
assert(#cache.match{author='Writer'}==0,'Display names must not cause mistaken account matches')
cache.observeSession{success=true,logged_in=true,username='SomeoneElse'}
assert(#cache.match{author_accounts={'Writer'}}==0)
cache.ensure();cache.invalidate();table.remove(jobs,1)()
assert(#cache.match{author_accounts={'Writer'}}==0,'Stale requests must not restore another account')
print('PASS: background mute cache, coauthor matching and account isolation')
package.loaded['gettext']=function(s) return s end
package.loaded['ao3lib.ao3.work_paging']={get=function() end}
package.loaded['ao3lib.library.blacklist']={match=function() return {'A blacklisted tag'} end}
cache.remember{success=true,username='Me',users={{name='Writer'}}}
local state,html,rows,actions
local view=require('ao3lib.ui.work_view')
state=view.new{works={{id=1,author_accounts={'Writer'}},{id=2}},blacklist=true,mutes=true,
    rows=function() return {{'Visible','work'}} end,
    present=function(_,h,a,r) html,actions,rows=h,a,r end}
state:render()
assert(html:find('Muted author: Writer',1,true) and html:find('A blacklisted tag',1,true))
assert(state:pageCount()==2 and #rows==2)
actions[1]();assert(rows[1][1]=='Visible' and state:pageCount()==2)
print('PASS: combined mute and blacklist reasons, reveal and unchanged work count')
