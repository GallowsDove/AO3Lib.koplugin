-- Parse AO3's subscription forms rather than translated button labels.
local M={}
local function attr(node,key) return node and node.attributes and node.attributes[key] end
function M.target(kind,value)
    if kind=='User' and type(value)=='string' and value:match('^[%w_%-]+$') then return '/users/'..value end
    if (kind=='Work' or kind=='Series') and tostring(value):match('^%d+$') then
        return (kind=='Work' and '/works/' or '/series/')..value
    end
end
function M.form(root,kind)
    for _,form in ipairs(root:select('form')) do
        local form_kind,target_id
        for _,input in ipairs(form:select('input')) do
            if attr(input,'name')=='subscription[subscribable_type]' then form_kind=attr(input,'value') end
            if attr(input,'name')=='subscription[subscribable_id]' then target_id=attr(input,'value') end
        end
        if form_kind==kind and tostring(target_id or ''):match('^%d+$') then
            local action=attr(form,'action') or ''
            local sub=action:match('/subscriptions/(%d+)$')
            if action:match('^/users/[^/]+/subscriptions') then
                return {kind=kind,target_id=target_id,subscription_id=sub}
            end
        end
    end
end
function M.list(root,decode,page)
    local list=root:select('dl.subscription')[1]
    if not root:select('#main')[1] or not list then return nil end
    local titles,details=list:select('dt'),list:select('dd')
    if #titles~=#details then return nil end
    local items={}
    for i,dt in ipairs(titles) do
        local form=details[i]:select('form')[1]
        local id=(attr(form,'action') or ''):match('^/users/[^/]+/subscriptions/(%d+)$')
        if not id then return nil end
        local item={subscription_id=id,title=decode(dt:getcontent()),kind='Unavailable'}
        for _,link in ipairs(dt:select('a')) do
            local href=attr(link,'href') or ''
            local work,series,user=href:match('^/works/(%d+)$'),href:match('^/series/(%d+)$'),href:match('^/users/([^/]+)$')
            if work or series or user then
                item.kind=work and 'Work' or series and 'Series' or 'User'
                item.target=work or series or user
                item.title=decode(link:getcontent())
                break
            end
        end
        items[#items+1]=item
    end
    local next_page
    for _,a in ipairs(root:select('a[rel="next"]')) do
        local n=tonumber((attr(a,'href') or ''):match('[?&]page=(%d+)'))
        if n and n>page then next_page=n;break end
    end
    return {success=true,subscriptions=items,next_page=next_page}
end
return M
