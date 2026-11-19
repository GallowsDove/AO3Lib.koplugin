local UI = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local Network = require("ao3lib.ao3.network")
local Updates = require("ao3lib.updates.checks")
local _ = require("gettext")
local M = {}
local previous
local function eligible(entry) return entry.remote and (entry.status=="update" or entry.status=="review" or entry.status=="error") end
local function statusLabel(entry)
    local labels={unchecked=_("Not checked"), update=_("Update available"), review=_("Review needed"),
        current=_("Up to date"), updated=_("Updated"), error=_("Failed"),
        unavailable=_("Unavailable or restricted"), state_error=_("EPUB updated; reading-state save failed")}
    local text=labels[entry.status] or entry.status
    if entry.remote and entry.status~="updated" then
        text=text .. " — " .. (entry.local_work.chapters or "?") .. " → " .. (entry.remote.chapters or "?")
    end
    return text
end
local function describe(entry)
    local work=entry.work
    return (work.title or tostring(work.id)) .. "\n" .. (work.author or "") .. "\n\n"
        .. statusLabel(entry) .. "\n\n"
        .. table.concat(entry.changes or {},"\n")
        .. (entry.error and ("\n\n" .. entry.error) or "")
        .. "\n\n" .. tostring(work.path)
end

local function openReview(fanfic, works, check_now, focused_work)
    local session=Updates.new(works,previous)
    previous=session
    local scope={}
    if focused_work then
        for _,entry in ipairs(session.entries) do
            if tostring(entry.work.id)==tostring(focused_work.id) and entry.work.path==focused_work.path then scope[entry]=true end
        end
    else for _,entry in ipairs(session.entries) do scope[entry]=true end end
    local function scopeEntries()
        local entries={};for _,entry in ipairs(session.entries) do if scope[entry] then entries[#entries+1]=entry end end
        return entries
    end
    local menu, refresh
    local show_all=false
    local screen_closed=false
    local function details(entry)
        UI:show(require("ao3lib.ui.navigation").bind(fanfic,
            TextViewer:new{title=_("Work update details"), text=describe(entry)}))
    end
    local function run(operation, targets)
        if #targets==0 then return end
        Network.run(function()
            if session.closed or session.busy then return end
            local started, err=session:run(operation, targets, refresh)
            if not started and err then UI:show(InfoMessage:new{text=err}) end
        end)
    end
    refresh=function()
        if screen_closed then return end
        local checked, available, failed, selected, unsaved=0,0,0,0,0
        local pending, retries, selections, all_checks={},{},{},{}
        for __, entry in ipairs(session.entries) do
            if scope[entry] then
                if entry.status~="state_error" then all_checks[#all_checks+1]=entry end
                if entry.status~="unchecked" then checked=checked+1 else pending[#pending+1]=entry end
                if entry.status=="update" then available=available+1 end
                if entry.status=="error" or entry.status=="unavailable" then
                    failed=failed+1; retries[#retries+1]=entry
                elseif entry.status=="state_error" then
                    failed=failed+1; unsaved=unsaved+1
                end
                if entry.selected and eligible(entry) then selected=selected+1; selections[#selections+1]=entry end
            end
        end
        local rows={{text=string.format(_("%d/%d checked · %d updates · %d failed"),checked,#scopeEntries(),available,failed),enabled=false}}
        if session.pause_reason then
            rows[#rows+1]={text=_("Requests paused: ") .. session.pause_reason, enabled=false}
        end
        if session.busy then
            rows[#rows+1]={text=string.format(_("%s: %d/%d — Stop"),
                session.operation=="check" and _("Checking") or _("Updating"),session.done,session.total),
                callback=function() session:stop(); refresh() end}
        else
            rows[#rows+1]={text=checked==0 and _("Check for updates") or _("Continue checking unchecked works"),
                enabled=#pending>0, callback=function() run("check",pending) end}
        end
        rows[#rows+1]={text=string.format(_("Update selected (%d)"),selected),enabled=selected>0 and not session.busy,
            callback=function() run("update",selections) end}
        rows[#rows+1]={text=_("Select all available updates"),enabled=available>0 and not session.busy,
            callback=function()
                for __, entry in ipairs(session.entries) do if entry.status=="update" then entry.selected=true end end
                refresh()
            end}
        rows[#rows+1]={text=_("Clear selection"),enabled=selected>0 and not session.busy,
            callback=function() for __, entry in ipairs(session.entries) do entry.selected=false end; refresh() end}
        rows[#rows+1]={text=string.format(_("Retry failed checks (%d)"),#retries),enabled=#retries>0 and not session.busy,
            callback=function() run("check",retries) end}
        rows[#rows+1]={text=_("Check all works again"),enabled=not session.busy and #all_checks>0,
            callback=function() run("check",all_checks) end}
        if unsaved>0 then
            rows[#rows+1]={text=_("Retry saving AO3 reading state"),enabled=not session.busy,
                callback=function()
                    local saved,err=Updates.retrySave(session)
                    if not saved then UI:show(InfoMessage:new{text=tostring(err)}) end
                    refresh()
                end}
        end
        rows[#rows+1]={text=show_all and _("Show updates and failures only") or _("Show all works"),
            callback=function() show_all=not show_all; refresh() end}
        rows[#rows+1]={text=_("Tap a work to select it; hold for details."), enabled=false}
        for __, entry in ipairs(session.entries) do
            if show_all or (entry.status~="current" and entry.status~="unchecked") then
                local prefix=eligible(entry) and (entry.selected and "☑ " or "☐ ") or ""
                rows[#rows+1]={text=prefix .. (entry.work.title or tostring(entry.work.id)) .. " — " .. statusLabel(entry),
                    callback=function()
                        if eligible(entry) and not session.busy then entry.selected=not entry.selected; refresh()
                        else details(entry) end
                    end,
                    hold_callback=function() details(entry) end}
            end
        end
        menu.item_table=rows
        menu:updateItems()
        UI:setDirty(menu,"ui")
    end
    local function close()
        if screen_closed then return end
        screen_closed=true
        if fanfic.ui and fanfic.ui.file_chooser then pcall(function() fanfic.ui.file_chooser:refreshPath() end) end
    end
    menu=Menu:new(require("ao3lib.ui.widgets").menu{title=_("Downloaded work updates"), item_table={}, close_callback=close,
        onMenuSelect=function(_,item)
            if item.enabled~=false and item.callback then item.callback() end
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
    if check_now then run("check", scopeEntries()) end
    return session,menu
end

function M.showWork(fanfic, work)
    local works={}
    for _,entry in ipairs(previous and previous.entries or {}) do works[#works+1]=entry.work end
    local found=false
    for _,item in ipairs(works) do if tostring(item.id)==tostring(work.id) and item.path==work.path then found=true end end
    if not found then works[#works+1]=work end
    return openReview(fanfic, works, true, work)
end

function M.show(fanfic)
    local cancelled=false
    local scanning=InfoMessage:new{text=_("Scanning downloaded AO3 EPUBs…"),
        dismiss_callback=function() cancelled=true end}
    UI:show(scanning)
    local Config=require("ao3lib.core.config")
    local roots={Config:readSetting("fanfic_folder_path"),require("apps/filemanager/filemanagerutil").getHomeFolder()}
    require("ao3lib.library.discovery").scan(roots,function(works,err)
        scanning.dismiss_callback=nil
        UI:close(scanning)
        if cancelled then return end
        if err then UI:show(InfoMessage:new{text=_("Could not finish the library scan: ")..err});return end
        if next(works)==nil then UI:show(InfoMessage:new{text=_("No downloaded AO3 works found.")}); return end
        openReview(fanfic,works)
    end,function() return cancelled end)
end

return M
