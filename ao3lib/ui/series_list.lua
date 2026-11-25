local _=require('gettext')
local Network=require('ao3lib.ao3.network')
local UI=require('ui/uimanager')
local M={}
function M.show(owner,user)
    if Network.defer(function() M.show(owner,user) end) then return end
    local View=require('ao3lib.ui.work_view')
    local function open(series)
        require('ao3lib.ui.subscriptions').openSeries(owner,series.id,series.title,series.work_count,series,{skip_overview=true})
    end
    local function html(series)
        if not series then return '<p>'.._('No series found.')..'</p>',{} end
        local rendered,actions,holds=View.seriesHTML(series,function()
            require('ao3lib.ui.work_bookmarks').show(owner,series,'series')
        end,{
            open=function() open(series) end,
            hold=function() require('ao3lib.ui.series_actions').show(owner,series) end,
            author=series.author_username and function() owner:showUserInfo(series.author_username,series.author_pseud) end or nil,
            tag=function(kind,name) require('ao3lib.ui.tag_actions').show(owner,kind,name) end,
        })
        local links={}
        for i,action in ipairs(actions) do links[i]={tap=action,hold=holds[i]} end
        return rendered:gsub('ao3%-action:', 'ao3-comment:'),links
    end
    return require('ao3lib.ui.comment_view').show(owner,{
        title=_('Series: ')..(user.pseud or user.username),network=Network.run,
        fetch=function(page)
            local result=require('ao3lib.ao3.client'):getUserSeries(user.username,user.pseud,page)
            if result.success and not result.next_page and not result.total_items then
                result.total_items=(page-1)*20+#(result.series or {})
            end
            return result
        end,
        error=function(result) UI:show(require('ui/widget/infomessage'):new{text=result.error or _('Could not load series.')}) end,
        prepare=function(result) return result.series or {} end,
        enrich=function(series)
            local result=require('ao3lib.ao3.client'):getWorksFromSeries(series.id,1)
            local details=result.success and result.works and result.works.series_info
            if details then for key,value in pairs(details) do if value~=nil then series[key]=value end end end
            series.words=series.words or series.word_count
            return result
        end,
        html=html,css=View.css,hide_actions=true,item_pages=true,items_per_batch=20,
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
