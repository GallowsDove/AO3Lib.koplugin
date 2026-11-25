-- Conservative, lossless XHTML cleanup. Untouched tokens retain their exact bytes.
-- No entity expansion, DTD loading, HTML repair, or CSS rewriting.
local M = {}
local protected_tags = {pre=true,code=true,blockquote=true,q=true,table=true,ul=true,ol=true,dl=true,svg=true,math=true,ruby=true}
local media = {img=true,svg=true,math=true,audio=true,video=true,object=true,iframe=true,hr=true}
local inline = {a=true,em=true,strong=true,b=true,i=true,u=true,s=true,span=true,small=true,sub=true,sup=true,mark=true}
local identities = {id=true,name=true,["xml:id"]=true}
local function compact(s)
    return (s:gsub('&#[xX]0*[aA]0;', ''):gsub('&#0*160;', ''):gsub('&nbsp;', '')
        :gsub('\194\160', ''):gsub('\226\128\139', ''):gsub('\239\187\191', ''):gsub('\226\129\160', ''):gsub('%s+', ''))
end
local function attrs(s)
    local out = {}
    for k, q, v in s:gmatch('([%w_:%.%-]+)%s*=%s*([\'"])(.-)%2') do out[k]=v end
    return out
end
local function tagend(s, start)
    local quote
    for i=start,#s do
        local c=s:sub(i,i)
        if quote then if c==quote then quote=nil end
        elseif c=='"' or c=="'" then quote=c
        elseif c=='>' then return i end
    end
    error('Unterminated XML tag')
