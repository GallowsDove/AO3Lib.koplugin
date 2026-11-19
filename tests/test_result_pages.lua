dofile('tests/test_network.lua')
local Fanfic = require('main')
local Client = require('ao3lib.ao3.client')
local Paging = require('ao3lib.ao3.work_paging')

-- Exercise every public adapter, especially optional nils before the page.
local endpoints = {
    {'fetchFanficsByTag', 'searchByTag', 2, 'result_works', true},
    {'getWorksFromAccountHistory', 'getWorksFromAccountHistory', 1, 'works', true},
    {'executeSearch', 'searchByParameters', 1, 'works', true},
    {'searchForUsers', 'searchForUsers', 1, 'result_users'},
    {'getWorksFromUserPage', 'getWorksFromUserPage', 4, 'works', true},
    {'getSeriesFromUserPage', 'getUserSeries', 2, 'series'},
    {'getCollectionsFromUserPage', 'getUserCollections', 1, 'collections'},
    {'getWorksFromSeries', 'getWorksFromSeries', 1, 'works', true},
    {'getWorksFromCollection', 'getWorksFromCollection', 1, 'works', true},
}
for __, spec in ipairs(endpoints) do
    local calls, fail, empty = {}, false, false
    Client[spec[2]] = function(self, ...)
        local args = {...}
        assert(select('#', ...) == spec[3] + 1, spec[1] .. ': page argument shifted')
        assert(args[1].query == 'original' and args[1].nested.sort == 'kudos')
        for i = 2, spec[3] do assert(args[i] == nil) end
        local page = args[spec[3] + 1]
        calls[#calls + 1] = page
        if fail then return {success=false, error='maintenance'} end
        local batch = {total=200}
        if not empty then
            for i = 1, 20 do batch[i] = {id=(page-1)*20+i} end
        end
        return {success=true, [spec[4]]=batch}
    end
    local query = {query='original', nested={sort='kudos'}}
    local ok, first, nextPage = Fanfic[spec[1]](Fanfic, query)
    assert(ok and calls[1] == 1 and first[1].id == 1)
    query.query, query.nested.sort = 'changed', 'updated'
    local pager = Paging.get(nextPage)
    assert((pager ~= nil) == (spec[5] == true))
    if pager then
        assert(pager:load(123).id == 123 and calls[#calls] == 7)
    end
    fail = true
    local failed = nextPage()
    assert(calls[#calls] == 2)
    assert(spec[1] == 'executeSearch' and failed == false or type(failed) == 'table')
    fail = false
    assert(nextPage()[1].id == 21 and calls[#calls] == 2)
    empty = true
    assert(#nextPage() == 0 and calls[#calls] == 3)
    empty = false
    local advance = spec[1] == 'fetchFanficsByTag' or spec[1] == 'getWorksFromAccountHistory'
    assert(nextPage()[1].id == (advance and 61 or 41))
    fail = true
    assert(Fanfic[spec[1]](Fanfic, {query='original', nested={sort='kudos'}}) == false)
end
print('PASS: all nine result adapters preserve API arity, query snapshots, result fields, numbered registration, retry cursors and empty-page behavior')
