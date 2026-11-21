package.path='./?.lua;'..package.path
package.loaded.gettext=function(s) return s end
local Format=require('ao3lib.core.format')
for raw,expected in pairs({['999']='999',['1000']='1,000',['43199']='43,199',['43,199']='43,199',
    ['46494']='46,494',['1000000']='1,000,000',['001000']='1,000',['0']='0',['Unknown']='Unknown',['?']='?'}) do
    assert(Format.integer(raw)==expected,raw)
end
assert(Format.integer(46494)=='46,494' and Format.integer(nil)=='')
assert(Format.newChapters(1)=='1 new chapter' and Format.newChapters(2)=='2 new chapters')
local registered
package.loaded['ao3lib.bookshelf.metadata']={get=function() return {wordcount='46494'} end}
package.loaded['lib/bookshelf_tokens']={API=1,register=function(_,defs) registered=defs;return true end}
assert(require('ao3lib.bookshelf.tokens').install())
assert(registered.ao3_words.expand({filepath='/books/example.epub'})=='46,494')
print('PASS: consistent grouping for raw/formatted/numeric counts; unknown values preserved; proper chapter plurals; Bookshelf word token')
