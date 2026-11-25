-- AO3's work bookmark page contains short bookmark blurbs, not work blurbs.
local M={}
function M.parse(root,decode,page)
    if not root:select('#main')[1] then return nil end
    local entries={}
    for _,node in ipairs(root:select('li.user.short.blurb')) do
        local byline=node:select('h5.byline a')[1]
        local date=node:select('p.datetime')[1]
        local notes=node:select('blockquote.summary')[1] or node:select('blockquote.notes')[1]
        local entry={bookmarker=byline and decode(byline:getcontent()) or nil,
            date=date and decode(date:getcontent()) or nil,notes=notes and decode(notes:getcontent()) or nil,tags={},collections={},collection_ids={}}
        local href=byline and byline.attributes and byline.attributes.href or ''
        entry.username,entry.pseud=href:match('^/users/([%w_%-]+)/pseuds/([%w_%-]+)')
        for _,tag in ipairs(node:select('ul.tags a.tag')) do
            local name=decode(tag:getcontent());if name~='' then entry.tags[#entry.tags+1]=name end
        end
        for _,link in ipairs(node:select('ul.meta a')) do
            local target=link.attributes and link.attributes.href or ''
            local id=target:match('^/collections/([^/?#]+)')
            if id then
                local name=decode(link:getcontent())
                if name~='' then
                    entry.collections[#entry.collections+1]=name
                    entry.collection_ids[#entry.collections]=id
                end
            end
        end
        entry.status=node:select('p.status span.rec')[1] and 'rec'
            or node:select('p.status span.private')[1] and 'private'
            or node:select('p.status span.hidden')[1] and 'hidden' or nil
        entries[#entries+1]=entry
    end
    local next_page
    for _,selector in ipairs({'ol.pagination li.next a','a[rel="next"]'}) do
        for _,link in ipairs(root:select(selector)) do
            local href=link.attributes and link.attributes.href or ''
            local n=tonumber(href:match('[?&]page=(%d+)'))
            if n and n>page then next_page=n;break end
        end
        if next_page then break end
    end
    -- AO3's pagination includes a link to the last page. The current page
    -- itself may be plain text rather than a link, particularly on the last
    -- page, so include it in the maximum.
    local total_pages=page
    for _,link in ipairs(root:select('ol.pagination a')) do
        local href=link.attributes and link.attributes.href or ''
        local n=tonumber(href:match('[?&]page=(%d+)'))
        if n and n>total_pages then total_pages=n end
    end
    -- If the markup only exposes a next link, the actual last page is unknown.
    if next_page and total_pages<=page then total_pages=nil end
    return {success=true,bookmarks=entries,next_page=next_page,total_pages=total_pages}
end
return M
