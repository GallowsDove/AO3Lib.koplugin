-- Parse the account's muted-user list; keep account names, not display pseuds.
local M={}
function M.page(root, username)
    if not root:select('#main')[1] or root:select('body.logged-out')[1] then return nil end
    local base='/users/'..username..'/muted/users'
    local form_ok=false
    for _,form in ipairs(root:select('form')) do
        if (form.attributes.action or ''):find(base..'/confirm_mute',1,true) then form_ok=true end
    end
    if not form_ok then return nil end
    local entries={}
    for _,item in ipairs(root:select('li.user.pseud.blurb')) do
        local name,id
        for _,link in ipairs(item:select('a')) do
            local href=link.attributes.href or ''
            name=name or href:match('^/users/([%w_%-]+)/pseuds/') or href:match('^/users/([%w_%-]+)$')
            id=id or href:match('/muted/users/(%d+)/confirm_unmute')
        end
        if not name or not id then return nil end
        entries[#entries+1]={name=name,id=id}
    end
    local next_page
    for _,link in ipairs(root:select('ol.pagination a')) do
        local href=link.attributes.href or ''
        if (link.attributes.rel or '')=='next' or (link:getcontent() or ''):lower():find('next',1,true) then
            next_page=tonumber(href:match('[?&]page=(%d+)'))
        end
    end
    return entries,next_page
end
function M.confirm(root,base,delete)
    for _,form in ipairs(root:select('form')) do
        local action=form.attributes.action or ''
        local path=action:match('^([^?]+)')
        if (not delete and path==base and action:find('muted_id=',1,true)) or
            (delete and path:match('^'..base..'/%d+$')) then
            local method
            for _,input in ipairs(form:select('input')) do
                if input.attributes.name=='_method' then method=(input.attributes.value or ''):lower() end
            end
            if (delete and method=='delete') or (not delete and not method) then return action end
        end
    end
end
return M
