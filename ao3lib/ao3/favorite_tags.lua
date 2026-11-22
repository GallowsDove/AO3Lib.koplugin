-- Parse AO3's account homepage and favorite-tag forms, independently of UI labels.
local M={}
local function attr(node,key) return node and node.attributes and node.attributes[key] end

function M.list(root,decode)
    if not root:select('#main')[1] or not root:select('body.logged-in')[1] then return nil end
    local favorites=root:select('div.favorite.module')[1]
    if not favorites then
        if root:select('div.browse.module')[1] then return {} end
        return nil
    end
    local out={}
    for _,link in ipairs(favorites:select('a')) do
        local href=attr(link,'href') or ''
        if href:match('^/tags/[^/]+/works') then
            local name=decode(link:getcontent())
            if name~='' then out[#out+1]={name=name} end
        end
    end
    if #out==0 then return nil end
    return out
end

function M.form(root,username)
    if not username or not username:match('^[%w_%-]+$') or not root:select('#main')[1] then return nil end
    local base='/users/'..username..'/favorite_tags'
    for _,form in ipairs(root:select('form')) do
        local action=attr(form,'action') or ''
        local id
        if action:sub(1,#base+1)==base..'/' then id=action:sub(#base+2):match('^(%d+)$') end
        if action==base or id then
            local tag_id,method
            for _,input in ipairs(form:select('input')) do
                if attr(input,'name')=='favorite_tag[tag_id]' then tag_id=attr(input,'value') end
                if attr(input,'name')=='_method' then method=(attr(input,'value') or ''):lower() end
            end
            if tostring(tag_id or ''):match('^%d+$') and (not id or method=='delete') then
                return {tag_id=tostring(tag_id),favorite_id=id,action=action}
            end
        end
    end
end
return M
