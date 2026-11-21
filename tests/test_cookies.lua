package.path='./?.lua;'..package.path
local C=require('ao3lib.ao3.cookies')
local url='https://archiveofourown.org/users/login'
local cookies=C.parse({'session=abc; Path=/; HttpOnly; Secure', 'remember_user_token=xyz; Expires=Wed, 01 Jan 2031 00:00:00 GMT; Path=/'},url)
assert(#cookies==2 and cookies[2].expires_at>os.time())
assert(C.matches(cookies[1],url) and not C.matches(cookies[1],'http://archiveofourown.org/'))
local combined=C.parse('a=1; expires=Wed, 01 Jan 2031 00:00:00 GMT; Path=/, b=2; Path=/users',url)
assert(#combined==2 and combined[1].expires_at)
assert(C.matches(combined[2],url) and not C.matches(combined[2],'https://archiveofourown.org/users2'))
assert(C.expired(C.parse('a=; Path=/',url)[1]))
assert(C.expired(C.parse('a=old; Max-Age=0; Expires=Wed, 01 Jan 2031 00:00:00 GMT',url)[1]))
assert(C.expired(C.parse('a=old; Expires=Wed, 01 Jan 2020 00:00:00 GMT',url)[1]))
print('PASS: multiple cookies, Expires commas, expiry, deletion, Max-Age, secure and path scoping')