end
local function noop() end
function M.parse(s,checkpoint)
    checkpoint=checkpoint or noop
    assert(#s <= 16*1024*1024, 'XHTML document is too large')
    local root={tag='',children={}}
    local stack={root}
    local pos, count=1,0
    local function add(n) local p=stack[#stack]; p.children[#p.children+1]=n end
    while pos<=#s do
        checkpoint()
        local a=s:find('<',pos,true)
        if not a then add(s:sub(pos)); break end
        if a>pos then add(s:sub(pos,a-1)) end
        local b, opaque
        if s:sub(a,a+3)=='<!--' then b=assert(s:find('-->',a+4,true),'Unterminated comment')+2; opaque=true
        elseif s:sub(a,a+8)=='<![CDATA[' then b=assert(s:find(']]>',a+9,true),'Unterminated CDATA')+2; opaque=true
        elseif s:sub(a,a+1)=='<?' then b=assert(s:find('?>',a+2,true),'Unterminated PI')+1; opaque=true
        else b=tagend(s,a+1) end
        local raw=s:sub(a,b)
        if opaque or raw:match('^<!') then
            assert(opaque or not raw:match('^<![^>]*%['), 'Internal DTD subsets are unsupported')
            add({tag='!',open=raw,children={}})
        elseif raw:match('^</') then
            local name=raw:match('^</([%w_:%.%-]+)%s*>$')
            assert(#stack>1 and stack[#stack].name==name,'Unbalanced XHTML')
            stack[#stack].close=raw; stack[#stack]=nil
        else
            local name=assert(raw:match('^<([%w_:%.%-]+)[%s/>]'),'Invalid XML tag')
            local n={name=name,tag=name:match('([^:]+)$'),open=raw,attrs=attrs(raw),children={}}
            add(n); count=count+1
            assert(count<=200000 and #stack<128,'XHTML complexity limit exceeded')
            if not raw:match('/%s*>$') then stack[#stack+1]=n end
        end
        pos=b+1
    end
    assert(#stack==1,'Unclosed XHTML tag')
    return root
end
local function render(n,out,checkpoint)
    checkpoint()
    if type(n)=='string' then out[#out+1]=n; return end
    out[#out+1]=n.open or ''
    for _,c in ipairs(n.children) do render(c,out,checkpoint) end
    out[#out+1]=n.close or ''
end
function M.serialize(n,checkpoint) local out={}; render(n,out,checkpoint or noop); return table.concat(out) end
local function special_style(s)
    s=(s or ''):lower()
    return s:match('text%-align%s*:%s*center') or s:match('text%-align%s*:%s*right')
        or s:match('white%-space%s*:%s*pre') or s:match('white%-space%s*:%s*break%-spaces')
        or s:match('background[^:]*:[^;]*url%s*%(')
end
function M.protectedClasses(css)
    local out={}
    for c in ('message poetry poem verse letter center centered notes endnotes preface summary endnote-link'):gmatch('%S+') do out[c]=true end
    for selectors, decl in (css or ''):gmatch('([^{}]+){([^{}]*)}') do
        if special_style(decl) then
            for selector in selectors:gmatch('[^,]+') do
                local c=selector:match('^%s*[%w]*%.([%w_%-]+)%s*$')
                if c then out[c]=true end
            end
        end
    end
    return out
end
local function hasclass(n,pattern)
    for c in ((n.attrs or {}).class or ''):gmatch('%S+') do if c:match(pattern) then return true end end
end
local function protected(n,classes)
    local a=n.attrs or {}
    if protected_tags[n.tag] or special_style(a.style) or a.align=='center' or a.align=='right' then return true end
    for c in (a.class or ''):gmatch('%S+') do if classes[c] then return true end end
    local id=(a.id or ''):lower()
    for _,word in ipairs({'note','summary','preface'}) do if id:find(word,1,true) then return true end end
    return false
end
local function blank(n)
    if n.tag~='p' then return false end
    local function empty(c)
        if type(c)=='string' then return compact(c)=='' end
        if media[c.tag] or c.tag=='!' then return false end
        for k in pairs(c.attrs or {}) do if identities[k] or k=='href' then return false end end
        for _,child in ipairs(c.children) do if not empty(child) then return false end end
        return true
    end
    return empty(n)
end
local function gap(n) return hasclass(n,'^ao3lib%-scene%-gap$') end
local function scene(n)
    local name=(n.name or 'p'):gsub('[^:]+$','p')
    return {name=name,tag='p',attrs={class='ao3lib-scene-gap'},open='<'..name..' class="ao3lib-scene-gap" style="margin: 0; height: 1em; line-height: 1em; text-indent: 0;">',close='</'..name..'>',children={'\194\160'}}
end
-- Compare styled text, links, anchors and media before accepting any output.
local function invariants(root,checkpoint)
    local chunks, ids, assets={}, {}, {}
    local context, text='', {}
    local function flush()
        if #text>0 then
            local joined=table.concat(text)
            chunks[#chunks+1]=#context..':'..context..#joined..':'..joined
        end
        text={}
    end
    local function walk(n,ctx)
        checkpoint()
        if type(n)=='string' then
            local t=compact(n)
            if t~='' then if ctx~=context then flush();context=ctx end; text[#text+1]=t end
            return
        end
        local a={}
        for k,v in pairs(n.attrs or {}) do
            if identities[k] then ids[#ids+1]=k..'='..v else a[#a+1]=k..'='..v end
        end
        table.sort(a)
        local sig=n.tag..'|'..table.concat(a,'|')
        if media[n.tag] then assets[#assets+1]=sig end
        if inline[n.tag] then ctx=ctx..'/'..sig end
        if n.tag=='!' then assets[#assets+1]=n.open end
        for _,c in ipairs(n.children) do walk(c,ctx) end
    end
    walk(root,''); flush(); table.sort(ids);table.sort(assets)
    return table.concat(chunks,'\0')..'\1'..table.concat(ids,'\0')..'\1'..table.concat(assets,'\0')
end
local function split(p,stats,classes,checkpoint)
    local cuts,removed={},{}
    local unsafe=false
    -- Some AO3 exports put an entire chapter in one paragraph, separating
    -- prose paragraphs with a single break. Require many substantial lines
    -- before treating those breaks as paragraphs, to leave verse and other
    -- intentional short-line layouts alone.
    local lengths,current={},0
    local function measure(n)
        for _,c in ipairs(n.children) do
            checkpoint()
            if type(c)=='string' then current=current+#compact(c)
            elseif c.tag=='br' then lengths[#lengths+1]=current;current=0
            elseif inline[c.tag] then measure(c) end
        end
    end
    measure(p);lengths[#lengths+1]=current
    local substantial,total=0,0
    for _,length in ipairs(lengths) do
        total=total+length
        if length>=30 then substantial=substantial+1 end
    end
    local single_prose=#lengths>=13 and total>=1000 and substantial>=math.ceil(#lengths*.85)
    local function find(n)
        for _,c in ipairs(n.children) do
            checkpoint()
            if type(c)=='table' and (protected(c,classes) or media[c.tag] or c.tag=='!' or (c.tag~='br' and not inline[c.tag])) then unsafe=true end
        end
        local i=1
        while i<=#n.children do
            checkpoint()
            local c=n.children[i]
            if type(c)=='table' and c.tag=='br' then
                local j,run=i+1,{c}
                while j<=#n.children do
                    checkpoint()
                    local nextc=n.children[j]
                    if type(nextc)=='string' and compact(nextc)=='' then j=j+1
                    elseif type(nextc)=='table' and nextc.tag=='br' then run[#run+1]=nextc;j=j+1
                    else break end
                end
                if #run>=2 or single_prose then
                    for _,br in ipairs(run) do
                        for k in pairs(br.attrs) do if identities[k] or k=='style' then unsafe=true end end
                        removed[br]=true
                    end
                    cuts[c]=#run
                end
                i=j
            else
                if type(c)=='table' then find(c) end
                i=i+1
            end
        end
    end
    find(p)
    if unsafe or not next(cuts) then return {p} end
    local originals,clones,seen={p},{},{}
    local out={}
    local function shallow(n)
        local open=n.open
        if seen[n] then
            for k in pairs(identities) do
                local pat=k:gsub('([^%w])','%%%1')
                open=open:gsub('%s+'..pat..'%s*=%s*"[^"]*"',''):gsub("%s+"..pat.."%s*=%s*'[^']*'",'')
            end
        end
        seen[n]=true
        return {tag=n.tag,name=n.name,open=open,close=n.close,attrs=attrs(open),children={}}
    end
    local function start()
        clones={}
        for i,n in ipairs(originals) do
            local c=shallow(n)
            if i==1 then out[#out+1]=c else clones[i-1].children[#clones[i-1].children+1]=c end
            clones[i]=c
        end
    end
    local function walk(n)
        for _,c in ipairs(n.children) do
            checkpoint()
            if cuts[c] then
                stats.break_runs_converted=stats.break_runs_converted+1
                if cuts[c]>=4 then out[#out+1]=scene(p) end
                start()
            elseif not removed[c] then
                if type(c)=='string' then
                    local target=clones[#clones].children;target[#target+1]=c
                else
                    originals[#originals+1]=c
                    local new=shallow(c);local target=clones[#clones].children;target[#target+1]=new
                    clones[#clones+1]=new;walk(c);clones[#clones]=nil;originals[#originals]=nil
                end
            end
        end
    end
    start();walk(p)
    local kept={}
    for _,n in ipairs(out) do checkpoint();if not blank(n) or gap(n) then kept[#kept+1]=n end end
    while kept[1] and gap(kept[1]) do table.remove(kept,1) end
    while kept[#kept] and gap(kept[#kept]) do kept[#kept]=nil end
    return #kept>0 and kept or {p}
end
function M.clean(data,classes,yield_fn)
    local steps,phase=0,'Reading paragraphs'
    local function checkpoint()
        steps=steps+1
        if yield_fn and steps%256==0 then yield_fn(phase) end
    end
    local root=M.parse(data,checkpoint)
    phase='Checking original text'
    local before=invariants(root,checkpoint)
    local stats={break_runs_converted=0,blank_paragraphs_removed=0}
    classes=classes or M.protectedClasses('')
    local function containsUserstuff(n)
        for _,c in ipairs(n.children) do
            checkpoint()
            if type(c)=='table' and (hasclass(c,'^userstuff%d*$') or containsUserstuff(c)) then return true end
        end
    end
    local function clean(n,blocked)
        blocked=blocked or protected(n,classes)
        if blocked then return end
        local children={}
        for _,c in ipairs(n.children) do
            checkpoint()
            if type(c)=='table' then
                if c.tag=='p' and not gap(c) and not protected(c,classes) then
                    for _,piece in ipairs(split(c,stats,classes,checkpoint)) do children[#children+1]=piece end
                else clean(c,false);children[#children+1]=c end
            else children[#children+1]=c end
        end
        n.children=children
        local out,i,preceding={},1,false
        while i<=#children do
            checkpoint()
            local c=children[i]
            if type(c)=='table' and blank(c) and not gap(c) and not protected(c,classes) then
                local j,count=i+1,1
                while j<=#children do
                    checkpoint()
                    local x=children[j]
                    if type(x)=='string' and compact(x)=='' then j=j+1
                    elseif type(x)=='table' and blank(x) and not gap(x) and not protected(x,classes) then count=count+1;j=j+1
                    else break end
                end
                if count>=2 and preceding and j<=#children then out[#out+1]=scene(c);count=count-1 end
                stats.blank_paragraphs_removed=stats.blank_paragraphs_removed+count
                for k=i,j-1 do if type(children[k])=='string' then out[#out+1]=children[k] end end
                i=j
            else out[#out+1]=c;if type(c)=='table' then preceding=true end;i=i+1 end
        end
        n.children=out
    end
    local function scopes(n,chapters,blocked)
        checkpoint()
        chapters=chapters or (n.attrs or {}).id=='chapters'
        blocked=blocked or protected(n,classes)
        if blocked then return end
        if chapters and n.tag=='div' and hasclass(n,'^userstuff%d*$') and not containsUserstuff(n) then clean(n,false);return end
        for _,c in ipairs(n.children) do if type(c)=='table' then scopes(c,chapters,blocked) end end
    end
    phase='Cleaning paragraphs'
    scopes(root,false,false)
    phase='Writing paragraphs'
    local output=M.serialize(root,checkpoint)
    phase='Verifying cleaned text'
    assert(invariants(M.parse(output,checkpoint),checkpoint)==before,'Cleanup changed text, formatting, links, media or anchors')
    return output,stats
end
return M
