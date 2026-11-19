dofile('tests/test_failures.lua')
local urls={}
require('ssl.https').request=function(req)
    urls[#urls+1]=req.url
    req.sink('SEARCH')
    return 1,200,{}
end
local Client=require('ao3lib.ao3.client')
local global={['work_search[freeform_names]']='My tag', ['work_search[sort_column]']='revised_at',
    ['work_search[excluded_tag_names]']='M/M,Graphic Depictions Of Violence'}
assert(Client:searchByParameters(global).success)
local url=urls[#urls]
assert(url:find('/works/search?commit=Search&',1,true))
assert(url:find('work_search%5Bfreeform_names%5D=My%20tag',1,true))
assert(url:find('work_search%5Bexcluded_tag_names%5D=M%2FM%2CGraphic%20Depictions%20Of%20Violence',1,true))
assert(Client:searchByParameters(global,4).success)
assert(urls[#urls]:find('page=4',1,true))
local scoped={tag_id='Fluff', ['work_search[freeform_names]']='My tag'}
assert(Client:searchByParameters(scoped,2).success)
assert(urls[#urls]:find('/works?commit=Sort+and+Filter&',1,true))
assert(urls[#urls]:find('tag_id=Fluff',1,true) and urls[#urls]:find('page=2',1,true))
assert(global.tag_id==nil and scoped.tag_id=='Fluff')
print('PASS: global/tag-scoped request routing; noncanonical tag encoding; canonical tag-name exclusions; numbered pages')
