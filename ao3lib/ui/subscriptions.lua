local Network=require('ao3lib.ao3.network')
local UI=require('ui/uimanager')
local Client=require('ao3lib.ao3.client')
local Info=require('ui/widget/infomessage')
local Buttons=require('ui/widget/buttondialog')
local _=require('gettext')
local M={}
local function failure(result)
    if result.success then return false end
    UI:show(Info:new{text=result.error or _("Could not update subscriptions.")})
    return true
end
function M.manage(owner,kind,target,title)
    if Network.defer(function() M.manage(owner,kind,target,title) end) then return end
    local state=Client:getSubscriptionTarget(kind,target)
    if failure(state) then return end
    local dialog
    dialog=Buttons:new{title=title,buttons={{{text=state.subscription_id and _("Unsubscribe") or _("Subscribe"),
        callback=Network.wrap(function()
            UI:close(dialog)
            local result=Client:setSubscription(kind,state.target_id,state.subscription_id)
            if not failure(result) then UI:show(Info:new{text=state.subscription_id and _("Unsubscribed.") or _("Subscribed.")}) end
        end)}},{{text=_("Cancel"),callback=function() UI:close(dialog) end}}}}
    UI:show(dialog)
    return dialog
end
function M.series(owner,id,title,count)
    local dialog
    dialog=Buttons:new{title=title,buttons={
        {{text=_("Browse works"),callback=Network.wrap(function()
            UI:close(dialog)
            local ok,works,next_page=owner:getWorksFromSeries(id)
            if ok then
                if count then works.total=count end
                owner:onShowFanficBrowser(works,next_page,title)
            end
        end)}},
        {{text=_("Manage subscription"),callback=Network.wrap(function()
            UI:close(dialog);M.manage(owner,'Series',id,title)
        end)}},
        {{text=_("Cancel"),callback=function() UI:close(dialog) end}},
    }}
    UI:show(dialog)
    return dialog
end
function M.show(owner)
    if Network.defer(function() M.show(owner) end) then return end
    local page,kind=1,nil
    local window
    local load
    local function open(item)
        if item.kind=='User' then owner:showUserInfo(item.target,item.target)
        elseif item.kind=='Series' then M.series(owner,item.target,item.title)
        elseif item.kind=='Work' then
            local result=Client:getWorkMetadata(item.target)
            if not failure(result) then owner:onShowFanficBrowser({result.work_metadata,total=1},nil,_("Subscribed work")) end
        end
    end
    local function options(item)
        local dialog
        local buttons={}
        if item.target then buttons[#buttons+1]={{text=_("Open"),callback=Network.wrap(function() UI:close(dialog);open(item) end)}} end
        buttons[#buttons+1]={{text=_("Unsubscribe"),callback=function()
            UI:close(dialog)
            UI:show(require('ui/widget/confirmbox'):new{text=_("Unsubscribe from ")..item.title..'?',ok_text=_("Unsubscribe"),
                ok_callback=Network.wrap(function()
                    local result=Client:deleteSubscription(item.subscription_id)
                    if not failure(result) then load(page,kind) end
                end)})
        end}}
        buttons[#buttons+1]={{text=_("Cancel"),callback=function() UI:close(dialog) end}}
        dialog=Buttons:new{title=item.title,buttons=buttons};UI:show(dialog)
    end
    local function filter()
        local dialog
        local buttons={}
        for __,entry in ipairs{{_("All"),false},{_("Works"),'Work'},{_("Series"),'Series'},{_("Authors"),'User'}} do
            local label,value=entry[1],entry[2]
            buttons[#buttons+1]={{text=label,callback=Network.wrap(function() UI:close(dialog);load(1,value or nil) end)}}
        end
        buttons[#buttons+1]={{text=_("Cancel"),callback=function() UI:close(dialog) end}}
        dialog=Buttons:new{title=_("Subscription type"),buttons=buttons};UI:show(dialog)
    end
    load=function(requested,requested_kind)
        local result=Client:getSubscriptions(requested,requested_kind)
        if window and not window._ao3_navigation then return end
        if failure(result) then return end
        -- Keep the filter and visible position when returning from an item.
        local visible_page=window and requested==page and requested_kind==kind and window.page or 1
        -- Keep the current page intact when a refresh or page request fails.
        page,kind=requested,requested_kind
        local labels={Work=_("Works"),Series=_("Series"),User=_("Authors")}
        local items={{text=_("Type: ")..(labels[kind] or _("All")),callback=filter},
            {text=_("Refresh"),callback=Network.wrap(function() load(page,kind) end)}}
        for __,item in ipairs(result.subscriptions) do
            local label=({Work=_("Work"),Series=_("Series"),User=_("Author"),Unavailable=_("Unavailable")})[item.kind]
            items[#items+1]={text='['..label..'] '..item.title,callback=function() options(item) end}
        end
        if #result.subscriptions==0 then items[#items+1]={text=_("No subscriptions on this page."),enabled=false} end
        if page>1 then items[#items+1]={text=_("Previous page"),callback=Network.wrap(function() load(page-1,kind) end)} end
        if result.next_page then items[#items+1]={text=_("Next page"),callback=Network.wrap(function() load(result.next_page,kind) end)} end
        if window then window.item_table=items;window.page=visible_page;window:updateItems()
        else
            window=require('ui/widget/menu'):new(require('ao3lib.ui.widgets').menu{
                title=_("Subscriptions"),item_table=items,
                onMenuSelect=function(_,item) if item.callback then item.callback() end;return true end,
            })
            require('ao3lib.ui.navigation').bind(owner,window,{
                resume=function()
                    -- Navigation resumes the parent before closing its child.
                    -- Start after that close so background requests anchor to
                    -- the subscription list rather than the departing page.
                    UI:nextTick(Network.wrap(function()
                        local frames=owner._ao3_navigation or {}
                        if window._ao3_navigation and frames[#frames]==window._ao3_navigation then
                            load(page,kind)
                        end
                    end))
                end,
            })
            UI:show(window)
        end
    end
    load(page,kind)
    return window
end
return M
