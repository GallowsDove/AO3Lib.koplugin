-- Convert AO3's XHTML download without an external converter.
local XML = require('ao3lib.library.cleanup_xml')
local M = {}
local function escape(s)
    return (s:gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;'):gsub('"','&quot;'))
end
local function plain(n)
    if type(n)=='string' then return n end
    local out={}
    for _,c in ipairs(n.children) do out[#out+1]=plain(c) end
    return table.concat(out)
end
local function walk(n,fn,parent)
    if type(n)~='table' then return end
    fn(n,parent)
    for _,c in ipairs(n.children) do walk(c,fn,n) end
end
local function class(n,c) return (' '..((n.attrs or {}).class or '')..' '):find(' '..c..' ',1,true) end
local function trim(s) return (s:gsub('^%s+',''):gsub('%s+$','')) end
function M.build(html, expected_id, fetch, base, progress)
    if progress then progress('Preparing the HTML for conversion…') end
    assert(type(html)=='string' and #html<=16*1024*1024,'HTML is too large')
    -- EPUB XHTML must not depend on an external DTD for named entities.
    html=html:gsub('&nbsp;','&#160;')
    for entity in html:gmatch('&([%a][%w]+);') do
        assert(entity=='amp' or entity=='lt' or entity=='gt' or entity=='quot' or entity=='apos','Unsupported XHTML entity: '..entity)
    end
    local tree=require('ao3lib.library.html_xml').parse(html)
    local id=require('ao3lib.library.epub').fromPreface(XML.serialize(tree))
    assert(id and tostring(expected_id)==id,'HTML does not match the requested AO3 work')
    local preface, chapters, root, title, authors, summary = nil,nil,nil,nil,{},nil
    walk(tree,function(n)
        if n.tag=='html' then root=n end
        if n.attrs and n.attrs.id=='preface' then preface=n end
        if n.attrs and n.attrs.id=='chapters' then chapters=n end
    end)
    assert(root and preface and chapters,'Incomplete AO3 HTML download')
    local subjects, dates, custom={'<dc:subject>Fanworks</dc:subject>'}, {}, {}
    local subject_groups={}
    local series={}
    walk(preface,function(n)
        if n.tag=='h1' and not title then title=trim(plain(n)) end
        if n.tag=='a' and n.attrs.rel=='author' then authors[#authors+1]=trim(plain(n)) end
        if n.tag=='div' and class(n,'meta') then
            for i,c in ipairs(n.children) do
                if type(c)=='table' and c.tag=='p' and trim(plain(c))=='Summary' then
                    for j=i+1,#n.children do
                        local nextnode=n.children[j]
                        if type(nextnode)=='table' then
                            if nextnode.tag=='blockquote' then
                                local markup={}
                                for _,child in ipairs(nextnode.children) do
                                    markup[#markup+1]=type(child)=='string' and child or XML.serialize(child)
                                end
                                summary=escape(trim(table.concat(markup)))
                            end
                            break
                        end
                    end
                end
            end
        end
        if n.tag=='dl' and class(n,'tags') then
            local label
            for _,c in ipairs(n.children) do
                if type(c)=='table' and c.tag=='dt' then label=trim(plain(c)):gsub(':$','')
                elseif type(c)=='table' and c.tag=='dd' and label then
                    local value=trim(plain(c))
                    if label=='Stats' then
                        for k,v in value:gmatch('(%a+):%s*([%d,/?%-]+)') do
                            if k=='Published' then dates[#dates+1]='<dc:date>'..v..'T00:00:00+00:00</dc:date>' end
                            custom[#custom+1]='<meta name="ao3:'..k:lower()..'" content="'..v..'"/>'
                        end
                    elseif label=='Series' then
                        series=require('ao3lib.library.epub').seriesFromHTML(XML.serialize(c))
                        custom[#custom+1]='<meta name="ao3:series" content="'..value:gsub('"','&quot;')..'"/>'
                    elseif label~='Language' then
                        subject_groups[label]=subject_groups[label] or {}
                        walk(c,function(a) if a.tag=='a' then subject_groups[label][#subject_groups[label]+1]=trim(plain(a)) end end)
                        custom[#custom+1]='<meta name="ao3:'..escape(label:lower())..'" content="'..value:gsub('"','&quot;')..'"/>'
                    end
                end
            end
        end
    end)
    if #authors==0 then
        walk(preface,function(n)
            if n.tag=='div' and class(n,'byline') then
                local author=trim(plain(n)):gsub('^by%s+','')
                if author~='' then authors[#authors+1]=author end
            end
        end)
    end
    assert(title and #authors>0,'Missing title or authors')
    local seen={Fanworks=true}
    for _,label in ipairs({'Rating','Fandom','Fandoms','Relationship','Relationships','Character','Characters','Additional Tags','Category','Categories','Archive Warning','Archive Warnings'}) do
        for _,value in ipairs(subject_groups[label] or {}) do
            if not seen[value] then subjects[#subjects+1]='<dc:subject>'..value..'</dc:subject>';seen[value]=true end
        end
    end
    -- EPUB 2 readers (including KOReader/Bookshelf) recognize Calibre's
    -- embedded series fields. They support one primary series; every AO3
    -- membership remains in the original preface for the plugin's links.
    if series[1] then
        custom[#custom+1]='<meta name="calibre:series" content="'..escape(series[1].title)..'"/>'
        if tonumber(series[1].position) then
            custom[#custom+1]='<meta name="calibre:series_index" content="'..escape(series[1].position)..'"/>'
        end
    end
    local files, manifest={}, {}
    local images,total,missing={},#html,0
    local image_count,image_index=0,0
    if progress then walk(tree,function(n) if n.tag=='img' then image_count=image_count+1 end end) end
    walk(tree,function(n,parent)
        if n.tag=='img' then
            image_index=image_index+1
            if progress then progress(string.format('Processing image %d of %d…',image_index,image_count)) end
            local src=n.attrs.src
            local url=src and src:gsub('&amp;','&')
            if url and not url:match('^https?://') then
                local ok,resolved=pcall(function() return require('socket.url').absolute(base,url) end)
                url=ok and resolved or nil
            end
            local image=src and images[src]
            if image==nil and src then
                local ok,bytes=pcall(function()
                    assert(url and url:match('^https?://') and fetch,'Image URL unavailable')
                    return fetch(url,true)
                end)
                if not ok and type(bytes)~='string' and require('ao3lib.ao3.background').isCancelled(bytes) then error(bytes,0) end
                local ext,media
                if ok and type(bytes)=='string' then
                    if bytes:sub(1,8)=='\137PNG\13\10\26\10' then ext,media='png','image/png'
                    elseif bytes:sub(1,3)=='\255\216\255' then ext,media='jpg','image/jpeg'
                    elseif bytes:sub(1,6)=='GIF87a' or bytes:sub(1,6)=='GIF89a' then ext,media='gif','image/gif' end
                end
                if ext and total+#bytes<=64*1024*1024 then
                    total=total+#bytes
                    local index=#manifest+1
                    image='image'..index..'.'..ext; files[image]=bytes
                    manifest[#manifest+1]='<item id="image'..index..'" href="'..image..'" media-type="'..media..'"/>'
                else image=false end
                images[src]=image
            end
            if image then
                n.open=n.open:gsub('(%ssrc%s*=%s*)([\'"])(.-)%2',function(prefix) return prefix..'"'..image..'"' end)
            else
                missing=missing+1
                local label='[Image unavailable]'
                local safe=url and url:match('^https?://') and escape(url)
                n.tag='span';n.open='<span>';n.close='</span>'
                if safe and (not parent or parent.tag~='a') then
                    n.children={'<a href="'..safe..'">'..label..'</a>'}
                elseif safe then n.children={label..' '..safe}
                else n.children={label} end
            end
        end
    end)
    local language=root.attrs['xml:lang'] or root.attrs.lang or 'en'
    if progress then progress('Building the EPUB chapters…') end
    local documents, document_manifest, spine, points=require('ao3lib.library.html_epub_sections').build(root,title,language)
    for name,bytes in pairs(documents) do files[name]=bytes end
    local creators={}
    for _,author in ipairs(authors) do creators[#creators+1]='<dc:creator opf:file-as="'..author:lower():gsub('"','&quot;')..'" opf:role="aut">'..author..'</dc:creator>' end
    local uid='https://archiveofourown.org/works/'..id
    files['content.opf']='<?xml version="1.0" encoding="UTF-8"?>'..
        '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="work-id">'..
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">'..
        '<meta name="ao3lib:html-conversion" content="1"/>'..
        '<dc:identifier id="work-id">'..uid..'</dc:identifier><dc:source>'..uid..'</dc:source>'..
        '<dc:title>'..title..'</dc:title><dc:language>'..escape(language)..'</dc:language>'..table.concat(creators)..
        '<dc:publisher>Archive of Our Own</dc:publisher><dc:description>'..(summary or '')..'</dc:description>'..
        table.concat(subjects)..table.concat(dates)..table.concat(custom)..'</metadata><manifest>'..
        document_manifest..
        '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'..table.concat(manifest)..
        '</manifest><spine toc="ncx">'..spine..'</spine></package>'
    files['toc.ncx']='<?xml version="1.0" encoding="UTF-8"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="'..uid..'"/><meta name="dtb:depth" content="1"/><meta name="dtb:totalPageCount" content="0"/><meta name="dtb:maxPageNumber" content="0"/></head><docTitle><text>'..title..'</text></docTitle><navMap>'..points..'</navMap></ncx>'
    files['META-INF/container.xml']='<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'
    return files,missing
end
function M.convert(html,path,id,fetch,base,progress)
    local files,missing=M.build(html,id,fetch,base,progress)
    if progress then progress('Writing the EPUB…') end
    local Archiver=require('ffi/archiver')
    local writer=Archiver.Writer:new()
    local reader
    local ok,err=pcall(function()
        assert(writer:open(path,'epub'),'Cannot create EPUB')
        assert(writer:setZipCompression('store'))
        assert(writer:addFileFromMemory('mimetype','application/epub+zip',os.time()))
        assert(writer:setZipCompression('deflate'))
        for name,bytes in pairs(files) do assert(writer:addFileFromMemory(name,bytes,os.time()),'Cannot write EPUB entry') end
        writer:close(); writer=nil
        if progress then progress('Verifying the EPUB…') end
        reader=Archiver.Reader:new()
        assert(reader:open(path),'Cannot verify converted EPUB')
        for _ in reader:iterate() do end
        assert(not reader.err,reader.err)
        local work=require('ao3lib.library.epub').scanReader(reader)
        reader:close();reader=nil
        assert(work and tostring(work.id)==tostring(id),'Converted EPUB failed verification')
    end)
    if writer then pcall(function() writer:close() end) end
    if reader then pcall(function() reader:close() end) end
    if not ok then os.remove(path);error(err) end
    return missing
end
return M
