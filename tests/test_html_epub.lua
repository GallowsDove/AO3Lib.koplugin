-- Run from the plugin directory: luajit tests/test_html_epub.lua
package.path='./?.lua;'..package.path
package.loaded['libs/libkoreader-lfs']={}
package.loaded.util={trim=function(s) return (s:gsub('^%s+',''):gsub('%s+$','')) end}
local Converter=require('ao3lib.library.html_epub')
local html=[[<!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en"><head><title>Example</title></head><body>
<div id="preface"><p class="message">Originally at <a href="https://archiveofourown.org/works/123">AO3</a>.</p>
<div class="meta"><h1>Title &amp; more</h1><div class="byline"><a rel="author">One</a>, <a rel="author">Two</a></div>
<dl class="tags"><dt>Fandom:</dt><dd><a>Example</a></dd><dt>Stats:</dt><dd>Published: 2025-01-01 Updated: 2025-02-01 Words: 1,200 Chapters: 2/2</dd></dl>
<p>Summary</p><blockquote><p>A &amp; B</p></blockquote></div></div>
<div id="chapters"><h2 class="title">Chapter one</h2><p>Content&nbsp;<a href="#note">note</a></p><h2 class="title">Chapter two</h2><img src="https://example.test/image.png"/></div>
<div id="afterword"><p id="note">End note</p></div></body></html>]]
local calls=0
local files=Converter.build(html,'123',function(url)
    assert(url=='https://example.test/image.png');calls=calls+1;return '\137PNG\13\10\26\10data'
end)
assert(not files['content.opf']:find('calibre:series',1,true),'Works without a series must not acquire one')
local series_html=html:gsub('<dt>Stats:</dt>', [[<dt>Series:</dt><dd>Part 2.5 of <a href="/series/42">A &amp; &quot;B&quot;</a>,
Part 3 of <a href="/series/99">Second series</a></dd><dt>Stats:</dt>]])
local series_files=Converter.build(series_html,'123',function() return '\137PNG\13\10\26\10data' end)
assert(series_files['content.opf']:find('<meta name="calibre:series" content="A &amp; &quot;B&quot;"/>',1,true))
assert(series_files['content.opf']:find('<meta name="calibre:series_index" content="2.5"/>',1,true))
local membership_count=0
for _,bytes in pairs(series_files) do
    if bytes:find('href="/series/99"',1,true) then membership_count=membership_count+1 end
