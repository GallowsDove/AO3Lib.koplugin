local UI=require('ui/uimanager')
local Network=require('ao3lib.ao3.network')
local Client=require('ao3lib.ao3.client')
local Info=require('ui/widget/infomessage')
local _=require('gettext')
local M={}
-- In-memory drafts survive closing/reopening a composer in this session.
local drafts={}
local function errorMessage(result)
    UI:show(Info:new{text=result.error or _("Could not load comments.")})
end
function M.compose(owner,work,options)
    options=options or {}
    local key=table.concat({tostring(work.id),tostring(options.chapter_id or ''),tostring(options.parent_id or '')},':')
    local dialog,busy,sent,dismissed,moved
    local function saveDraft()
        if not sent and not moved then drafts[key]=dialog:getInputText() end
    end
    local function chooseChapter()
        Network.run(function()
            if dismissed or busy then return end
            local chapters=work.chapter_data
            if not chapters or #chapters==0 then
                local result=Client:getWorkMetadata(work.id)
                if not result.success then errorMessage(result);return end
                chapters=result.work_metadata.chapterData or result.work_metadata.chapter_data or {}
                work.chapter_data=chapters
            end
            if dismissed then return end
            local chooser
            local function selectChapter(id,name)
                local input=dialog:getInputText()
                local selected=require('ao3lib.core.table').shallowCopy(options)
                selected.chapter_id,selected.chapter_name,selected.initial_input=id,name,input
                moved=true;drafts[key]=nil
                UI:close(chooser);UI:close(dialog)
                M.compose(owner,work,selected)
            end
            local buttons={{{text=_("Latest posted chapter"),callback=function() selectChapter(nil,nil) end}}}
            for i,chapter in ipairs(chapters) do
                local id,name=chapter.id,chapter.name or string.format(_("Chapter %d"),i)
                if id then buttons[#buttons+1]={{text=name,callback=function() selectChapter(id,name) end}} end
            end
            buttons[#buttons+1]={{text=_("Cancel"),callback=function() UI:close(chooser) end}}
            chooser=require('ui/widget/buttondialog'):new{title=_("Post comment on"),buttons=buttons}
            UI:show(chooser)
        end)
    end
    local target=options.chapter_name or (options.chapter_id and _("Selected chapter")) or _("Latest posted chapter")
    dialog=require('ui/widget/inputdialog'):new{
        title=options.parent_id and _("Reply to ")..(options.author or _("comment")) or _("Write comment"),
        description=(work.title or '')..(not options.parent_id and ('\n'.._('Posting to: ')..target) or ''),
        input=options.initial_input or drafts[key] or '',input_type='text',allow_newline=true,
        buttons={{{text=_("Cancel"),id='close',callback=function() dismissed=true;saveDraft();UI:close(dialog) end},
            {text=_("Post comment"),callback=function()
                if busy then return end
                local content=dialog:getInputText()
                if not content:find('%S') then errorMessage{error=_("Enter a comment first.")};return end
                drafts[key]=content;busy=true
                Network.run(function()
                    if dismissed then busy=false;return end
                    local ok,result=pcall(Client.commentOnWork,Client,content,work.id,options.chapter_id,options.parent_id)
                    busy=false
                    if not ok then error(result,0) end
                    if not result.success then errorMessage(result);return end
                    sent=true;drafts[key]=nil
                    UI:close(dialog)
                    if options.on_post then options.on_post(result) end
                    UI:show(Info:new{text=_("Comment posted. AO3 may hold it for moderation.")})
                end)
            end}},
            not options.parent_id and {{text=_("Chapter…"),callback=chooseChapter}} or nil},
    }
    local closed=dialog.onCloseWidget
    dialog.onCloseWidget=function(self,...)
        dismissed=true
        saveDraft()
        if closed then return closed(self,...) end
    end
    UI:show(dialog);dialog:onShowKeyboard()
    return dialog
end
function M.show(owner,work,options)
    options=options or {}
    if Network.defer(function() M.show(owner,work,options) end) then return end
    owner=owner or {menu_stack={}}
    local function compose(state,comment)
        local chapter_name
        for _,c in ipairs(work.chapter_data or {}) do
            if tostring(c.id)==tostring(state.chapter) then chapter_name=c.name;break end
        end
        M.compose(owner,work,{chapter_id=state.chapter,chapter_name=chapter_name,
            parent_id=comment and comment.id,author=comment and (comment.author or comment.heading),
            on_post=function() if not state.closed then state:refresh() end end})
    end
    local function scope(state)
        local dialog
        local buttons={{{text=_("All chapters"),callback=function() UI:close(dialog);state:load(1,nil) end}}}
        for i,chapter in ipairs(work.chapter_data or {}) do
            local id,name=chapter.id,chapter.name or string.format(_("Chapter %d"),i)
            if id then buttons[#buttons+1]={{text=name,callback=function() UI:close(dialog);state:load(1,id) end}} end
        end
        buttons[#buttons+1]={{text=_("Cancel"),callback=function() UI:close(dialog) end}}
        dialog=require('ui/widget/buttondialog'):new{title=_("Comments for"),buttons=buttons};UI:show(dialog)
    end
    local function more(state)
        local dialog
        local buttons={}
        local comment=state:current()
        if comment and (comment.id or comment.thread_id) then
            buttons[#buttons+1]={{text=_("View thread"),callback=Network.wrap(function()
                UI:close(dialog)
                M.show(owner,work,{chapter_id=state.chapter,thread_id=comment.thread_id or comment.id})
            end)}}
        end
        buttons[#buttons+1]={{text=_("Refresh"),callback=function() UI:close(dialog);state:refresh() end}}
        if not options.thread_id and #(work.chapter_data or {})>1 then
            buttons[#buttons+1]={{text=_("Comments for…"),callback=function() UI:close(dialog);scope(state) end}}
        end
        buttons[#buttons+1]={{text=_("Cancel"),callback=function() UI:close(dialog) end}}
        dialog=require('ui/widget/buttondialog'):new{title=_("Comments"),buttons=buttons};UI:show(dialog)
    end
    return require('ao3lib.ui.comment_view').show(owner,{
        title=options.thread_id and _("Comment thread") or _("Comments: ")..(work.title or tostring(work.id)),
        chapter_id=options.chapter_id,network=Network.run,error=errorMessage,
        fetch=function(page,chapter) return Client:getComments(work.id,chapter,page,options.thread_id) end,
        compose=compose,more=more,
        author=Network.wrap(function(comment) owner:showUserInfo(comment.username,comment.pseud) end),
        thread=function(comment,state)
            M.show(owner,work,{chapter_id=state.chapter,thread_id=comment.thread_id})
        end,
    })
end
return M
