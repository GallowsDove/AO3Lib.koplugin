local UI = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local Network = require("ao3lib.ao3.network")
local Updates = require("ao3lib.updates.checks")
local Scope = require("ao3lib.ui.update_scope")
local Format = require("ao3lib.core.format")
local _ = require("gettext")
local M = {}
local previous
local previous_native
local function eligible(entry) return entry.remote and (entry.status=="update" or entry.status=="review") end
local function statusLabel(entry,details)
    if entry.status=='updated' and entry.move_error then return _('Updated; move needs attention') end
    if entry.status=='updated' and (entry.missing_images or 0)>0 then
        return string.format(_("Updated; %d image(s) unavailable"),entry.missing_images)
    end
    local labels={unchecked=_("Not checked"), update=_("Update available"), review=_("Review needed"),
        current=_("Up to date"), updated=_("Updated"), error=_("Failed"),
        unavailable=_("Unavailable or restricted"), state_error=_("EPUB updated; reading-state save failed")}
    if entry.status=="update" and not details then
        if entry.native_only then return _("Native EPUB available") end
        local old=tonumber(((entry.local_work or {}).chapters or ""):match("^(%d+)/"))
        local new=tonumber(((entry.remote or {}).chapters or ""):match("^(%d+)/"))
        if old and new and new>old then return Format.newChapters(new-old)..string.format(" · %d → %d",old,new) end
        if entry.remote and entry.local_work and entry.remote.chapters~=entry.local_work.chapters then
            local current,total=(entry.remote.chapters or ""):match("^(%d+)/(%d+)$")
            if current and current==total then return _("Completed") end
        end
        for __,change in ipairs(entry.changes or {}) do
            if change:find(_("Words:"),1,true) then return _("Text changed") end
            local date=change:match("→%s*(%d%d%d%d%-%d%d%-%d%d)$")
            if date then return _("Updated ")..date end
        end
        return _("Update available")
    end
    return labels[entry.status] or entry.status
end
local function describe(entry)
    local work=entry.work
    return (work.title or tostring(work.id)) .. "\n" .. (work.author or "") .. "\n\n"
        .. statusLabel(entry,true) .. "\n\n"
        .. table.concat(entry.changes or {},"\n")
        .. (entry.error and ("\n\n" .. entry.error) or "")
        .. (entry.move_error and ("\n\n" .. _("Could not move updated work: ") .. entry.move_error) or "")
        .. "\n\n" .. tostring(work.path)
end