end
assert(membership_count>0,'Additional memberships must remain in the preface')
assert(calls==1)
assert(files['content.opf']:find('<dc:title>Title &amp; more</dc:title>',1,true))
assert(files['content.opf']:find('<dc:creator opf:file-as="two" opf:role="aut">Two</dc:creator>',1,true))
assert(files['content.opf']:find('<dc:description>&lt;p&gt;A &amp;amp; B&lt;/p&gt;</dc:description>',1,true))
assert(files['content.opf']:find('ao3:chapters" content="2/2"',1,true))
assert(files['toc.ncx']:find('Chapter two',1,true))
local combined={}
for path,bytes in pairs(files) do if path:match('%.xhtml$') then combined[#combined+1]=bytes end end
combined=table.concat(combined)
assert(combined:find('src="image1.png"',1,true))
assert(combined:find('id="note"',1,true))
assert(combined:find('href="work_split_002.xhtml#note"',1,true))
assert(files['work_split_000.xhtml'] and files['work_split_001.xhtml'] and files['work_split_002.xhtml'])
assert(files['stylesheet.css']:find('.meta dl.tags',1,true))
assert(files['content.opf']:find('<dc:subject>Fanworks</dc:subject>',1,true))
assert(not pcall(Converter.build,html,'999'))
assert(not pcall(Converter.build,'<html>Login required</html>','123'))
assert(not pcall(Converter.build,html:gsub('</body>',''),'123'))
local missing_files,missing=Converter.build(html,'123',function() error('Image unavailable') end)
assert(missing==1)
local missing_content=''
for path,bytes in pairs(missing_files) do if path:match('%.xhtml$') then missing_content=missing_content..bytes end end
assert(missing_content:find('[Image unavailable]',1,true))
assert(missing_content:find('href="https://example.test/image.png"',1,true))
assert(not missing_files['image1.png'])
local _,bad_image=Converter.build(html,'123',function() return '<html>Not an image</html>' end)
assert(bad_image==1)
local cancel={}
package.loaded['ao3lib.ao3.background']={isCancelled=function(err) return err==cancel end}
local completed,err=pcall(Converter.build,html,'123',function() error(cancel,0) end)
assert(not completed and err==cancel,'Cancellation must not be treated as a missing image')
-- Regression for work 52247068: author HTML uses bare <br> inside emphasis.
local html_breaks=html:gsub('<img[^>]+/>',''):gsub('Content&nbsp;', '<em>Content<br>More</em>')
local repaired=Converter.build(html_breaks,'123')
local joined={}
for path,bytes in pairs(repaired) do
    if path:match('%.xhtml$') then
        require('ao3lib.library.cleanup_xml').parse(bytes)
        joined[#joined+1]=bytes
    end
end
assert(table.concat(joined):find('<em>Content<br/>More</em>',1,true))
-- Optional real example supplied beside the repository; never needed by CI.
local sample=io.open('../Wish for a Bitch.html','rb')
if sample then
    local result=Converter.build(sample:read('*a'),'69412136');sample:close()
    assert(result['content.opf']:find('<dc:language>en</dc:language>',1,true))
    assert(result['content.opf']:find('ao3:words" content="6,768"',1,true))
    local output=os.getenv('AO3_EPUB_TEST_OUTPUT')
    if output then
        for path,bytes in pairs(result) do
            local f=assert(io.open(output..'/'..path,'wb'));assert(f:write(bytes));f:close()
        end
    end
end
print('HTML EPUB conversion tests passed')

-- Exercise archive creation and verification on a .part staging filename.
local entries, compression, first={},nil,true
local Writer={}
function Writer:new() return self end
function Writer:open(path,format) assert(path=='/tmp/converted.epub.part' and format=='epub');return true end
function Writer:setZipCompression(value) compression=value;return true end
function Writer:addFileFromMemory(name,bytes)
    if first then assert(name=='mimetype' and compression=='store');first=false end
    entries[name]=bytes;return true
end
function Writer:close() end
local Reader={}
function Reader:new() return setmetatable({entries={}}, {__index=self}) end
function Reader:open() for name,bytes in pairs(entries) do self.entries[name]={size=#bytes} end;return true end
function Reader:iterate() return function() return nil end end
function Reader:extractToMemory(name) return entries[name] end
function Reader:close() end
package.loaded['ffi/archiver']={Writer=Writer,Reader=Reader}
Converter.convert(html:gsub('<img[^>]+/>',''),'/tmp/converted.epub.part','123')
assert(entries['mimetype']=='application/epub+zip')
print('PASS: archive writing, uncompressed first mimetype, and metadata verification of staged EPUB')

-- Real AO3 layout: hidden preface/story/afterword headings and chapter notes.
local multi=html:gsub('<img[^>]+/>','')
    :gsub('<div id="preface">','<div id="preface"><h2 class="toc-heading">Preface</h2>')
    :gsub('<div id="afterword">','<div id="afterword"><h2 class="toc-heading">Afterword</h2>')
    :gsub('Chapter one</h2>','Chapter one</h2><p id="chapter-one"><a href="#note">End notes</a></p>')
    :gsub('End note</p>','End note <a href="#chapter-one">Back</a></p>')
local split=Converter.build(multi,'123')
assert(split['work_split_004.xhtml'])
assert(split['work_split_002.xhtml']:find('work_split_004.xhtml#note',1,true))
assert(split['work_split_004.xhtml']:find('work_split_002.xhtml#chapter-one',1,true))
assert(not split['work_split_003.xhtml']:find('id="chapters"',1,true))
assert(split['toc.ncx']:find('Preface',1,true) and split['toc.ncx']:find('Afterword',1,true))
assert(not split['toc.ncx']:find('Title &amp; more',split['toc.ncx']:find('<navMap>',1,true),true))
print('PASS: multichapter spine, separate title page, forward/backward notes and unique wrapper IDs')

local probe=Reader:new();probe:open()
local Epub=require('ao3lib.library.epub')
local marked=Epub.scanReader(probe)
assert(marked._ao3_html_conversion)
local Bookshelf=require('ao3lib.bookshelf.metadata')
local visible=Bookshelf.fromWork(marked)
marked._ao3_html_conversion=nil
local unmarked=Bookshelf.fromWork(marked)
for k,v in pairs(visible) do
    if type(v)=='table' then
        for i,value in ipairs(v) do assert(unmarked[k][i]==value) end
    else assert(unmarked[k]==v) end
end
assert(not visible._ao3_html_conversion)
entries['content.opf']=entries['content.opf']:gsub('<meta name="ao3lib:html%-conversion" content="1"/>','')
assert(Epub.scanReader(probe)._ao3_html_conversion,'Earlier unmarked fallback files must be recognized')
entries['content.opf']=entries['content.opf']:gsub('<dc:source>.-</dc:source>','')
assert(not Epub.scanReader(probe)._ao3_html_conversion,'A similar EPUB without converter provenance is not a fallback')
print('PASS: private provenance marker, legacy detection, and unchanged Bookshelf metadata')

-- AO3's multichapter download labels chapters with "heading", not "title".
local ao3_chapters=html:gsub('<img[^>]+/>','')
    :gsub('<h2 class="title">Chapter one</h2>', '<div class="meta group"><h2 class="heading">Chapter one</h2></div>')
    :gsub('<h2 class="title">Chapter two</h2>', '<div class="meta group"><h2 class="heading">Chapter two</h2></div>')
    :gsub('Content&nbsp;', 'Content&nbsp;<h2 class="heading">Story heading</h2>')
local ao3_result=Converter.build(ao3_chapters,'123')
assert(ao3_result['toc.ncx']:find('Chapter one',1,true) and ao3_result['toc.ncx']:find('Chapter two',1,true))
assert(not ao3_result['toc.ncx']:find('Story heading',1,true),'Arbitrary story headings must not become chapters')
assert(ao3_result['content.opf']:find('<dc:description>&lt;p&gt;A &amp;amp; B&lt;/p&gt;</dc:description>',1,true))
print('PASS: AO3 h2.heading chapters, story-heading isolation and formatted summary metadata')
