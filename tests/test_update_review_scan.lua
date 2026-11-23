-- Exercise the real update-review screen with a deliberately unfinished scan.
dofile('tests/test_updates.lua')
local UI=require('ui/uimanager')
local Review=require('ao3lib.ui.update_review')
local work1={id='cache',path='/books/cache.epub',title='Cached work',author='Writer'}
local work2={id='new',path='/books/new.epub',title='New work',author='Writer'}
local worker,scan
package.loaded['ao3lib.library.local_cache']={
    get=function() end,
    load=function(_,done,valid)
        worker={done=done,valid=valid,cancel=function(self) self.cancelled=true end}
        return worker
    end,
    put=function(_,works) package.loaded['ao3lib.library.local_cache'].saved=works end,
}
package.loaded['ao3lib.library.discovery']={scan=function(_,done,invalid,options)
    scan={done=done,invalid=invalid,progress=options.progress}
    return {cancel=function() scan.cancelled=true end}
end}
local checks=0
local Client=require('ao3lib.ao3.client')
local original=Client.getWorkMetadata
Client.getWorkMetadata=function(...) checks=checks+1;return original(...) end
local session,menu=Review.show({ui={}})
assert(menu.title=='Downloaded work updates' and not scan and worker,
    'Review must open without starting directory discovery')
assert(menu.review_model.total==0)
worker.done({cache=work1})
assert(menu.review_model.total==1 and menu.review_model.summary:find('0 of 1 checked',1,true),
    'Cached works must become available during discovery')
local check_row
for _,row in ipairs(menu.review_model.buttons[1]) do if row.text=='Check for updates' then check_row=row end end
assert(check_row and check_row.enabled,'Checks must be available before discovery finishes')
for _,row in ipairs(menu.item_table) do assert(row.text~='Rescan library') end
assert(checks==0,'Opening a review must not start AO3 update checks')
local _,menu2=Review.show({ui={}})
menu2:onCloseWidget()
assert(worker.cancelled and not worker.valid(),
    'Closing the review must cancel its cache worker')
worker.done({cache=work1})
assert(menu2.review_model.summary:find('0 of 0 checked',1,true),
    'A closed review must ignore late discovery results')
Client.getWorkMetadata=original
print('PASS: update review uses cache without exposing rescan and cancels validation on close')
