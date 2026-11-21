local M={}
function M.isReveal(link)
    local href=link.attributes and link.attributes.href or ''
    return href:find('/tags/show_hidden',1,true)~=nil
end
-- Decode the string argument of AO3's replacement response. Never evaluate JS.
function M.fragment(body,id,kind)
    local prefix='^%s*%$j%(%s*"#work_'..id..'_category_'..kind..'"%s*%)%.replaceWith%(%s*"'
    local _,start=body:find(prefix)
    if not start then return end
    local out={}
    local i=start+1
    local escapes={n='\n',r='\r',t='\t',['\\']='\\',['"']='"',["'"]="'",['/']='/',['`']='`',['$']='$'}
    while i<=#body do
        local c=body:sub(i,i)
        if c=='"' then
            if not body:sub(i+1):match('^%s*%)%s*;%s*$') then return end
            return table.concat(out)
        elseif c=='\\' then
            local e=body:sub(i+1,i+1)
            if not escapes[e] then return end
            out[#out+1]=escapes[e];i=i+2
        else out[#out+1]=c;i=i+1 end
    end
end
return M
