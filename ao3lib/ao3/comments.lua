-- AO3 comment pages are parsed into plain text; remote markup is never run.
local M={}
local function attr(node,key) return node and node.attributes and node.attributes[key] end
local function first(node,selector) return node:select(selector)[1] end
function M.path(work,chapter,parent)
    local kind,id='works',work
    if chapter then kind,id='chapters',chapter end
    if parent then kind,id='comments',parent end
    if not tostring(id):match('^%d+$') then return end
    return '/'..kind..'/'..id..'/comments'
end
function M.form(root,id,path)
    local form=first(root,'#comment_for_'..id)
    if not form or attr(form,'action')~=path then return end
    local token,pseud
    for _,input in ipairs(form:select('input')) do
        if attr(input,'name')=='authenticity_token' then token=attr(input,'value') end
        if attr(input,'name')=='comment[pseud_id]' then pseud=attr(input,'value') end
    end
    for _,select in ipairs(form:select('select')) do
        if attr(select,'name')=='comment[pseud_id]' then
            local options=select:select('option')
            for _,option in ipairs(options) do
                if attr(option,'selected')~=nil then pseud=attr(option,'value');break end
            end
            pseud=pseud or attr(options[1],'value')
        end
    end
    if type(token)~='string' or token=='' or not tostring(pseud):match('^%d+$') then return end
    return {token=token,pseud_id=pseud}
end
function M.list(root,decode,page,thread)
    if not first(root,'#main') then return end
    local scope=thread and root or first(root,'#comments_placeholder')
    if not scope or (thread and not first(root,'ol.thread')) then return end
    local items={}
    for _,node in ipairs(scope:select('li.comment')) do
        local id=(attr(node,'id') or ''):match('^comment_(%d+)$')
        if id then
            local byline=first(node,'h4.byline')
            local body=first(node,'blockquote.userstuff')
            local heading=byline and decode(byline:getcontent()) or ''
            local date=first(node,'.posted')
            local chapter=first(node,'.parent')
            local author,username,pseud
            for _,link in ipairs(byline and byline:select('a') or {}) do
                local user,name=(attr(link,'href') or ''):match('^/users/([^/]+)/pseuds/([^/?#]+)$')
                if user then
                    local function unquote(v) return (v:gsub('%%(%x%x)',function(h) return string.char(tonumber(h,16)) end)) end
                    username,pseud,author=unquote(user),unquote(name),decode(link:getcontent())
                    break
                end
            end
            -- Keep metadata out of the name, including for guests without a profile.
            local name_html=byline and byline:getcontent() or ''
            name_html=name_html:match('^(.-)<span[^>]-class=["\'][^"\']-parent')
                or name_html:match('^(.-)<span[^>]-class=["\'][^"\']-posted') or name_html
            author=author or decode(name_html):gsub('%s+',' '):match('^%s*(.-)%s*$')
            if author=='' then author=nil end
            local depth=0
            local ancestor=node.parent
            local seen={}
            while ancestor and not seen[ancestor] do
                seen[ancestor]=true
                if (attr(ancestor,'class') or ''):match('%f[%w]thread%f[%W]') then depth=depth+1 end
                ancestor=ancestor.parent
            end
            local unavailable=not body
            local text=body and decode(body:getcontent()) or decode(node:getcontent())
            items[#items+1]={id=id,heading=heading~='' and heading or 'Unavailable comment',
                text=text,author=author,username=username,pseud=pseud,date=date and decode(date:getcontent()) or '',
                chapter=chapter and decode(chapter:getcontent()) or '',depth=math.max(0,depth-1),
                can_reply=not unavailable and first(node,'#add_comment_reply_link_'..id)~=nil}
        else
            -- AO3 limits thread nesting and links to a deeper thread instead.
            for _,link in ipairs(node:select('a')) do
                local target=(attr(link,'href') or ''):match('^/comments/(%d+)$')
                if target then items[#items+1]={thread_id=target,heading=decode(link:getcontent())};break end
            end
        end
    end
    local next_page
    for _,link in ipairs(scope:select('a[rel="next"]')) do
        local n=tonumber((attr(link,'href') or ''):match('[?&]page=(%d+)'))
        if n and n>page then next_page=n;break end
    end
    local total_pages=page
    for _,link in ipairs(scope:select('ol.pagination a')) do
        local n=tonumber((attr(link,'href') or ''):match('[?&]page=(%d+)'))
        if n and n>total_pages then total_pages=n end
    end
    if next_page and total_pages<=page then total_pages=nil end
    return {success=true,comments=items,next_page=next_page,total_pages=total_pages}
end
return M
