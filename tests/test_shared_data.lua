local Tables = require('ao3lib.core.table')
local shared = {progress=0.75}
local key = {}
local original = {first=shared, second=shared, [key]=key}
original.self = original
setmetatable(original, {owner=original})
local copied = Tables.deepCopy(original)
assert(copied ~= original and copied.self == copied)
assert(copied.first == copied.second and copied.first ~= shared)
assert(getmetatable(copied) ~= getmetatable(original) and getmetatable(copied).owner == copied)
for k, v in pairs(copied) do
    if type(k) == 'table' then assert(k ~= key and k == v) end
end
copied.first.progress = 1
assert(shared.progress == 0.75)
assert(Tables.deepCopy(false) == false and Tables.deepCopy(nil) == nil)
local shallow = Tables.shallowCopy(original)
assert(shallow ~= original and shallow.first == shared and shallow.self == original)
assert(next(Tables.shallowCopy(nil)) == nil)

package.loaded.util = {trim=function(text) return text:match('^%s*(.-)%s*$') end}
local Fields = require('ao3lib.library.fields')
local stored = Fields.list('Smith, John')
assert(#stored == 1 and stored[1] == 'Smith, John')
local displayed = Fields.list(' First, Second , ,Third', true)
assert(#displayed == 4 and displayed[1] == 'First' and displayed[2] == 'Second' and displayed[3] == '' and displayed[4] == 'Third')
assert(Fields.list(stored, true) == stored)
assert(#Fields.list(false) == 0 and #Fields.list(nil) == 0)
local work = {tags='Smith, John', title='Title'}
assert(Fields.normalize(work, {'tags', 'fandoms'}) == work)
assert(work.tags[1] == 'Smith, John' and #work.fandoms == 0 and work.title == 'Title')
print('PASS: shared deep/shallow copy preserves isolation, aliases, cycles, table keys and metatables; metadata normalization preserves storage/display policies')
