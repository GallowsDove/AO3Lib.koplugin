dofile('tests/test_network.lua')
local View=require('ao3lib.ui.work_view')
local function rows(work) return {{work.title},{'Author:',work.author}} end
local online={title='Story',author='Writer',summary='First & second.\n\nNext paragraph.',
    tags={'One tag','Another tag'},chapters='1/1'}
local local_work={title='Story',author='Writer',summary='<p>First &amp; second.</p>\n<p>Next paragraph.</p>',
    tags={'  One\n tag  ','Another tag'},chapters='1/1'}
local rendered=View.html(local_work,rows(local_work),{summary_html=true})
local browsing=View.html(online,rows(online))
local function section(html,class) return html:match('<div class="'..class..'">(.-)</div>') end
assert(section(rendered,'summary')==section(browsing,'summary'),'Stored HTML and online text must have the same paragraph spacing')
assert(not rendered:find('&lt;p&gt;',1,true) and rendered:find('First &amp; second.',1,true))
assert(section(rendered,'tag%-group additional')==section(browsing,'tag%-group additional'),
    'Whitespace in EPUB tag metadata must not change chip spacing')
assert(not section(rendered,'tag%-group additional'):find('&#160;',1,true) and not rendered:find(' Hits',1,true))
assert(not rendered:find('class="footnote"',1,true),'Unknown counters must not create a footer')
local_work.hits=0;local_work.kudos='12345';local_work.updated='2026-11-21'
rendered=View.html(local_work,rows(local_work),{summary_html=true})
assert(rendered:find('<b>0</b> Hits',1,true) and rendered:find('<b>12,345</b> Kudos',1,true))
assert(not rendered:find(' Bookmarks',1,true) and rendered:find('2026-11-21',1,true))
local_work.summary='<p onclick="evil()">Safe<br/>line &lt;literal&gt;</p><script>alert(1)</script>'
rendered=View.html(local_work,rows(local_work),{summary_html=true})
assert(not rendered:find('<script>',1,true) and not rendered:find('onclick',1,true))
assert(rendered:find('Safe<br/>line &lt;literal&gt;',1,true))
rendered=View.html({title='Plain',summary='<p>Literal text</p>'},{{'Plain'}})
assert(rendered:find('&lt;p&gt;Literal text&lt;/p&gt;',1,true),'Online plain text must remain escaped')
print('PASS: matching local/online summaries and tag spacing; unknown counters omitted; known zero preserved; safe local summary markup')
