-- Formatted work browser. Uses KOReader widgets and local AO3 symbols only;
-- Bookshelf need not be installed, and remote markup is never executed.
local _=require('gettext')
local M={}
-- HtmlBoxWidget exposes link hit-testing but has no held-link callback.
-- Bind only this widget instance, using its current page and coordinates.
function M.bindTitleHold(scroll,callback)
    local box=scroll.htmlbox_widget
    if not box then return end
    box.ges_events=require('ao3lib.core.table').shallowCopy(box.ges_events)
    box.ges_events.HoldAO3Title={require('ui/gesturerange'):new{
        ges='hold',range=function() return box.dimen end,
    }}
    box.onHoldAO3Title=function(self,_,ges)
        local pos=self:getPosFromAbsPos(ges.pos)
        local link=pos and self:getLinkByPosition(pos)
        local id=link and tonumber((link.uri or ''):match('^ao3%-action:(%d+)$'))
        if id then return callback(id) or false end
        return false
    end
end

function M.baseTextSize()
    local size=tonumber(require('ao3lib.core.config'):readSetting('work_view_font_size',20)) or 20
    if size~=size then size=18 end
    return math.max(12,math.min(32,math.floor(size)))
end
local function escape(value)
    return tostring(value or ''):gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;'):gsub('"','&quot;'):gsub("'",'&#39;')
end
local function text(value)
    if type(value)=='table' then return table.concat(value,', ') end
    return tostring(value or '')
end
local function paragraphs(value)
    local html=escape(text(value)):gsub('\r\n','\n'):gsub('\n\n+','</p><p>'):gsub('\n','<br/>')
    return '<p>'..html..'</p>'
end

