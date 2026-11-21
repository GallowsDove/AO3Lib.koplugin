-- Offline downloaded-library screen, sharing the review's fixed controls.
local UI=require('ui/uimanager')
local Menu=require('ui/widget/menu')
local ButtonDialog=require('ui/widget/buttondialog')
local Config=require('ao3lib.core.config')
local History=require('ao3lib.library.history')
local Cache=require('ao3lib.library.local_cache')
local Scope=require('ao3lib.ui.update_scope')
local Format=require('ao3lib.core.format')
local _=require('gettext')
local M={}
local function progress(work)
    local chapters=work.chapter_data or {}
    local count=tonumber((work.chapters or ''):match('^(%d+)/'))
    if #chapters>0 then
        local read=0
        for i=1,count or #chapters do if chapters[i] and chapters[i].read then read=read+1 end end
        local total=count or #chapters
        return read==total,read,total
    end
    return work.read==true,work.read and count or 0,count
end
function M.show(plugin)
    local window,header,refresh,job,rendered,showRendered
    local closed,loading=false,true
    local rendered_suspended=false
    local works,deleted={},{}
    local saved=Config:readSetting('downloaded_view') or {}
    local selected_scope=type(saved.scope)=='table' and saved.scope or {kind='library'}
    local filter,sort=saved.reading or 'all',saved.sort or 'title'
    local completion,length=saved.completion or 'all',saved.length or 'all'
    local display=saved.display or 'list'
    local function remember()
        Config:saveSetting('downloaded_view',{scope=selected_scope,reading=filter,sort=sort,completion=completion,length=length,display=display})
    end
    local chooseOptions
    local reading_choices={{'all',_('All reading states')},{'unread',_('Unread (including started)')},{'new',_('Not started')},{'reading',_('Currently reading')},{'read',_('Read')}}
    local completion_choices={{'all',_('Any completion status')},{'complete',_('Complete')},{'ongoing',_('In progress')},{'unknown',_('Unknown completion status')}}
    local length_choices={{'all',_('Any word count')},{'short',_('Under 10,000 words')},{'medium',_('10,000–49,999 words')},{'long',_('50,000–99,999 words')},{'epic',_('100,000+ words')}}
    local sort_choices={{'title',_('Title')},{'author',_('Author')},{'recent',_('Recently read')}}
    local function choiceLabel(choices,key)
        for _,choice in ipairs(choices) do if choice[1]==key then return choice[2] end end
        return choices[1][2]
    end
    local roots={}
    local function addRoot(path) if type(path)=='string' and path~='' then roots[#roots+1]=path end end
    addRoot(Config:readSetting('fanfic_folder_path'))
    addRoot(require('apps/filemanager/filemanagerutil').getHomeFolder())
    local function valid() return not closed and (not UI.isWidgetShown or UI:isWidgetShown(window)) end
    local function stop()
        if closed then return end
        closed=true
        if job and job.cancel then job:cancel() end
    end
    local function merge(found)
        for id in pairs(works) do works[id]=nil end
        for id,source in pairs(found or {}) do
            if not deleted[tostring(id)] then
                local work=require('ao3lib.core.table').shallowCopy(source)
                local saved=History.get(id)
                if saved and (not saved.path or saved.path==work.path) then
                    work.chapter_data=saved.chapter_data or work.chapter_data
                    work.read=saved.read;work.last_accessed=saved.last_accessed
                end
                works[tostring(id)]=work
            end
        end
    end
    local function workOptions(work)
        return {deleted=function()
            deleted[tostring(work.id)]=true;works[tostring(work.id)]=nil
            Cache.remove(roots,work.id)
        end,refresh=refresh,
        details=function()
            local visible={}
            for _,row in ipairs(window.item_table) do visible[#visible+1]=row.work end
            showRendered(visible,work.id)
        end}
    end
    local function changeScope(value)
        if closed then return end
        selected_scope=value;remember();window.page=1;refresh();chooseOptions()
    end
    local function chooseScope()
        local chooser
        local function group(kind)
            UI:close(chooser)
            local entries={};for __,work in pairs(works) do entries[#entries+1]={work=work} end
            local rows,picker={}
            for __,entry in ipairs(Scope.groups(entries,kind)) do
                local name=entry.name
                rows[#rows+1]={text=string.format('%s (%d)',name,entry.count),callback=function()
                    UI:close(picker);changeScope({kind=kind,value=name})
                end}
            end
            picker=Menu:new(require('ao3lib.ui.widgets').menu{title=kind=='author' and _('Choose author') or _('Choose fandom'),item_table=rows,
                onMenuSelect=function(_,item) if item.callback then item.callback() end;return true end})
            UI:show(require('ao3lib.ui.navigation').bind(plugin,picker))
        end
        chooser=ButtonDialog:new{title=_('Show downloaded works'),buttons={
            {{text=_('Entire library'),callback=function() UI:close(chooser);changeScope({kind='library'}) end}},
            {{text=_('One author…'),callback=function() group('author') end}},
            {{text=_('One fandom…'),callback=function() group('fandom') end}},
        }}
        UI:show(chooser)
    end
    local function choose(choices,current,set,title)
        local dialog
        local rows={}
        for _,choice in ipairs(choices) do
            local key=choice[1]
            rows[#rows+1]={{text=choice[2],checked_func=function() return current==key end,no_refresh_checkmark=true,
                callback=function()
                    UI:close(dialog)
                    if closed then return end
                    set(key);remember();window.page=1;refresh();chooseOptions()
                end}}
        end
        dialog=ButtonDialog:new{title=title,buttons=rows};UI:show(dialog)
    end
    chooseOptions=function()
        if closed then return end
        local dialog
        local function option(text,callback)
            return {{text=text,callback=function() UI:close(dialog);callback() end}}
        end
        dialog=ButtonDialog:new{title=_('Downloaded works · View options'),buttons={
            option(_('Scope: ')..Scope.label(selected_scope),chooseScope),
            option(_('Reading: ')..choiceLabel(reading_choices,filter),function() choose(reading_choices,filter,function(v) filter=v end,_('Reading status')) end),
            option(_('Completion: ')..choiceLabel(completion_choices,completion),function() choose(completion_choices,completion,function(v) completion=v end,_('Completion status')) end),
            option(_('Length: ')..choiceLabel(length_choices,length),function() choose(length_choices,length,function(v) length=v end,_('Word count')) end),
            option(_('Sort: ')..choiceLabel(sort_choices,sort),function() choose(sort_choices,sort,function(v) sort=v end,_('Sort downloaded works')) end),
            option(_('Review updates for shown works'),function()
                if window.library_model.visible>0 then window.library_model.review() end
            end),
            option(_('Reset view'),function()
                selected_scope={kind='library'};filter='all';sort='title';completion='all';length='all'
                remember();window.page=1;refresh();chooseOptions()
            end),
            option(_('Done'),function() end),
        }}
        UI:show(dialog)
    end
    refresh=function()
        if closed then return end
        local configured=Config:readSetting('downloaded_rendered_view',display=='rendered') and 'rendered' or 'list'
        if configured~=display then
            display=configured;rendered_suspended=false
            if display=='list' and rendered then
                local previous=rendered;rendered=nil;previous.closed=true;previous.window._replacing=true
                UI:close(previous.window)
            end
        end
        local scoped,visible,read={},{},0
        for __,work in pairs(works) do
            if Scope.matches(work,selected_scope) then
                scoped[#scoped+1]=work
                local finished,done=progress(work)
                if finished then read=read+1 end
                local reading_match=filter=='all' or (filter=='read' and finished) or (filter=='unread' and not finished)
                    or (filter=='new' and not finished and (done or 0)==0) or (filter=='reading' and not finished and (done or 0)>0)
                local known=Scope.isComplete(work) and 'complete' or
                    ((work.chapters or ''):match('/%s*[%d%?]') or (work.iswip or ''):lower()=='in progress') and 'ongoing' or 'unknown'
                local completion_match=completion=='all' or completion==known
                local words=tonumber((tostring(work.words or work.wordcount or ''):gsub(',','')))
                local length_match=length=='all' or words and ((length=='short' and words<10000)
                    or (length=='medium' and words>=10000 and words<50000)
                    or (length=='long' and words>=50000 and words<100000) or (length=='epic' and words>=100000))
                if reading_match and completion_match and length_match then visible[#visible+1]=work end
            end
        end
        table.sort(visible,function(a,b)
            if sort=='recent' and (a.last_accessed or '')~=(b.last_accessed or '') then return (a.last_accessed or '')>(b.last_accessed or '') end
            if sort=='author' and (a.author or ''):lower()~=(b.author or ''):lower() then return (a.author or ''):lower()<(b.author or ''):lower() end
            if (a.title or ''):lower()~=(b.title or ''):lower() then return (a.title or ''):lower()<(b.title or ''):lower() end
            return tostring(a.id)<tostring(b.id)
        end)
        local label=Scope.label(selected_scope)
        local active={label}
        if filter~='all' then active[#active+1]=choiceLabel(reading_choices,filter) end
        if completion~='all' then active[#active+1]=choiceLabel(completion_choices,completion) end
        if length~='all' then active[#active+1]=choiceLabel(length_choices,length) end
        local view_label=table.concat(active,' · ')
        local model={summary=string.format(_('%d of %d works · %s'),#visible,#scoped,view_label),
            notice=loading and _('Loading downloaded works…') or '',total=#scoped,visible=#visible,filter=filter,
            sort=sort,completion=completion,length=length,scope_label=label}
        model.review=function()
            if not closed then require('ao3lib.ui.update_review').showWorks(plugin,visible,view_label) end
        end
        model.buttons={{{text=_('View options…'),callback=chooseOptions}}}
        local rows={}
        for __,work in ipairs(visible) do
            local finished,done,total=progress(work)
            local status
            if finished then status=_('Read')
            elseif done and done>0 and total then status=string.format(_('%d/%d chapters read'),done,total)
            else status=_('Unread') end
            if work.wordcount or work.words then status=status..' · '..Format.integer(work.words or work.wordcount)..' '.._('words') end
            rows[#rows+1]={text=(work.title or work.path)..'  —  '.._('by ')..(work.author or _('Anonymous'))..' · '..status,id=work.id,work=work,
                callback=function()
                    require('ao3lib.ui.work_actions').show(plugin,work,workOptions(work))
                end}
        end
        if #visible==0 and not loading then model.notice=#scoped==0 and _('No downloaded works in this scope.') or _('No works in this filter.') end
        window.library_model=model;window.item_table=rows
        header:update(model);window:updateItems(nil,false);UI:setDirty(window,'ui')
        if rendered and #visible==0 then
            local previous=rendered;rendered=nil;previous.closed=true;previous.window._replacing=true
            UI:close(previous.window)
        elseif ((display=='rendered' and not rendered_suspended) or (rendered and not rendered.closed)) and not loading and #visible>0 then showRendered(visible) end
    end
    showRendered=function(visible,focused_id)
        if rendered and not rendered.closed then
            local id=focused_id or (rendered.works[rendered.index] and rendered.works[rendered.index].id)
            rendered.works=visible;rendered.total=nil
            rendered.index=1
            for i,work in ipairs(visible) do if work.id==id then rendered.index=i;break end end
            rendered:render();return
        end
        local index=1
        for i,work in ipairs(visible) do if work.id==focused_id then index=i;break end end
        local context={plugin=plugin,works=visible,index=index,title=_('Downloaded Works'),summary_html=true,
            list=function() chooseOptions() end,
            on_back=function()
                if rendered then rendered.closed=true end
                rendered=nil;rendered_suspended=true
                return false
            end,
            rows=function(work)
                -- Use the same author/series navigation as online browsing,
                -- with an isolated browser so children cannot replace callbacks.
                local browser=setmetatable({Fanfic=plugin,showAuthorInfoCallback=function(author)
                    plugin:onShowAuthor(author)
                end},{__index=require('ao3lib.ui.work_browser')})
                local rows=browser:generateTable({}, {work})
                rows[1].callback=function()
                    local options=workOptions(work)
                    options.hide_details=true -- This page already shows the details.
                    require('ao3lib.ui.work_actions').show(plugin,work,options)
                end
                return rows
            end,
            resume=function() refresh() end,
        }
        rendered=require('ao3lib.ui.work_view').show({},context)
    end
    header=require('ao3lib.ui.update_review_header').new(_('Downloaded Works'),function() if window then window:onClose() end end,
        function() if window then window:onLeftButtonTap() end end)
    window=Menu:new(require('ao3lib.ui.widgets').menu{title=_('Downloaded Works'),custom_title_bar=header,item_table={},
        items_max_lines=3,items_font_size=18,close_callback=stop,
        setupItemHeights=function(self)
            -- Flexible rows ignore items_per_page. Add space to their measured
            -- heights, then rebuild page boundaries using those padded heights.
            Menu.setupItemHeights(self)
            local padding=require('device').screen:scaleBySize(6)
            self.page_items={{}}
            local page,height=self.page_items[1],0
            for i,item in ipairs(self.item_table) do
                item.height=item.height+padding
                if #page>0 and height+item.height>self.available_height then
                    page={};self.page_items[#self.page_items+1]=page;height=0
                end
                page[#page+1]=i;height=height+item.height
            end
        end,
        onMenuSelect=function(_,item) if item.callback then item.callback() end;return true end})
    local original=window.onCloseWidget
    window.onCloseWidget=function(self,...) stop();if original then return original(self,...) end end
    require('ao3lib.ui.navigation').bind(plugin,window,{resume=function()
        local latest=Cache.get(roots)
        if latest then merge(latest) end
        refresh()
    end})
    local snapshot=Cache.get(roots)
    if snapshot then merge(snapshot) end
    refresh();UI:show(window)
    job=Cache.load(roots,function(found,err)
        if not valid() then return end
        loading=false
        if found then merge(found) end
        refresh()
        if err then UI:show(require('ui/widget/infomessage'):new{text=tostring(err)}) end
    end,valid)
    if not job then loading=false;refresh() end
    return window
end
return M
