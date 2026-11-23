-- Numbered navigation for the information-list view, sharing the formatted
-- view's sparse work cache and cancellation rules. Only the visible work's
-- 15 rows are built, even when AO3 reports thousands of results.
local _=require('gettext')
local M={}
function M.show(browser,context)
    local UI=require('ui/uimanager')
    local Base=require('ui/widget/keyvaluepage')
    local Window=Base:extend{}
    local state
    function Window:_populateItems()
        if self.items_per_page~=15 then
            if self.item_height then
                self.item_height=math.floor(self.item_height*self.items_per_page/15)
                self.items_font_size=math.min(require('ui/widget/textboxwidget'):getFontSizeToFitHeight(self.item_height,1,1),22)
            end
            self.items_per_page=15
        end
        self.show_page=state.index;self.pages=state:pageCount()
        Base._populateItems(self)
    end
    function Window:goToPage(page) state:goTo(page) end
    function Window:nextPage() state:next() end
    function Window:prevPage() state:previous() end
    function Window:reload() state:render() end
    function Window:onCloseWidget(...)
        self._ao3_closed=true;context.plugin.menu_stack[self]=nil
        if not self._replacing then state.closed=true;require('ao3lib.ao3.mute_cache').unwatch(state) end
        if Base.onCloseWidget then Base.onCloseWidget(self,...) else UI:setDirty(nil,'ui') end
    end
    context.rows=function(work) return browser:generateTable({}, {work},context.update,context.download) end
    context.network=require('ao3lib.ao3.network').run
    context.present=function(controller,html,actions,rows)
        local sparse={}
        for i,row in ipairs(rows) do sparse[(state.index-1)*15+i]=row end
        local previous=state.window
        local window
        window=Window:new{title=context.title or _('AO3 works'),kv_pairs=sparse,
            show_page=state.index,title_bar_left_icon='ao3',is_borderless=true,is_popout=false,
            value_overflow_align='center',
        }
        state.window=window;browser.browse_window=window
        require("ao3lib.ui.navigation").bind(context.plugin, window, {
            replace=previous or context.replacing, identity=context.identity, resume=function(resumed)
                if context.resume then context.resume(resumed) end
                state:resumeBackgroundRefresh()
            end,
        })
        context.replacing=nil
        UI:show(window)
        if previous then previous._replacing=true;UI:close(previous) end
    end
    state=require('ao3lib.ui.work_view').new(context)
    state:render()
    return state
end
return M