local function openReview(fanfic, works, check_now, focused_work, on_close, native_only, requested_scope)
    local prior=previous
    if native_only then prior=previous_native end
    local session=Updates.new(works,prior)
    session.native_only=native_only
    if native_only then previous_native=session else previous=session end
    local prior_entries={}
    for __,entry in ipairs(prior and prior.entries or {}) do
        prior_entries[tostring(entry.work.id).."\n"..tostring(entry.work.path)]=entry
    end
    local selected_scope=requested_scope or {kind="library"}
    local function matches(work)
        if focused_work then return tostring(work.id)==tostring(focused_work.id) and work.path==focused_work.path end
        return Scope.matches(work,selected_scope)
    end
    local scope_revision=0
    local scope={}
    for __,entry in ipairs(session.entries) do if matches(entry.work) then scope[entry]=true end end
    local function scopeEntries()
        local entries={};for __,entry in ipairs(session.entries) do if scope[entry] then entries[#entries+1]=entry end end
        return entries
    end
    local menu, refresh, release_awake, header
    local filter="updates"
    local screen_closed=false
    local loading=false
    local function run(operation, targets)
        if #targets==0 or screen_closed then return end
        local revision=scope_revision
        Network.run(function()
            if session.closed or session.busy or revision~=scope_revision then return end
            local scoped={}
            for __,entry in ipairs(targets) do if scope[entry] then scoped[#scoped+1]=entry end end
            if #scoped==0 then return end
            local started, err=session:run(operation, scoped, refresh)
            if not started and err then UI:show(InfoMessage:new{text=err}) end
        end)
    end
    local function toggle(entry)
        if not session.busy and eligible(entry) then entry.selected=not entry.selected;refresh() end
    end
    local function retryable(entry) return entry.status=="error" or entry.status=="unavailable" end
    local function details(entry)
        local viewer
        local buttons={}
        if eligible(entry) then
            buttons[#buttons+1]={text=entry.selected and _("Deselect work") or _("Select work"),enabled=not session.busy,
                callback=function() UI:close(viewer);toggle(entry) end}
        end
        if retryable(entry) then
            buttons[#buttons+1]={text=_("Retry check"),enabled=not session.busy,
                callback=function() UI:close(viewer);run("check",{entry}) end}
        end
        viewer=TextViewer:new{title=_("Work update details"),text=describe(entry),buttons_table=#buttons>0 and {buttons} or nil}
        UI:show(require("ao3lib.ui.navigation").bind(fanfic,viewer))
    end
    local function moreActions(model)
        local dialog
        local buttons={}
        for __,action in ipairs(model.more) do
            local choice=action
            buttons[#buttons+1]={{text=choice.text,enabled=choice.enabled,
                callback=function() UI:close(dialog);if not screen_closed then choice.callback() end end}}
        end
        dialog=require("ui/widget/buttondialog"):new{title=_("Update actions"),buttons=buttons}
        UI:show(dialog)
    end
    local function chooseScope()
        if session.busy then return end
        local chooser
        local function select(value)
            if screen_closed or session.busy then return end
            if value.incomplete_only==nil then value.incomplete_only=selected_scope.incomplete_only end
            selected_scope=value
            scope_revision=scope_revision+1
            for __,entry in ipairs(session.entries) do
                scope[entry]=matches(entry.work) and true or nil
                entry.selected=false
            end
            menu.page=1;refresh()
        end
        local function chooseGroup(kind)
            UI:close(chooser)
            local picker
            local rows={}
            for __,group in ipairs(Scope.groups(session.entries,kind,selected_scope.incomplete_only)) do
                local value=group.name
                rows[#rows+1]={text=string.format("%s (%d)",value,group.count),callback=function()
                    UI:close(picker);select({kind=kind,value=value})
                end}
            end
            picker=Menu:new(require("ao3lib.ui.widgets").menu{title=kind=="author" and _("Choose author") or _("Choose fandom"),item_table=rows,
                onMenuSelect=function(_,item) if item.callback then item.callback() end;return true end}
            )
            UI:show(require("ao3lib.ui.navigation").bind(fanfic,picker))
        end
        chooser=require("ui/widget/buttondialog"):new{title=_("Check updates for"),buttons={
            {{text=_("Entire library"),callback=function() UI:close(chooser);select({kind="library"}) end}},
            {{text=_("One author…"),callback=function() chooseGroup("author") end}},
            {{text=_("One fandom…"),callback=function() chooseGroup("fandom") end}},
            {{text=_("Incomplete works only"),checked_func=function() return selected_scope.incomplete_only==true end,
                callback=function()
                    UI:close(chooser)
                    select({kind=selected_scope.kind,value=selected_scope.value,incomplete_only=not selected_scope.incomplete_only})
                end}},
        }}
        UI:show(chooser)
    end
    refresh=function()
        if screen_closed then return end
        local checked, available, failed, selected, unsaved, review_count=0,0,0,0,0,0
        local pending, retries, selections, all_checks={},{},{},{}
        local total=0
        for __,entry in ipairs(scopeEntries()) do
            total=total+1
            if entry.status~="state_error" then all_checks[#all_checks+1]=entry end
            if entry.status~="unchecked" then checked=checked+1 else pending[#pending+1]=entry end
            if entry.status=="update" then available=available+1 end
            if retryable(entry) then failed=failed+1;retries[#retries+1]=entry end
            if entry.status=="state_error" then failed=failed+1;unsaved=unsaved+1 end
            if entry.status=="review" or retryable(entry) or entry.status=="state_error" or entry.move_error then review_count=review_count+1 end
            if entry.selected and eligible(entry) then selected=selected+1;selections[#selections+1]=entry end
        end
        local model={summary=string.format(_("%d of %d checked · %d updates found · %d failed"),checked,total,available,failed),
            notice="",buttons={},filters={},more={},selected=selected,checked=checked,total=total,available=available,failed=failed,filter=filter}
        model.scope_label=focused_work and (focused_work.title or _("This work")) or Scope.label(selected_scope)
        if not focused_work and selected_scope.kind~="selection" then model.scope={text=_("Scope: ")..model.scope_label,enabled=not session.busy,callback=chooseScope} end
        local check_targets=#pending>0 and pending or all_checks
        if session.busy then
            model.notice=string.format(_("%s %d of %d"),session.operation=="check" and _("Checking") or _("Downloading"),math.min((session.done or 0)+1,session.total),session.total)
        elseif loading then model.notice=_("Loading downloaded works…")
        elseif session.pause_reason then model.notice=_("Paused: ")..session.pause_reason end
        local primary={text=session.busy and (session.operation=="check" and _("Stop checking") or _("Stop downloads"))
                or (#pending>0 and checked>0 and _("Continue checking") or (native_only and _("Check native availability") or _("Check for updates"))),
            enabled=session.busy or #check_targets>0,
            callback=function() if session.busy then session:stop();refresh() else run("check",check_targets) end end}
        local apply={text=string.format(native_only and _("Replace selected (%d)") or _("Update selected (%d)"),selected),
            enabled=selected>0 and not session.busy,callback=function() run("update",selections) end}
        model.buttons={{primary,apply,{text=_("More…"),enabled=not session.busy,callback=function() moreActions(model) end}}}
        local function addMore(text,enabled,callback) model.more[#model.more+1]={text=text,enabled=enabled,callback=callback} end
        if #all_checks>0 then addMore(_("Recheck all"),true,function() run("check",all_checks) end) end
        if #retries>0 then addMore(string.format(_("Retry failed checks (%d)"),#retries),true,function() run("check",retries) end) end
        if selected>0 then addMore(_("Clear selection"),true,function()
            for __,entry in ipairs(scopeEntries()) do entry.selected=false end;refresh()
        end) end
        if unsaved>0 then addMore(_("Retry saving reading state"),true,function()
            local saved,err=Updates.retrySave(session)
            if not saved then UI:show(InfoMessage:new{text=tostring(err)}) end;refresh()
        end) end
        if checked>0 then addMore(_("Clear results"),true,function()
            for __,entry in ipairs(scopeEntries()) do
                if entry.status~="state_error" then
                    local work=entry.work
                    for key in pairs(entry) do entry[key]=nil end
                    entry.work,entry.status,entry.selected=work,"unchecked",false
                end
            end
            session.done,session.total=0,0;refresh()
        end) end
        if #model.more==0 then table.remove(model.buttons[1],3) end
        for __,tab in ipairs({{"updates",_("Updates"),available},{"review",_("Needs review"),review_count},{"all",_("All"),total}}) do
            local key=tab[1]
            model.filters[#model.filters+1]={text=string.format("%s (%d)",tab[2],tab[3]),
                checked_func=function() return filter==key end,callback=function() filter=key;menu.page=1;refresh() end}
        end
        if available>0 and filter~="review" then
            local all_selected=true
            for __,entry in ipairs(scopeEntries()) do if entry.status=="update" and not entry.selected then all_selected=false end end
            model.select_all={text=_("Select all updates"),checked_func=function() return all_selected end,enabled=not session.busy,
                callback=function()
                    if session.busy then return end
                    for __,entry in ipairs(scopeEntries()) do if entry.status=="update" then entry.selected=not all_selected end end
                    refresh()
                end}
        end
        local rows={}
        for __,entry in ipairs(scopeEntries()) do
            local needs_review=entry.status=="review" or retryable(entry) or entry.status=="state_error" or entry.move_error
            if filter=="all" or (filter=="updates" and entry.status=="update") or (filter=="review" and needs_review)
                    or session.active_entry==entry then
                local status=statusLabel(entry)
                if session.active_entry==entry then status=session.operation=="check" and _("Checking…") or _("Downloading…") end
                local prefix=eligible(entry) and (entry.selected and "☑ " or "☐ ") or ""
                rows[#rows+1]={text=prefix..(entry.work.title or tostring(entry.work.id)).."\n"..(entry.work.author or "").."\n"..status,
                    mandatory=retryable(entry) and _("Retry") or nil,entry=entry,
                    callback=function() details(entry) end,toggle_callback=function() toggle(entry) end,
                    retry_callback=retryable(entry) and function() run("check",{entry}) end or nil,
                    hold_callback=function() details(entry) end}
            end
        end
        if #rows==0 and model.notice=="" then
            model.notice=total==0 and (native_only and _("No converted AO3 EPUBs found.") or _("No downloaded AO3 works found."))
                or (filter=="updates" and _("No updates listed. Check for updates or choose All.") or _("No works in this filter."))
        end
        menu.review_model=model
        menu.item_table=rows
        header:update(model)
        menu:updateItems(nil,false)
        UI:setDirty(menu,"ui")
    end

    local function close()
        if screen_closed then return end
        screen_closed=true
        if release_awake then release_awake();release_awake=nil end
        if session.busy and session.operation=="update" then session:stop() end
        if native_only then session.closed=true;session:stop() end
        if on_close then on_close() end
        if fanfic.ui and fanfic.ui.file_chooser then pcall(function() fanfic.ui.file_chooser:refreshPath() end) end
    end
    local review_title=native_only and _("Replace converted EPUBs") or _("Downloaded work updates")
    if selected_scope.kind=="selection" then review_title=_("Updates: ")..selected_scope.label end
    header=require("ao3lib.ui.update_review_header").new(review_title,
        function() if menu then menu:onClose() end end,function() if menu then menu:onLeftButtonTap() end end)
    menu=Menu:new(require("ao3lib.ui.widgets").menu{title=review_title, item_table={}, close_callback=close,custom_title_bar=header,items_per_page=5,items_max_lines=3,
        items_font_size=18,is_enable_shortcut=false,
        onMenuSelect=function(_,item,pos)
            local mirrored=require("ui/bidi").mirroredUILayout()
            local x=pos and (mirrored and (1-pos.x) or pos.x)
            if x and x<=0.13 and item.entry and eligible(item.entry) then item.toggle_callback()
            elseif x and x>=0.85 and item.retry_callback and not session.busy then item.retry_callback()
            elseif item.callback then item.callback() end
            return true
        end,
        onMenuHold=function(_,item) if item.hold_callback then item.hold_callback() end; return true end,
    })
    local original_close=menu.onCloseWidget
    menu.onCloseWidget=function(self,...)
        close()
        if original_close then return original_close(self,...) end
    end
    require("ao3lib.ui.navigation").bind(fanfic, menu)
    refresh()
    UI:show(menu)
    release_awake=require("ao3lib.ui.awake").acquire()
    if check_now then run("check", scopeEntries()) end
    local controls={}
    function controls.loading(value) loading=value;refresh() end
    function controls.merge(works,authoritative)
        if screen_closed then return end
        local byid={}
        for __,entry in ipairs(session.entries) do
            byid[tostring(entry.work.id).."\n"..tostring(entry.work.path)]=entry
        end
        local seen={}
        for __,work in pairs(works or {}) do
            if work.id and work.path then
                local key=tostring(work.id).."\n"..tostring(work.path)
                local entry=byid[key]
                if not entry then
                    local old=prior_entries[key]
                    entry=old and Updates.new({work},{entries={old}}).entries[1]
                        or {work=work,status="unchecked",selected=false}
                    session.entries[#session.entries+1]=entry;byid[key]=entry
                elseif entry.status=="unchecked" then entry.work=work end
                scope[entry]=matches(work) and true or nil;seen[entry]=true
            end
        end
        if authoritative then
            for entry in pairs(scope) do if not seen[entry] then scope[entry]=nil end end
        end
        table.sort(session.entries,function(a,b)
            if (a.work.title or "")~=(b.work.title or "") then return (a.work.title or "")<(b.work.title or "") end
            return tostring(a.work.id)<tostring(b.work.id)
        end)
        refresh()
    end
    return session,menu,controls
end

-- A library view can review exactly the visible local works without expanding
-- a read-state filter into a full-library network check.
function M.showWorks(fanfic, works, label)
    local all,keys,seen={},{},{}
    for __,work in pairs(works) do
        local key=tostring(work.id).."\n"..tostring(work.path)
        keys[key]=true;seen[key]=true;all[#all+1]=work
    end
    for __,entry in ipairs(previous and previous.entries or {}) do
        local key=tostring(entry.work.id).."\n"..tostring(entry.work.path)
        if not seen[key] then all[#all+1]=entry.work end
    end
    return openReview(fanfic,all,false,nil,nil,nil,{kind="selection",keys=keys,label=label or _("Selected works")})
end

function M.showWork(fanfic, work)
    local works={}
    for __,entry in ipairs(previous and previous.entries or {}) do works[#works+1]=entry.work end
    local found=false
    for __,item in ipairs(works) do if tostring(item.id)==tostring(work.id) and item.path==work.path then found=true end end
    if not found then works[#works+1]=work end
    return openReview(fanfic, works, true, work)
end

function M.show(fanfic, requested_scope)
    local cancelled=false
    local cache_job
    local function close()
        cancelled=true
        if cache_job and cache_job.cancel then cache_job:cancel() end
    end
    local Config=require("ao3lib.core.config")
    local roots={}
    local function add(root) if type(root)=="string" and root~="" then roots[#roots+1]=root end end
    add(Config:readSetting("fanfic_folder_path"));add(require("apps/filemanager/filemanagerutil").getHomeFolder())
    local LocalCache=require("ao3lib.library.local_cache")
    local cached=LocalCache.get(roots)
    local session,menu,controls=openReview(fanfic,cached or {},false,nil,close,nil,requested_scope)
    controls.loading(not cached)
    cache_job=LocalCache.load(roots,function(works)
        if not cancelled then
            controls.loading(false)
            if works then controls.merge(works,true) end
        end
    end,function() return not cancelled end)
    if not cache_job then controls.loading(false) end
    return session,menu
end

-- Explicit maintenance action: scan locally first, then let the user review
-- availability and select replacements, including otherwise unchanged works.
function M.showNative(fanfic)
    local Config=require("ao3lib.core.config")
    local roots={Config:readSetting("fanfic_folder_path"),require("apps/filemanager/filemanagerutil").getHomeFolder()}
    local cancelled, scan=false,nil
    local dialog=InfoMessage:new{text=_("Finding converted AO3 EPUBs…\n\nTap or press Back to cancel."),
        dismiss_callback=function() cancelled=true;if scan then scan.cancel() end end}
    UI:show(dialog)
    scan=require("ao3lib.library.discovery").scan(roots,function(works,err)
        if cancelled then return end
        dialog.dismiss_callback=nil;UI:close(dialog)
        if err then UI:show(InfoMessage:new{text=tostring(err)});return end
        local converted={}
        for __,work in pairs(works) do
            if work._ao3_html_conversion then converted[#converted+1]=work end
        end
        openReview(fanfic,converted,false,nil,nil,true)
    end,function() return cancelled end,{read_only=true})
    return dialog
end

return M
