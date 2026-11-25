local _=require('gettext')
local Network=require('ao3lib.ao3.network')
local UI=require('ui/uimanager')
local M={}
local function escape(value)
    return tostring(value or ''):gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;'):gsub('"','&quot;'):gsub("'",'&#39;')
end
function M.html(collection,handlers)
    if not collection then return '<p>'..escape(_('No collections found.'))..'</p>',{} end
    handlers=handlers or {}
    local format=require('ao3lib.core.format').integer
    local extra={}
    if collection.subcollection_count~=nil then extra[#extra+1]=format(collection.subcollection_count)..' '.._('subcollections') end
    if collection.prompt_count~=nil then extra[#extra+1]=format(collection.prompt_count)..' '.._('prompts') end
    local info={id=collection.id,title=collection.title,author=collection.author,summary=collection.summary,
        tags=collection.tags,work_count=collection.work_count,bookmark_count=collection.bookmark_count,
        updated=collection.date_posted}
    local author=collection.authors and #collection.authors>0 and handlers.author or nil
    local html,actions,holds=require('ao3lib.ui.work_view').seriesHTML(info,handlers.bookmarks,{
        open=handlers.works,works=handlers.works,author=author,author_hold=handlers.author_hold,
        tag=handlers.tag and function(_,name) handlers.tag(name) end or nil,
        generic_tags=true,tag_label=_('Tags'),status=collection.type,extra_stats=extra,
    })
    local links={}
    for i,action in ipairs(actions) do links[i]={tap=action,hold=holds[i]} end
    return html:gsub('ao3%-action:', 'ao3-comment:'),links
end
function M.openBookmarks(owner,collection)
    Network.run(function()
        local success,works,next_page=owner:getBookmarksFromCollection(collection.id)
        if success then owner:onShowFanficBrowser(works,next_page,collection.title) end
    end)
end
function M.open(owner,id,title)
    local Nav=require('ao3lib.ui.navigation')
    local identity=Nav.key('collection',id)
    if Nav.isCurrent(owner,identity) then return end
    if Network.defer(function() M.open(owner,id,title) end) then return end
    local result=require('ao3lib.ao3.client'):getCollectionInfo(id)
    if not result.success then
        UI:show(require('ui/widget/infomessage'):new{text=result.error or _('Could not load collection.')})
        return
    end
    local success,works,next_page=owner:getWorksFromCollection(id)
    if not success or Nav.isCurrent(owner,identity) then return end
    local collection=result.collection
    collection.title=collection.title or title
    if collection.work_count~=nil then works.total=collection.work_count end
    owner:onShowFanficBrowser(works,next_page,collection.title,{identity=identity,collection_info=collection})
end
function M.chooseAuthor(owner,authors,hold)
    local function select(author)
        if hold then require('ao3lib.ui.user_actions').show(author,owner)
        else owner:showUserInfo(author.username,author.pseud) end
    end
    if #authors==1 then return select(authors[1]) end
    if #authors==0 then return end
    local dialog,buttons={},{}
    for _,author in ipairs(authors) do
        buttons[#buttons+1]={{text=author.name,callback=function() UI:close(dialog);select(author) end}}
    end
    buttons[#buttons+1]={{text=_('Cancel'),callback=function() UI:close(dialog) end}}
    dialog=require('ui/widget/buttondialog'):new{title=_('Choose author'),buttons=buttons}
    UI:show(dialog)
end
function M.show(owner,user)
    if Network.defer(function() M.show(owner,user) end) then return end
    local View=require('ao3lib.ui.work_view')
    local function open(collection,bookmarks)
        Network.run(function()
            local ok,works,next_page
            if bookmarks then ok,works,next_page=owner:getBookmarksFromCollection(collection.id)
            else ok,works,next_page=owner:getWorksFromCollection(collection.id) end
            if ok then owner:onShowFanficBrowser(works,next_page,collection.title) end
        end)
    end
    return require('ao3lib.ui.comment_view').show(owner,{
        title=_('Collections: ')..user.username,network=Network.run,
        fetch=function(page)
            local result=require('ao3lib.ao3.client'):getUserCollections(user.username,page)
            if result.success and not result.next_page and not result.total_items then result.total_items=(page-1)*20+#(result.collections or {}) end
            return result
        end,
        error=function(result) UI:show(require('ui/widget/infomessage'):new{text=result.error or _('Could not load collections.')}) end,
        prepare=function(result) return result.collections or {} end,
        html=function(collection)
            return M.html(collection,collection and {
                works=function() open(collection,false) end,
                bookmarks=function() open(collection,true) end,
                author=function() M.chooseAuthor(owner,collection.authors,false) end,
                author_hold=function() M.chooseAuthor(owner,collection.authors,true) end,
                tag=function(name) require('ao3lib.ui.tag_actions').show(owner,nil,name) end,
            } or nil)
        end,
        css=View.css,hide_actions=true,item_pages=true,items_per_batch=20,
        link_action=function(action) if action.tap then action.tap() end end,
        link_hold=function(action) if action.hold then action.hold() end end,
        page_label=function(state)
            if #state.comments==0 then return _('No items') end
            local index=(state.page-1)*20+state.index
            if state.total_items then return string.format(_('Page %d of %d'),index,state.total_items) end
            return string.format(_('Page %d'),index)
        end,
    })
end
return M
