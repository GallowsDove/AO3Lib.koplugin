local _=require('gettext')
local M={}
local function escape(value)
    return tostring(value or ''):gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;'):gsub('"','&quot;'):gsub("'",'&#39;')
end
local function formatDate(value)
    value=tostring(value or ''):gsub('%s+',' '):match('^%s*(.-)%s*$')
    local day,month,year,hour,minute,period,zone=value:match('^%a+ (%d+) (%a+) (%d+) (%d+):(%d+)([AP]M)%s*(.*)$')
    if day then
        hour=tonumber(hour)%12+(period=='PM' and 12 or 0)
        return string.format('%d %s %s · %02d:%s%s',tonumber(day),month,year,hour,minute,zone~='' and ' '..zone or '')
    end
    return value
end
local function threads(comments)
    local result={}
    for _,comment in ipairs(comments) do
        if #result==0 or (comment.id and (comment.depth or 0)==0) then
            local root={}
            for k,v in pairs(comment) do root[k]=v end
            root.entries={};result[#result+1]=root
        end
        local entries=result[#result].entries
        entries[#entries+1]=comment
    end
    return result
end
function M.html(thread)
    if not thread then return '<p>'..escape(_("No comments on this page."))..'</p>',{} end
    local parts,links={},{}
    local function link(kind,comment,label)
        links[#links+1]={kind=kind,comment=comment}
        return '<a href="ao3-comment:'..#links..'" style="color:#000000;text-decoration:none"><span style="color:#000000">'..escape(label)..'</span></a>'
    end
    for entry_index,comment in ipairs(thread.entries or {thread}) do
        local name=comment.author or comment.heading
        if comment.username then name=link('author',comment,name) else name=escape(name) end
        local body=escape(comment.text or _("Open this thread to continue reading."))
            :gsub('\r\n','\n'):gsub('\n\n+','</p><p>'):gsub('\n','<br/>')
        parts[#parts+1]='<div class="comment" style="margin-left:'..(math.min(comment.depth or 0,3)*0.7)..'em">'
            ..'<h2>'..name..'</h2><p class="context">'..escape(formatDate(comment.date))
            ..(comment.chapter and comment.chapter~='' and ' · '..escape(comment.chapter) or '')..'</p><p>'..body..'</p>'
            ..(comment.can_reply and '<p class="context">'..link('reply',comment,_("Reply"))..'</p>' or '')
            ..(comment.thread_id and '<p>'..link('thread',comment,comment.heading)..'</p>' or '')..'</div>'
    end
    return table.concat(parts),links
end
M.css=[[
@page { margin: 0; }
body { margin: 0; color: #000; background: #fff; line-height: 1.35; }
a, a:link, a:visited, a:active { color: #000; text-decoration: none; }
h2 { font-size: 1em; margin: 0 0 .2em; font-weight: bold; }
p { margin: 0 0 .65em; }
.comment { margin-bottom: 1em; border-bottom: 1px solid #888; }
.context { font-size: .8em; margin: 0 0 .6em; }
]]
-- AO3 pages are fetched lazily. Each displayed page contains one thread;
-- moving within a fetched batch or back to an earlier batch needs no request.
function M.new(context)
    local state={page=1,index=1,chapter=context.chapter_id,comments={},cache={},closed=false,loading=false}
    function state:current() return self.comments[self.index] end
    function state:hasPrevious() return self.index>1 or self.page>1 end
    function state:hasNext() return self.index<#self.comments or self.next_page~=nil end
    function state:render()
        if self.closed then return end
        local item=self:current()
        if context.enrich and item and not item._ao3_enriched then
            if self.enriching then return end
            self.enriching=true
            context.network(function()
                if self.closed then self.enriching=false;return end
                local ok,result=pcall(context.enrich,item)
                self.enriching=false
                if not ok then error(result,0) end
                item._ao3_enriched=true
                if result and not result.success then context.error(result) end
                if not self.closed then self:render() end
            end)
            return
        end
        context.present(self,(context.html or M.html)(item))
    end
    function state:enter(page,chapter,result,index)
        if chapter~=self.chapter then self.cache={} end
        self.page,self.chapter,self.comments,self.next_page=page,chapter,
            context.prepare and context.prepare(result) or threads(result.comments),result.next_page
        self.total_pages=result.total_pages
        self.total_items=result.total_items or self.total_items
        self.cache[page]=result
        self.index=math.max(1,math.min(index or 1,math.max(1,#self.comments)))
        self:render()
    end
    function state:load(page,chapter,index,preserve)
        if self.closed or self.loading then return end
        local id=preserve and self:current() and self:current().id
        context.network(function()
            if self.closed or self.loading then return end
            self.loading=true
            local ok,result=pcall(context.fetch,page,chapter)
            self.loading=false
            if not ok then error(result,0) end
            if self.closed then return end
            if not result.success then context.error(result);return end
            if id then
                for i,c in ipairs(threads(result.comments)) do if c.id==id then index=i;break end end
            end
            self:enter(page,chapter,result,index)
        end)
    end
    function state:next()
        if self.closed or self.loading then return end
        if self.index<#self.comments then self.index=self.index+1;self:render()
        elseif self.next_page then
            local page=self.next_page
            if self.cache[page] then self:enter(page,self.chapter,self.cache[page],1)
            else self:load(page,self.chapter,1) end
        end
    end
    function state:previous()
        if self.closed or self.loading then return end
        if self.index>1 then self.index=self.index-1;self:render()
        elseif self.page>1 then
            local page=self.page-1
            if self.cache[page] then self:enter(page,self.chapter,self.cache[page],math.huge)
            else self:load(page,self.chapter,math.huge) end
        end
    end
    function state:goToPage(page)
        if self.closed or self.loading or not page or page%1~=0 or page<1
                or (self.total_pages and page>self.total_pages) then return end
        if self.cache[page] then self:enter(page,self.chapter,self.cache[page],1)
        else self:load(page,self.chapter,1) end
    end
    function state:goToItem(index)
        if self.closed or self.loading or type(index)~='number' or index%1~=0 or index<1
                or (self.total_items and index>self.total_items) then return end
        local size=context.items_per_batch or 20
        local page=math.floor((index-1)/size)+1
        local within=(index-1)%size+1
        if self.cache[page] then self:enter(page,self.chapter,self.cache[page],within)
        else self:load(page,self.chapter,within) end
    end
    function state:refresh() self:load(self.page,self.chapter,self.index,true) end
    return state
end
function M.show(owner,context)
    local UI=require('ui/uimanager')
    local Device=require('device')
    local Screen=Device.screen
    local Button=require('ui/widget/button')
    local Title=require('ui/widget/titlebar')
    local Horizontal=require('ui/widget/horizontalgroup')
    local Vertical=require('ui/widget/verticalgroup')
    local Center=require('ui/widget/container/centercontainer')
    local Frame=require('ui/widget/container/framecontainer')
    local Geom=require('ui/geometry')
    local Scroll=require('ui/widget/scrollhtmlwidget')
    local Window=require('ui/widget/focusmanager'):extend{covers_fullscreen=true,is_always_active=true}
    local width,height=Screen:getWidth(),Screen:getHeight()
    local padding=Screen:scaleBySize(12)
    local content_width=math.max(1,width-2*padding)
    local state
    function Window:onClose() UI:close(self);return true end
    function Window:onCloseWidget()
        self._ao3_closed=true
        if not self._replacing then state.closed=true end
        UI:setDirty(nil,'ui')
    end
    function Window:onShow() UI:setDirty(self,'ui');return true end
    -- Fullscreen readers sit above the work view, which remains active for
    -- navigation. Consume otherwise unhandled taps and holds so they cannot
    -- activate the work underneath; child controls receive gestures first.
    function Window:onConsumeReaderTouch() return true end
    function Window:onNextComment()
        if not self._ao3_closed and (context.item_pages or not self.scroll:onScrollDown()) then state:next() end
        return true
    end
    function Window:onPreviousComment()
        if not self._ao3_closed and (context.item_pages or not self.scroll:onScrollUp()) then state:previous() end
        return true
    end
    function Window:onSwipeReader(_,gesture)
        local direction=require('ui/bidi').flipDirectionIfMirroredUILayout(gesture.direction)
        if direction=='west' then
            if not self._ao3_closed then state:next() end
            return true
        elseif direction=='east' then
            if not self._ao3_closed then state:previous() end
            return true
        end
        return false
    end
    function Window:init()
        self.key_events={Close={{'Back'}}}
        local GestureRange=require('ui/gesturerange')
        local screen=Geom:new{x=0,y=0,w=width,h=height}
        self.ges_events={ConsumeReaderTouch={
            GestureRange:new{ges='tap',range=screen},
            GestureRange:new{ges='hold',range=screen},
            GestureRange:new{ges='hold_release',range=screen},
        },SwipeReader={GestureRange:new{ges='swipe',range=screen}}}
        if Device:hasKeys() then
            self.key_events.NextComment={{Device.input.group.PgFwd}}
            self.key_events.PreviousComment={{Device.input.group.PgBack}}
        end
        self.titlebar=Title:new{width=width,title=context.title,left_icon='ao3',
            left_icon_tap_callback=function() require('ao3lib.ui.navigation').menu(self) end,
            close_callback=function() self:onClose() end}
        local comment=state:current()
        local third=math.max(1,math.floor(content_width/3))
        self.action_buttons={
            {text=_("Write comment"),width=third,callback=function() context.compose(state) end},
            {text=_("Reply"),width=third,enabled=comment and comment.can_reply or false,
                callback=function() if comment and comment.can_reply then context.compose(state,comment) end end},
            {text=_("More…"),width=math.max(1,content_width-2*third),callback=function() context.more(state) end},
        }
        local actions=Horizontal:new{}
        for i,options in ipairs(self.action_buttons) do
            options.bordersize=0;options.show_parent=self
            self.action_buttons[i]=Button:new(options);actions[#actions+1]=self.action_buttons[i]
        end
        local pager
        local total=context.item_pages and state.total_items or state.total_pages
        local goto_page=context.item_pages and function(page) state:goToItem(page) end or function(page) state:goToPage(page) end
        local current=context.item_pages and ((state.page-1)*(context.items_per_batch or 20)+state.index) or state.page
        pager,self.page_buttons=require('ao3lib.ui.rendered_pager').new(self,{
            width=width,total=total,
            label=context.page_label and context.page_label(state) or string.format(_("Thread %d/%d · Page %d"),#state.comments>0 and state.index or 0,#state.comments,state.page),
            has_previous=state:hasPrevious(),has_next=state:hasNext(),
            has_last=total and current<total or false,
            first=function() goto_page(1) end,previous=function() state:previous() end,
            next=function() state:next() end,last=function() goto_page(total) end,
            go_to=goto_page,
        })
        local action_height=context.hide_actions and 0 or actions:getSize().h
        self.scroll=Scroll:new{width=content_width,
            height=math.max(1,height-self.titlebar:getHeight()-action_height-pager:getSize().h-2*padding),
            html_body=self.html,css=context.css or M.css,default_font_size=Screen:scaleBySize(require('ao3lib.ui.work_view').baseTextSize()),dialog=self,
            html_link_tapped_callback=function(link)
                local id=tonumber((link.uri or ''):match('^ao3%-comment:(%d+)$'))
                local action=id and self.links[id]
                if not action then return end
                if context.link_action then context.link_action(action,state)
                elseif action.kind=='reply' then context.compose(state,action.comment)
                elseif action.kind=='author' then context.author(action.comment)
                elseif action.kind=='thread' then context.thread(action.comment,state) end
            end}
        if context.link_hold then
            require('ao3lib.ui.work_view').bindTitleHold(self.scroll,function(id)
                local action=self.links[id]
                if action then context.link_hold(action,state);return true end
            end,'ao3%-comment')
        end
        -- Hardware page turns scroll a long thread before advancing to the
        -- next one. Touch arrows always move directly between threads.
        if self.scroll.key_events then self.scroll.key_events.ScrollDown=nil;self.scroll.key_events.ScrollUp=nil end
        local content=Vertical:new{self.titlebar}
        if not context.hide_actions then content[#content+1]=Center:new{dimen=Geom:new{w=width,h=action_height},actions} end
        content[#content+1]=Frame:new{padding=padding,margin=0,bordersize=0,self.scroll}
        content[#content+1]=Center:new{dimen=Geom:new{w=width,h=pager:getSize().h},pager}
        self[1]=Frame:new{padding=0,margin=0,bordersize=0,background=require('ffi/blitbuffer').COLOR_WHITE,
            dimen=Geom:new{w=width,h=height},content}
        self.layout=context.hide_actions and {self.page_buttons} or {self.action_buttons,self.page_buttons}
    end
    context.present=function(controller,html,links)
        local previous=controller.window
        local window=Window:new{html=html,links=links}
        controller.window=window
        require('ao3lib.ui.navigation').bind(owner,window,{replace=previous})
        UI:show(window)
        if previous then previous._replacing=true;UI:close(previous) end
    end
    state=M.new(context)
    state:load(1,context.chapter_id)
    return state
end
return M
