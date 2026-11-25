local UI=require('ui/uimanager')
local Network=require('ao3lib.ao3.network')
local Client=require('ao3lib.ao3.client')
local _=require('gettext')
local M={}

local function escape(value)
    return tostring(value or ''):gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;'):gsub('"','&quot;'):gsub("'",'&#39;')
end
function M.html(page)
    local entries=page and page.entries or {}
    if #entries==0 then return '<p>'..escape(_('No visible bookmarks on this page.'))..'</p>',{} end
    local parts,links={},{}
    local function link(label,action)
        links[#links+1]=action
        return '<a href="ao3-comment:'..#links..'" style="color:#000000;text-decoration:none"><span style="color:#000000">'..escape(label)..'</span></a>'
    end
    for __,entry in ipairs(entries) do
        local header={}
        if entry.date and entry.date~='' then header[#header+1]=escape(entry.date) end
        local status={rec=_('Recommendation'),private=_('Private'),hidden=_('Hidden by AO3')}
        if status[entry.status] then header[#header+1]=escape(status[entry.status]) end
        local name=entry.bookmarker or _('Bookmark')
        name=entry.username and link(name,{kind='author',entry=entry}) or escape(name)
        local out={'<div class="bookmark"><h2>'..name..'</h2>'}
        if #header>0 then out[#out+1]='<p class="context">'..table.concat(header,' &#183; ')..'</p>' end
        for _,field in ipairs({{'tags',_('Tags')},{'collections',_('Collections')}}) do
            local values={};for i,value in ipairs(entry[field[1]] or {}) do
                local id=field[1]=='collections' and entry.collection_ids and entry.collection_ids[i]
                values[#values+1]=id and link(value,{kind='collection',id=id,name=value}) or escape(value)
            end
            if #values>0 then out[#out+1]='<p class="metadata"><b>'..escape(field[2])..'</b> '..table.concat(values,' &#183; ')..'</p>' end
        end
        if entry.notes and entry.notes~='' then
            local notes=escape(entry.notes):gsub('\r\n','\n'):gsub('\n\n+','</p><p>'):gsub('\n','<br/>')
            out[#out+1]='<div class="notes"><p>'..notes..'</p></div>'
        end
        out[#out+1]='</div>';parts[#parts+1]=table.concat(out)
    end
    return table.concat(parts),links
end
M.css=[[
@page { margin: 0; }
body { margin: 0; color: #000; background: #fff; line-height: 1.3; }
a, a:link, a:visited, a:active { color: #000; text-decoration: none; }
h2 { font-size: 1em; margin: 0 0 .12em; font-weight: bold; }
p { margin: .2em 0; }
.bookmark { padding: 0 0 .5em; margin: 0 0 .6em; border-bottom: 1px solid #888; }
.context { font-size: .8em; }
.metadata { font-size: .85em; }
.notes { font-size: .9em; margin-top: .3em; }
]]
function M.show(owner,work,kind)
    if Network.defer(function() M.show(owner,work,kind) end) then return end
    return require('ao3lib.ui.comment_view').show(owner,{
        title=_('Bookmarks: ')..(work.title or tostring(work.id)),
        network=Network.run,
        fetch=function(page)
            if kind=='series' then return Client:getSeriesBookmarks(work.id,page) end
            return Client:getWorkBookmarks(work.id,page)
        end,
        error=function(result) UI:show(require('ui/widget/infomessage'):new{text=result.error or _('Could not load bookmarks.')}) end,
        prepare=function(result) return {{entries=result.bookmarks or {}}} end,
        html=M.html,css=M.css,hide_actions=true,
        link_action=Network.wrap(function(action)
            if action.kind=='author' then
                owner:showUserInfo(action.entry.username,action.entry.pseud)
            elseif action.kind=='collection' then
                require('ao3lib.ui.collection_list').open(owner,action.id,action.name)
            end
        end),
        page_label=function(state)
            if state.total_pages then return string.format(_('Page %d of %d'),state.page,state.total_pages) end
            return string.format(_('Page %d'),state.page)
        end,
    })
end
return M
