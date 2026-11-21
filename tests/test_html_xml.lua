package.path='./?.lua;'..package.path
local XML=require('ao3lib.library.cleanup_xml')
local HTML=require('ao3lib.library.html_xml')
local function parse(body)
    return HTML.parse('<html><head><title>Example</title><meta charset="utf-8"></head><body>'..body..'</body></html>')
end
local function normalized(body) return XML.serialize(parse(body)) end
local function text(n)
    if type(n)=='string' then return n end
    local out={};for _,c in ipairs(n.children) do out[#out+1]=text(c) end;return table.concat(out)
end
local html=normalized('<p>One<br>Two<hr><p>Three')
assert(html:find('<br/>',1,true) and html:find('<hr/>',1,true))
assert(text(parse('<p><em>One</p><p>Two</p>'))=='ExampleOneTwo')
assert(normalized('<em><strong>One</em>Two</strong>'):find('<em><strong>One</strong></em><strong>Two</strong>',1,true))
assert(normalized('<ul><li>One<li>Two</ul>'):find('<li>One</li><li>Two</li>',1,true))
assert(normalized('<dl><dt>Name<dd>Value</dl>'):find('<dt>Name</dt><dd>Value</dd>',1,true))
assert(normalized("<P class='a' data-note=plain>One<BR>Two</P>"):find('<p class="a" data-note="plain">One<br/>Two</p>',1,true))
assert(not pcall(HTML.parse,'<html><body><p>Truncated'))
assert(not pcall(HTML.parse,'<html><head></head><body><p>Missing body end</html>'))
assert(not pcall(XML.parse,'<html><body><p><em>One</p></body></html>'),'Cleanup parser must remain strict')
local valid='<html><head></head><body><p class="a">One<br/>Two</p></body></html>'
assert(XML.serialize(HTML.parse(valid))==valid,'Valid XHTML should remain unchanged')
print('PASS: HTML void elements, optional paragraph/list tags, overlapping inline formatting, quoted attributes, truncation rejection and strict cleanup isolation')
