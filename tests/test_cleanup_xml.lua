-- Run from the plugin directory: luajit tests/test_cleanup_xml.lua
package.path='./?.lua;'..package.path
local X=require('ao3lib.library.cleanup_xml')
local function doc(s) return '<?xml version="1.0"?><html><body><div id="chapters"><div class="userstuff">'..s..'</div></div></body></html>' end
local function clean(s,css)
    local out,stats=X.clean(doc(s),X.protectedClasses(css or ''))
    assert(X.clean(out,X.protectedClasses(css or ''))==out,'Cleanup must be idempotent')
    return out,stats
end
local out,s=clean('<p id="p"><em id="em">A<br/><br/>B<a id="link" href="#target">C<br/><br/>D</a>E</em>F</p><p id="target">Target</p>')
assert(s.break_runs_converted==2)
assert(out:find('<p><em>B<a id="link" href="#target">C</a></em></p>',1,true))
assert(out:find('<p><em><a href="#target">D</a>E</em>F</p>',1,true))
for _,id in ipairs({'p','em','link','target'}) do local _,n=out:gsub('id="'..id..'"','');assert(n==1) end
for _,body in ipairs({
    '<p>A<br/>B</p>', '<p>A<br id="anchor"/><br/>B</p>',
    '<p>A<br style="clear: both"/><br/>B</p>', '<p class="verse">A<br/><br/>B</p>',
    '<blockquote><p>A<br/><br/>B</p></blockquote>', '<p>A<img src="art.png"/><br/><br/>B</p>',
    '<p><span class="verse">A<br/><br/>B</span></p>', '<div id="endnotes4"><p>A<br/><br/>B</p></div>',
    '<p style="text-align: right">A<br/><br/>B</p>', '<p>A<!-- comment --><br/><br/>B</p>',
    '<p><![CDATA[<br/><br/>]]></p>',
}) do assert(clean(body)==doc(body),'Formatting must stay byte-identical: '..body) end
out,s=clean('<p>A</p><p>&#160;</p>\n<p> </p><p>B</p><p><img src="art.png"/></p><p id="keep"> </p>')
assert(s.blank_paragraphs_removed==1 and out:find('ao3lib-scene-gap',1,true))
assert(out:find('<p id="keep"> </p>',1,true))
out=clean('<p><br/><br/>A<br/><br/><br/><br/>B<br/><br/></p>')
assert(out:find('ao3lib-scene-gap',1,true) and not out:find('<p></p>',1,true))
local styled='<p class="calibre9">A<br/><br/>B</p>'
assert(clean(styled,'p.calibre9 { text-align: center; }')==doc(styled))
local untouched='<html><body><div id="preface"><p>A<br/><br/>B</p></div><div class="userstuff"><p>C<br/><br/>D</p></div></body></html>'
assert(X.clean(untouched)==untouched)
local prose=string.rep('A long prose paragraph with enough ordinary text to be clearly distinct from a short line.<br/>',15)..'Another long prose paragraph with enough ordinary text to conclude the example.'
out,s=clean('<p>'..prose..'</p>')
assert(s.break_runs_converted==15 and select(2,out:gsub('<p>',''))==16)
local verse='<p>'..string.rep('A short line<br/>',20)..'A final line</p>'
assert(clean(verse)==doc(verse),'Short lines should not be mistaken for prose paragraphs')
local titled='<p class="verse">'..prose..'</p>'
assert(clean(titled)==doc(titled),'Explicitly marked verse must stay unchanged')
local anchored='<p>'..prose:gsub('<br/>','<br id="line"/>',1)..'</p>'
assert(clean(anchored)==doc(anchored),'Anchored single breaks must not be removed')
out,s=clean('<div class="userstuff1"><div class="userstuff2"><p>A<br/><br/>B</p></div></div>')
assert(s.break_runs_converted==1)
assert(not pcall(X.clean,doc('<p>A</div>')))
assert(not pcall(X.clean,'<!DOCTYPE html [<!ENTITY x "bad">]>'..doc('<p>&x;</p>')))
print('AO3 XHTML cleanup tests passed')

-- A single large chapter must yield inside parsing, cleanup and validation.
-- Archive-entry-only scheduling cannot keep input/cancellation responsive here.
local large=doc('<p>'..string.rep('Plain prose<br/><br/>',3000)..'</p>')
local phases,checkpoints={},0
local worker=coroutine.create(function()
    return X.clean(large,nil,function(phase) coroutine.yield(phase) end)
end)
while true do
    local ok,value,stats=coroutine.resume(worker)
    assert(ok,value)
    if coroutine.status(worker)=='dead' then
        assert(stats.break_runs_converted==3000)
        assert(X.clean(value)==value)
        break
    end
    phases[value]=true;checkpoints=checkpoints+1
end
assert(checkpoints>100)
for _,phase in ipairs({'Reading paragraphs','Checking original text','Cleaning paragraphs','Writing paragraphs','Verifying cleaned text'}) do
    assert(phases[phase],'Missing in-document checkpoint: '..phase)
end
local ticks=0
assert(not pcall(X.clean,large,nil,function() ticks=ticks+1;error('cancelled') end))
assert(ticks==1,'Cancellation must stop at the next checkpoint')
print('PASS: large single-chapter scheduling, all validation phases and immediate cancellation')
