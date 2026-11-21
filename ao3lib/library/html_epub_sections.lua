-- Split at the same semantic headings used by AO3's Calibre conversion.
-- Clone enclosing elements so chapter notes and cross-document links survive.
local XML=require('ao3lib.library.cleanup_xml')
local M={}
local function class(n,c) return (' '..((n.attrs or {}).class or '')..' '):find(' '..c..' ',1,true) end
local function escape(s) return (s:gsub('&','&amp;'):gsub('"','&quot;'):gsub('<','&lt;'):gsub('>','&gt;')) end
local function rawtext(n)
    if type(n)=='string' then return n end
    local out={};for _,c in ipairs(n.children) do out[#out+1]=rawtext(c) end
    return table.concat(out)
end
local function walk(n,fn)
    if type(n)~='table' then return end
    fn(n);for _,c in ipairs(n.children) do walk(c,fn) end
end
function M.build(root,title,language)
    local body,css,headtitle=nil,{},title
    for _,n in ipairs(root.children) do
        if type(n)=='table' and n.tag=='body' then body=n end
        if type(n)=='table' and n.tag=='head' then
            walk(n,function(c)
                if c.tag=='style' then css[#css+1]=rawtext(c) end
                if c.tag=='title' then headtitle=rawtext(c) end
            end)
        end
    end
    assert(body,'HTML body is missing')
    -- Multichapter AO3 HTML uses h2.heading inside each chapter's metadata
    -- group. Those are navigation headings, unlike headings in story prose.
    local chapter_headings={}
    local function chapterHeading(n)
        return type(n)=='table' and (n.tag=='h2' or n.tag=='h3') and class(n,'heading')
    end
    walk(body,function(n)
        if not n.attrs or n.attrs.id~='chapters' then return end
        for _,child in ipairs(n.children) do
            if chapterHeading(child) then chapter_headings[child]=true
            elseif type(child)=='table' and child.tag=='div' and class(child,'meta') then
                for _,heading in ipairs(child.children) do
                    if chapterHeading(heading) then chapter_headings[heading]=true end
                end
            end
        end
    end)
    local section,started=1,false
    local navigation={}
    local function split(n)
        if type(n)=='string' then return {[section]=n} end
        local boundary=chapter_headings[n] or n.tag=='h1' or ((n.tag=='h2' or n.tag=='h3') and (class(n,'toc-heading') or class(n,'title')))
        if boundary then
            if started then section=section+1 end
            started=true
            -- AO3's title/summary page is in the spine, but not the NCX.
            if n.tag~='h1' then navigation[#navigation+1]={section=section,title=rawtext(n):gsub("%s+"," "):match("^%s*(.-)%s*$")} end
        end
        local parts={}
        local start=section
        local function ensure(i)
            if not parts[i] then
                parts[i]={tag=n.tag,attrs=n.attrs,open=n.open,close=n.close,children={}}
            end
            return parts[i]
        end
        ensure(start)
        for _,c in ipairs(n.children) do
            for i,part in pairs(split(c)) do
                local p=ensure(i);p.children[#p.children+1]=part
            end
        end
        -- Whitespace before a heading must not strand a wrapper's anchor
        -- at the end of the preceding file (notably #chapters/#afterword).
        local owner=start
        for i=start,section do
            if parts[i] and rawtext(parts[i]):find('%S') then owner=i;break end
        end
        for i,part in pairs(parts) do
            if i~=owner then part.open=part.open:gsub('%s+id%s*=%s*([\'"]).-%1','') end
        end
        return parts
    end
    local parts=split(body)
    local names,ids={},{}
    for i=1,section do
        names[i]=string.format('work_split_%03d.xhtml',i-1)
        walk(parts[i],function(n)
            local id=n.open and (n.open:match('%sid%s*=%s*"([^"]+)"') or n.open:match("%sid%s*=%s*'([^']+)'") )
            if id then assert(not ids[id],'Duplicate HTML ID: '..id);ids[id]=names[i] end
        end)
    end
    local files,manifest,spine,points={},{},{},{}
    for i=1,section do
        walk(parts[i],function(n)
            if n.open then
                n.open=n.open:gsub('(%shref%s*=%s*)([\'"])#(.-)%2',function(prefix,quote,id)
                    assert(ids[id],'Broken internal HTML link: '..id)
                    return prefix..quote..ids[id]..'#'..id..quote
                end)
            end
        end)
        files[names[i]]='<?xml version="1.0" encoding="UTF-8"?>\n<html xmlns="http://www.w3.org/1999/xhtml" lang="'..escape(language)..'" xml:lang="'..escape(language)..'"><head><title>'..headtitle..'</title><meta http-equiv="Content-Type" content="text/html; charset=utf-8"/><link rel="stylesheet" type="text/css" href="stylesheet.css"/><link rel="stylesheet" type="text/css" href="page_styles.css"/></head>'..XML.serialize(parts[i])..'</html>'
        manifest[#manifest+1]='<item id="html'..i..'" href="'..names[i]..'" media-type="application/xhtml+xml"/>'
        spine[#spine+1]='<itemref idref="html'..i..'"/>'
    end
    if #navigation==0 then navigation[1]={section=1,title=title} end
    for i,n in ipairs(navigation) do points[#points+1]='<navPoint id="nav'..i..'" playOrder="'..i..'"><navLabel><text>'..n.title..'</text></navLabel><content src="'..names[n.section]..'"/></navPoint>' end
    -- Match the computed layout in the supplied AO3 EPUB without Calibre's
    -- generated class names. Keep author styling, then normalize AO3 chrome.
    files['stylesheet.css']=table.concat(css,'\n')..[[
body { display: block; font-size: 1em; padding: 0; margin: 0 5pt; }
p { display: block; margin: 1em 0; }
p.message, .byline { text-align: center; }
.meta h1 { font-size: 1.41667em; line-height: 1.2; text-align: center; margin: 0.67em 0; }
.meta h2 { page-break-before: auto; }
.meta dl.tags { display: block; margin: 1em 0; padding: 0; border: none; }
.meta dt { display: block; font-weight: bold; margin: 0; }
.meta dd { display: block; margin: 0 0 1em 1em; }
#chapters { font-family: serif; padding: 0; }
.userstuff { font-family: serif; margin: 1em 0; padding: 0; }
blockquote.userstuff { margin: 1em; }
.toc-heading { display: none; }
]]
    files['page_styles.css']='@page { margin-bottom: 5pt; margin-top: 5pt; }\n'
    manifest[#manifest+1]='<item id="css" href="stylesheet.css" media-type="text/css"/><item id="page_css" href="page_styles.css" media-type="text/css"/>'
    return files,table.concat(manifest),table.concat(spine),table.concat(points)
end
return M