function M.html(work,rows,options)
    if work.is_deleted or work.is_unavailable then
        return '<h2>'..escape(work.is_unavailable and _('Unavailable work') or _('Deleted work'))..'</h2>',{}
    end
    local actions,holds={},{}
    local function link(label,callback,hold)
        if not callback then return escape(label) end
        actions[#actions+1]=callback
        holds[#actions]=hold
        return '<a href="ao3-action:'..#actions..'" style="color:#000000;text-decoration:none"><span style="color:#000000">'..escape(label)..'</span></a>'
    end
    local function tagLink(kind,name)
        local callback=options and options.tag_action and function() options.tag_action(kind,name) end
        local star=options and options.is_favorite and options.is_favorite(name)
            and '<span style="color:#000000">&#9733;</span> ' or ''
        return star..link(name,callback)
    end
    local function tagList(value,kind,split)
        if type(value)=='string' then
            local items={}
            if split then for item in value:gmatch('[^,]+') do items[#items+1]=item:match('^%s*(.-)%s*$') end
            else items[1]=value end
            value=items
        end
        local result={}
        for __,name in ipairs(type(value)=='table' and value or {}) do
            if type(name)=='string' and name~='' and name~='N/A' then result[#result+1]=tagLink(kind,name) end
        end
        return table.concat(result,' &#183; ')
    end
    local author,series,warning_row,tag_row
    for __,row in ipairs(rows) do
        local label=row[1]:match('^%s*(.-):$')
        if label=='Author' then author=row end
        if label=='Warnings' then warning_row=row end
        if label=='Other Tags' then tag_row=row end
        if label==_('Series:'):sub(1,-2) then series=row end
    end
    local data=require('ao3lib.bookshelf.metadata').fromWork(work)
    local Badges=require('ao3lib.bookshelf.badges')
    local symbols=Badges.symbols(data)
    local cells={}
    for i=1,4 do
        cells[i]=symbols[i] and '<img src="'..Badges.relativePath(symbols[i])..'"/>' or '&#160;'
    end
    local badge='<table class="badges"><tr><td>'..cells[1]..'</td><td>'..cells[2]..'</td></tr><tr><td>'..cells[3]..'</td><td>'..cells[4]..'</td></tr></table>'
    local out={'<table class="heading" width="100%"><tr><td class="square">'..badge..'</td><td><h1>'..link(rows[1][1],rows[1].callback,rows[1].hold_callback)..'</h1>',
        '<p class="author">'..escape(_('by'))..' '..link(author and author[2] or work.author or _('Anonymous'),author and author.callback,author and author.hold_callback)..'</p>'}
    local fandoms=tagList(work.fandoms,'Fandom',true)
    if fandoms~='' then out[#out+1]='<p class="fandom">'..fandoms..'</p>' end
    out[#out+1]='</td></tr></table>'
    if type(work.series)=='table' and #work.series>0 and series then
        out[#out+1]='<p class="series">'..link(series[2],series.callback,series.hold_callback)..'</p>'
    end
    local completion=data.ao3_completion[1]
    local status=work.iswip or (completion=='complete' and _('Complete')
        or completion=='in_progress' and _('Work in progress') or _('Unknown work status'))
    out[#out+1]='<p class="work-facts"><b>'..escape(require('ao3lib.core.format').integer(work.words or work.wordcount or '?'))..'</b> '..escape(_('words'))
        ..' &#183; <b>'..escape(work.chapters or '?/?')..'</b> '..escape(_('chapters'))
        ..' &#183; '..escape(work.language or _('Unknown language'))..'</p>'
    local advisory={'<span class="status">'..escape(status)..'</span>'}
    for __,field in ipairs({'rating','category','warnings'}) do
        local value=text(work[field])
        if field=='warnings' and work.warnings_hidden then
            advisory[#advisory+1]=link(_('Show warnings'),warning_row and warning_row.callback)
        elseif value~='' and value~='N/A' then
            local kind=field=='rating' and 'Rating' or field=='category' and 'Category' or 'Warning'
            advisory[#advisory+1]=tagList(work[field],kind,field=='category')
        end
    end
    if #advisory>0 then out[#out+1]='<p class="advisory">'..table.concat(advisory,' &#183; ')..'</p>' end
    local summary=text(work.summary)
    if options and options.summary_html then
        -- EPUB descriptions contain HTML; online summaries are already plain
        -- text. Match the online paragraph layout without executing markup.
        summary=summary:gsub('<!%-%-.-%-%->',''):gsub('<[bB][rR]%s*/?>','\n')
            :gsub('</[pP]%s*>','\n\n'):gsub('<[^>]*>',''):match('^%s*(.-)%s*$')
    end
    local summary_body=paragraphs(summary)
    if options and options.summary_html then
        -- Preserve encoded characters after stripping tags and escaping text.
        summary_body=summary_body:gsub('&amp;([#%w]+);',function(entity)
            if ({amp=true,lt=true,gt=true,quot=true,apos=true,nbsp=true})[entity]
                or entity:match('^#%d+$') or entity:match('^#[xX]%x+$') then return '&'..entity..';' end
            return '&amp;'..entity..';'
        end)
    end
    out[#out+1]='<div class="summary">'..summary_body..'</div>'
    local function tags(field,label,class)
        if field=='tags' and work.tags_hidden then
            out[#out+1]='<div class="tag-group '..class..'"><p><span class="tag-heading">'..escape(label)..'</span> '
                ..link(_('Show additional tags'),tag_row and tag_row.callback)..'</p></div>'
            return
        end
        local value=field=='tags' and work.tag_names or work[field]
        local values={}
        if type(value)=='table' then values=value
        elseif type(value)=='string' then
            for item in value:gmatch('[^,]+') do values[#values+1]=item:match('^%s*(.-)%s*$') end
        end
        local chips={}
        for __,item in ipairs(values) do
            item=tostring(item):gsub('%s+',' '):match('^%s*(.-)%s*$')
            if item~='' and item~='N/A' then
                local kind=field=='relationships' and 'Relationship' or field=='characters' and 'Character' or 'Freeform'
                chips[#chips+1]='<span class="chip">'..tagLink(kind,item)..'</span>'
            end
        end
        if #chips>0 then
            out[#out+1]='<div class="tag-group '..class..'"><p><span class="tag-heading">'..escape(label)..'</span> '..table.concat(chips,'&#160;&#183; ')..'</p></div>'
        end
    end
    tags('relationships',_('Relationships'),'relationships')
    tags('characters',_('Characters'),'characters')
    tags('tags',_('Additional tags'),'additional')
    local stats={}
    for __,field in ipairs({{'hits',_('Hits')},{'kudos',_('Kudos')},{'bookmarks',_('Bookmarks')},{'comments',_('Comments')}}) do
        local value=work[field[1]]
        if value~=nil and tostring(value)~='' then
            stats[#stats+1]='<b>'..escape(require('ao3lib.core.format').integer(value))..'</b> '..escape(field[2])
        end
    end
    local date=work.date or work.updated or work.published
    if #stats>0 or date then
        out[#out+1]='<div class="footnote">'..(#stats>0 and '<p>'..table.concat(stats,' &#183; ')..'</p>' or '')
            ..(date and '<p class="date">'..escape(date)..'</p>' or '')..'</div>'
    end
    return table.concat(out,'\n'),actions,holds
end

-- Conservative HTML/CSS supported by KOReader's MuPDF renderer: tables for
-- alignment, relative sizes for device scaling, no browser-only layout rules.
M.css=[[
@page { margin: 0; }
body { margin: 0; line-height: 1.22; color: #000; background-color: #fff; }
a, a:link, a:visited, a:active { color: #000; text-decoration: none; }
p { margin: .25em 0; }
h1 { font-size: 1.25em; font-weight: bold; line-height: 1.1; margin: 0 0 .12em; }
h1, h1 a, h1 a:link, h1 a:visited, h1 a:active { color: #000; }
.tag-group .tag-heading { font-size: .72em; font-weight: bold; color: #000; }
table.heading { width: 100%; border-spacing: 0; margin: 0 0 .3em; }
table.heading td { vertical-align: top; padding: 0; }
table.heading td.square { width: 4em; padding-right: .5em; }
table.badges { border-spacing: .1em; width: 3.6em; }
table.badges td { width: 1.7em; height: 1.7em; }
table.badges img { width: 1.7em; height: 1.7em; }
.author { font-size: .95em; font-style: normal; margin: 0; }
.fandom { font-size: .82em; color: #111; margin: .2em 0 0; }
.series { font-size: .9em; font-style: normal; margin: .25em 0; }
.work-facts { font-size: .85em; margin: .35em 0 .2em; }
.advisory { font-size: .74em; color: #111; margin: .2em 0; }
.status { font-weight: bold; color: #000; }
.summary { margin: .55em 0; }
.summary p { margin: .4em 0; }
.tag-group { margin: .3em 0; }
.tag-group p { font-size: .85em; line-height: 1.4; }
.chip { background-color: #fff; padding: .03em .15em; }
.relationships .chip { font-style: normal; }
.footnote { border-top: 1px solid #777; margin-top: 1.1em; padding-top: .4em; font-size: .72em; color: #111; }
.footnote b { color: #000; }
.date { font-style: normal; }
.hidden-work h1 { margin-bottom: .4em; }
.hidden-work .hidden-label { font-size: .85em; font-weight: bold; margin: .5em 0 .2em; }
.hidden-work .hidden-tag { margin: .2em 0; }
.hidden-work .hidden-action { border-top: 1px solid #777; margin-top: .8em; padding-top: .5em; }
.hidden-work .hidden-action a { font-weight: bold; }
]]

-- Controller kept separate from rendering so paging/connection lifecycle can
-- be tested without a device or a MuPDF renderer.
function M.new(context)
    local pager=require('ao3lib.ao3.work_paging').get(context.fetch)
    local self={context=context,works={},index=context.index or 1,closed=false,pager=pager,revealed={}}
    for i,work in ipairs(context.works) do self.works[i]=work end
    self.total=tonumber(context.works.total)
    if self.total and self.total<#self.works then self.total=nil end
    if pager then
        pager:setTotal(self.total)
        for i,work in ipairs(self.works) do pager.works[i]=work end
        while pager.works[pager.loaded+1] do pager.loaded=pager.loaded+1 end
        self.works=pager.works
    end
    if context.mutes then
        local cache=require('ao3lib.ao3.mute_cache')
        cache.watch(self,function(owner)
            if not owner.closed and owner.window and not owner.window._ao3_closed then owner:render() end
        end)
        cache.ensure()
    end
    function self:pageCount() return (self.pager and (self.pager.total or self.pager.loaded)) or self.total or #self.works end
    self.index=math.max(1,math.min(self.index,math.max(1,self:pageCount())))
    function self:render()
        if self.closed then return end
        local work=self.works[self.index]
        local match=require('ao3lib.ui.hidden_work').reasons(work,{
            blacklist=context.blacklist,mutes=context.mutes,
            revealed=work and self.revealed[work.id or self.index],
        })
        local rows=work and not match and context.rows(work) or {}
        local html,actions,holds
        if match then
            local function reveal() self.revealed[work.id or self.index]=true;self:render() end
            local label=_('Hidden because of:')
            local names=table.concat(match,', ')
            rows={{_('Hidden work'),label..' '..names,callback=reveal},
                {_('Show work'),'',callback=reveal}}
            local entries={};for _,name in ipairs(match) do
                entries[#entries+1]='<p class="hidden-tag">'..escape(name)..'</p>'
            end
            html='<div class="hidden-work"><h1>'..escape(_('Hidden work'))..'</h1>'
                ..'<p class="hidden-label">'..escape(label)..'</p>'..table.concat(entries)
                ..'<p class="hidden-action"><a href="ao3-action:1" style="color:#000000;text-decoration:none"><span style="color:#000000">'..escape(_('Show work'))..'</span></a></p></div>'
            actions={reveal}
        elseif work then html,actions,holds=M.html(work,rows,context) else html,actions='<p>'..escape(_('No works found.'))..'</p>',{} end
        context.present(self,html,actions,rows,holds)
    end
    function self:goTo(index,allow_unknown_next)
        local maximum=self.pager and self.pager.total or self.total or #self.works
        if self.closed or self.loading or type(index)~='number' or index%1~=0
            or index<1 or (maximum and index>maximum and not (allow_unknown_next and self.pager and not self.pager.total))
            or index==self.index then return end
        self.request=(self.request or 0)+1
        local request=self.request
        if self.works[index] then self.index=index;self:render();return end
        if not self.pager then return end
        context.network(function()
            if self.closed or self.loading or self.request~=request then return end
            self.loading=true
            local ok,work=pcall(self.pager.load,self.pager,index)
            self.loading=false
            if not ok then error(work,0) end
            if self.closed or self.request~=request then return end
            if work then self.index=index;self:render() end
        end)
    end
    function self:previous()
        self:goTo(self.index-1)
    end
    function self:next()
        if self.closed or self.loading then return end
        if self.pager then self:goTo(self.index+1,true);return end
        if self.index<#self.works then self.index=self.index+1;self:render();return end
        if not context.fetch or (self.total and self.index>=self.total) then return end
        local index=self.index
        context.network(function()
            if self.closed or self.loading or self.index~=index then return end
            self.loading=true
            local ok,more=pcall(context.fetch)
            self.loading=false
            if not ok then error(more,0) end
            if self.closed or self.index~=index then return end
            if type(more)=='table' and #more>0 then
                for __,work in ipairs(more) do self.works[#self.works+1]=work end
                self.index=self.index+1;self:render()
            end
        end)
    end
    return self
end

function M.show(browser,context)
    local UI=require('ui/uimanager')
    local Device=require('device')
    local Screen=Device.screen
    local Geom=require('ui/geometry')
    local Frame=require('ui/widget/container/framecontainer')
    local Vertical=require('ui/widget/verticalgroup')
    local Center=require('ui/widget/container/centercontainer')
    local TitleBar=require('ui/widget/titlebar')
    local Button=require('ui/widget/button')
    local Horizontal=require('ui/widget/horizontalgroup')
    local Span=require('ui/widget/horizontalspan')
    local T=require('ffi/util').template
    local Scroll=require('ui/widget/scrollhtmlwidget')
    local View=require('ui/widget/focusmanager'):extend{covers_fullscreen=true,is_always_active=true}
    local width,height=Screen:getWidth(),Screen:getHeight()
    local padding=Screen:scaleBySize(12)
    local state
    if not context.tag_action and context.plugin then
        context.tag_action=function(kind,name) require('ao3lib.ui.tag_actions').show(context.plugin,kind,name) end
    end
    function View:onClose() UI:close(self);return true end
    function View:onCloseWidget()
        self._ao3_closed=true
        context.plugin.menu_stack[self]=nil
        if not self._replacing then
            state.closed=true
            require('ao3lib.ao3.favorite_cache').unwatch(state)
            require('ao3lib.ao3.mute_cache').unwatch(state)
        end
        UI:setDirty(nil,'ui')
    end
    function View:onShow() UI:setDirty(self,'ui');return true end
    function View:reload() state:render() end
    function View:onNextWork()
        if not self._ao3_closed then state:next() end
        return true
    end
    function View:onPreviousWork()
        if not self._ao3_closed then state:previous() end
        return true
    end
    function View:onSwipeWork(_,gesture)
        local direction=require('ui/bidi').flipDirectionIfMirroredUILayout(gesture.direction)
        if direction=='west' then return self:onNextWork() end
        if direction=='east' then return self:onPreviousWork() end
        return false
    end
    function View:init()
        self.key_events=self.key_events or {}
        self.key_events.Close={{'Back'}}
        if Device:isTouchDevice() then
            self.ges_events=self.ges_events or {}
            self.ges_events.SwipeWork={require('ui/gesturerange'):new{
                ges='swipe',range=Geom:new{x=0,y=0,w=width,h=height},
            }}
        end
        if Device:hasKeys() then
            self.key_events.NextWork={{Device.input.group.PgFwd}}
            self.key_events.PreviousWork={{Device.input.group.PgBack}}
        end
        local title=TitleBar:new{width=width,title=context.title or _('AO3 works'),
            left_icon='ao3',left_icon_tap_callback=function() require('ao3lib.ui.navigation').menu(self) end,close_callback=function() self:onClose() end}
        self.titlebar=title
        local view_options=context.list and Button:new{text=_('View options…'),
            width=width-2*padding,bordersize=0,show_parent=self,callback=function() context.list(self,state) end}
        self.view_options_button=view_options
        local options_height=view_options and view_options:getSize().h or 0
        -- Match KeyValuePage's borderless first/previous/page/next/last bar.
        -- The full result count includes works not downloaded into the UI
        -- cache yet; a jump fetches only its AO3 result batch.
        local mirrored=require('ui/bidi').mirroredUILayout()
        local previous=Button:new{icon=mirrored and 'chevron.right' or 'chevron.left',bordersize=0,
            show_parent=self,enabled=state.index>1,callback=function() state:previous() end}
        local following=Button:new{icon=mirrored and 'chevron.left' or 'chevron.right',bordersize=0,
            show_parent=self,enabled=state.index<state:pageCount() or (context.fetch~=nil and (not state.total or state.index<state.total)),
            callback=function() state:next() end}
        local first=Button:new{icon=mirrored and 'chevron.last' or 'chevron.first',bordersize=0,
            show_parent=self,enabled=state.index>1,callback=function() state:goTo(1) end}
        local last=Button:new{icon=mirrored and 'chevron.first' or 'chevron.last',bordersize=0,
            show_parent=self,enabled=state.index<state:pageCount(),callback=function() state:goTo(state:pageCount()) end}
        local page=Button:new{text=state:pageCount()>0 and T(_('Page %1 of %2'),state.index,state:pageCount()) or _('No items'),
            bordersize=0,text_font_face='pgfont',text_font_bold=false,enabled=state:pageCount()>1,
            show_parent=self,call_hold_input_on_tap=true,hold_input={
                title=_('Enter page number'),input_type='number',
                hint_func=function() return T('(1 - %1)',state:pageCount()) end,
                ok_text=_('Go to page'),callback=function(input) state:goTo(tonumber(input)) end,
            }}
        self.page_buttons={first,previous,page,following,last}
        local used=0
        for __,button in ipairs(self.page_buttons) do used=used+button:getSize().w end
        local gap=math.max(0,math.min(Screen:scaleBySize(32),math.floor((width-used)/4)))
        local controls=Horizontal:new{first,Span:new{width=gap},previous,Span:new{width=gap},page,
            Span:new{width=gap},following,Span:new{width=gap},last}
        local scroll=Scroll:new{width=width-2*padding,
            height=math.max(1,height-title:getHeight()-options_height-controls:getSize().h-2*padding),
            html_body=self.html,css=M.css,html_resource_directory=require('ao3lib.ui.icons').file:match('^(.*[/\\])'),
            default_font_size=Screen:scaleBySize(M.baseTextSize()),dialog=self,
            html_link_tapped_callback=function(link)
                local id=tonumber((link.uri or ''):match('^ao3%-action:(%d+)$'))
                if id and self.actions[id] then self.actions[id]() end
            end}
        self.work_scroll=scroll
        M.bindTitleHold(scroll,function(id)
            local hold=self.holds and self.holds[id]
            if hold then hold();return true end
            return false
        end)
        -- Page keys belong to work navigation. Remove only the scroller's
        -- physical-key bindings; its touch/swipe scrolling remains intact.
        if scroll.key_events then
            scroll.key_events.ScrollDown=nil
            scroll.key_events.ScrollUp=nil
        end
        local content=Vertical:new{title}
        if view_options then
            content[#content+1]=Center:new{dimen=Geom:new{w=width,h=options_height},view_options}
        end
        content[#content+1]=Frame:new{padding=padding,margin=0,bordersize=0,scroll}
        content[#content+1]=Center:new{dimen=Geom:new{w=width,h=controls:getSize().h},controls}
        self[1]=Frame:new{padding=0,margin=0,bordersize=0,background=require('ffi/blitbuffer').COLOR_WHITE,
            dimen=Geom:new{w=width,h=height},content}
        self.layout=view_options and {{view_options},self.page_buttons} or {self.page_buttons}
    end
    context.rows=context.rows or function(work) return browser:generateTable({}, {work},context.update,context.download) end
    local favorites=require('ao3lib.ao3.favorite_cache')
    context.is_favorite=context.is_favorite or favorites.contains
    context.network=require('ao3lib.ao3.network').run
    context.present=function(_,html,actions,rows,holds)
        local previous=state.window
        local ratio=state._favorite_refresh and previous and previous.work_scroll
            and previous.work_scroll.getCurrentRatio and previous.work_scroll:getCurrentRatio()
        state._favorite_refresh=nil
        local window=View:new{html=html,actions=actions,rows=rows,holds=holds}
        state.window=window;browser.browse_window=window
        require("ao3lib.ui.navigation").bind(context.plugin, window, {
            replace=previous or context.replacing, identity=context.identity, resume=function(resumed)
                if context.resume then context.resume(resumed) end
                if state._favorites_dirty and not state.closed then
                    state._favorites_dirty=nil;state._favorite_refresh=true;state:render()
                end
            end,
            back=context.on_back,
        })
        context.replacing=nil
        UI:show(window)
        if previous then previous._replacing=true;UI:close(previous) end
        if ratio and window.work_scroll and window.work_scroll.scrollToRatio then window.work_scroll:scrollToRatio(ratio) end
    end
    state=M.new(context)
    state:render()
    favorites.watch(state,function(current)
        local window=current.window
        if current.closed or not window or window._ao3_closed then return end
        local top=UI.getTopmostVisibleWidget and UI:getTopmostVisibleWidget()
        if top and top~=window and not top.modal then current._favorites_dirty=true;return end
        current._favorites_dirty=nil
        current._favorite_refresh=true;current:render()
    end)
    favorites.ensure()
    require("ao3lib.ui.work_view_help").showIfNeeded()
    return state
end
return M
