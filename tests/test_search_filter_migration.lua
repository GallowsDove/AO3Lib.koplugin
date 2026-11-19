package.path='./?.lua;'..package.path
local Filters=require('ao3lib.ui.saved_searches')
local copy=require('ao3lib.core.table').deepCopy
local saved={
    fandom={title='Fandom',parameters={main_tag='A Fandom',characters={'A Character'},rating='13',
        word_count='>50000',exclude_categories={'21'},sort_by='kudos_count'}},
    pairing={title='Pairing',parameters={main_tag='A/B',relationships={'A/B'},exclude_warnings={'17'}}},
    trope={title='Trope',parameters={main_tag='Fluff',additional_tags={'Another trope','Angst'}}},
    generic={title='Generic',parameters={additional_tags={'Unwrangled tag'},date_from='2026-01-01'}},
}
local original=copy(saved)
local writes=0
local config={readSetting=function() return copy(saved) end,saveSetting=function(_,key,value)
    assert(key=='saved_filters');saved=copy(value);writes=writes+1
end}
local converted=Filters.saved(config)
assert(writes==1 and converted.fandom.parameters.main_tag==nil)
assert(converted.fandom.parameters.additional_tags[1]=='A Fandom')
for _,field in ipairs({'characters','rating','word_count','exclude_categories','sort_by'}) do
    local value=converted.fandom.parameters[field]
    if type(value)=='table' then assert(value[1]==original.fandom.parameters[field][1])
    else assert(value==original.fandom.parameters[field]) end
end
assert(converted.pairing.parameters.additional_tags==nil,'Existing includes must not be duplicated')
assert(converted.pairing.parameters.relationships[1]=='A/B')
assert(converted.trope.parameters.additional_tags[2]=='Angst' and converted.trope.parameters.additional_tags[3]=='Fluff')
assert(converted.trope.parameters.additional_tags[1]=='Another trope')
assert(converted.generic.parameters.additional_tags[1]=='Unwrangled tag')
assert(converted.generic.parameters.date_from=='2026-01-01')
assert(original.fandom.parameters.main_tag=='A Fandom','Migration must not mutate its input')
converted.fandom.parameters.additional_tags[1]='Unsaved edit'
local reopened=Filters.saved(config)
assert(writes==1 and reopened.fandom.parameters.additional_tags[1]=='A Fandom','Migration must survive reload and be idempotent')
local normalized,changed=Filters.normalize({main_tag='A/B',additional_tags={'A/B'},exclude_additional_tags={'Different tag'}})
assert(changed and normalized.main_tag==nil and #normalized.additional_tags==1 and normalized.exclude_additional_tags[1]=='Different tag')
local again,changedAgain=Filters.normalize(normalized)
assert(not changedAgain and #again.additional_tags==1)
-- Legacy array-shaped saved searches must preserve their keys, names and options too.
saved={{title='Old array',parameters={main_tag='Fluff',completion_status='T'}}}
assert(Filters.saved(config)[1].parameters.additional_tags[1]=='Fluff' and saved[1].title=='Old array')
assert(saved[1].parameters.completion_status=='T')
print('PASS: persistent offline migration; all tag types; deduplication; every other criterion retained; saved copies isolated; idempotent reload; legacy array records')
