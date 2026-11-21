-- AO3 downloads can contain HTML void tags and optional/misnested author tags.
-- Repair only the HTML import path; EPUB formatting cleanup stays strict.
local XML=require('ao3lib.library.cleanup_xml')
local M={}
local void={area=true,base=true,br=true,col=true,embed=true,hr=true,img=true,input=true,link=true,meta=true,param=true,source=true,track=true,wbr=true}
local inline={a=true,b=true,big=true,code=true,del=true,em=true,font=true,i=true,ins=true,s=true,small=true,span=true,strike=true,strong=true,sub=true,sup=true,u=true}
local block={address=true,article=true,aside=true,blockquote=true,div=true,dl=true,fieldset=true,footer=true,form=true,h1=true,h2=true,h3=true,h4=true,h5=true,h6=true,header=true,hr=true,ol=true,p=true,pre=true,section=true,table=true,ul=true}
local function tagend(s,start)
    local quote
    for i=start,#s do
        local c=s:sub(i,i)
        if quote then if c==quote then quote=nil end
        elseif c=='"' or c=="'" then quote=c
        elseif c=='>' then return i end
    end
    error('Unterminated HTML tag')
end
local function opening(name,raw)
    local attrs={}
    local pos=1
    while pos<=#raw do
        local _,b,key=raw:find('^%s*([%w_:%.%-]+)',pos)
        if not key then assert(raw:sub(pos):match('^%s*/?%s*$'),'Invalid HTML attributes');break end
        pos=b+1
        local _,eq=raw:find('^%s*=%s*',pos)
        local value=key
        if eq then
            pos=eq+1
            local q=raw:sub(pos,pos)
            if q=='"' or q=="'" then
                local finish=assert(raw:find(q,pos+1,true),'Unterminated HTML attribute')
                value=raw:sub(pos+1,finish-1);pos=finish+1
            else
                local finish=raw:find('%s',pos) or (#raw+1)
                value=raw:sub(pos,finish-1);pos=finish
            end
        end
        attrs[#attrs+1]=' '..key:lower()..'="'..value:gsub('"','&quot;'):gsub('<','&lt;')..'"'
    end
    return '<'..name..table.concat(attrs)..(void[name] and '/>' or '>')
end
function M.parse(s)
    assert(#s<=16*1024*1024,'HTML document is too large')
    local ok,tree=pcall(XML.parse,s)
    if ok then return tree end
    local original_error=tree
    -- Do not turn an interrupted download into an apparently complete book.
    assert(s:lower():find('</body%s*>') and s:lower():find('</html%s*>'),original_error)
    local out,stack={},{}
    local function emit(bytes) out[#out+1]=bytes end
    local function find(name)
        for i=#stack,1,-1 do if stack[i].name==name then return i end end
    end
    local function close(index)
        for i=#stack,index,-1 do emit('</'..stack[i].name..'>');stack[i]=nil end
    end
    local pos,count=1,0
    while pos<=#s do
        local a=s:find('<',pos,true)
        if not a then emit(s:sub(pos));break end
        emit(s:sub(pos,a-1))
        local b
        if s:sub(a,a+3)=='<!--' then
            b=assert(s:find('-->',a+4,true),'Unterminated HTML comment')+2;emit(s:sub(a,b))
        elseif s:sub(a,a+8)=='<![CDATA[' then
            b=assert(s:find(']]>',a+9,true),'Unterminated HTML CDATA')+2;emit(s:sub(a,b))
        else
            b=tagend(s,a+1)
            local raw=s:sub(a,b)
            local name=raw:match('^</([%w_:%.%-]+)%s*>$')
            if name then
                name=name:lower()
                local index=find(name)
                if index then
                    -- Keep formatting when inline end tags overlap.
                    local reopen={}
                    if inline[name] then
                        for i=index+1,#stack do
                            assert(inline[stack[i].name],'Invalid HTML inline nesting')
                            reopen[#reopen+1]=stack[i]
                        end
                    end
                    close(index)
                    for _,tag in ipairs(reopen) do
                        local start=tag.open:gsub('%s+id="[^"]*"','')
                        emit(start);stack[#stack+1]={name=tag.name,open=start}
                    end
                elseif not (void[name] or inline[name] or name=='p' or name=='li' or name=='dt' or name=='dd') then
                    error('Unexpected HTML closing tag: '..name)
                end
            elseif raw:match('^<!') or raw:match('^<%?') then emit(raw)
            else
                local attr
                name,attr=raw:match('^<([%w_:%.%-]+)(.-)>$')
                assert(name,'Invalid HTML tag');name=name:lower()
                if block[name] then local index=find('p');if index then close(index) end end
                if name=='li' or name=='dt' or name=='dd' or name=='tr' or name=='td' or name=='th' then
                    local index
                    local parent=(name=='li' and {ul=true,ol=true}) or ((name=='dt' or name=='dd') and {dl=true}) or {table=true,tbody=true,thead=true,tfoot=true,tr=true}
                    for i=#stack,1,-1 do
                        local previous=stack[i].name
                        if previous==name or ((name=='dd' or name=='dt') and (previous=='dt' or previous=='dd'))
                                or ((name=='td' or name=='th') and (previous=='td' or previous=='th')) then index=i;break end
                        if parent[previous] then break end
                    end
                    if index then close(index) end
                end
                local self_closing=attr:match('/%s*$')
                if self_closing then attr=attr:gsub('/%s*$','') end
                local start=opening(name,attr)
                if self_closing and not void[name] then start=start:gsub('>$','/>') end
                emit(start);count=count+1
                assert(count<=200000 and #stack<128,'HTML complexity limit exceeded')
                if not void[name] and not self_closing then stack[#stack+1]={name=name,open=start} end
            end
        end
        pos=b+1
    end
    assert(#stack==0,'Unclosed HTML document')
    return XML.parse(table.concat(out))
end
return M
