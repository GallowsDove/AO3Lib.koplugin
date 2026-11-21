-- Options are grouped by purpose; maintenance operations use real buttons.
local Config=require('ao3lib.core.config')
local UI=require('ui/uimanager')
local InputDialog=require('ui/widget/inputdialog')
local ButtonDialog=require('ui/widget/buttondialog')
local InfoMessage=require('ui/widget/infomessage')
local _=require('gettext')
local M={}
function M.show(owner,checkFilenameTemplate)
    local Pacing=require('ao3lib.updates.pacing')
    local groups={
        {title=_('Reading and display'),options={
            {text=_('Work view'),key='formatted_work_view',type='Bool',on=_('Formatted'),off=_('Information list')},
            {text=_('Downloaded works view'),key='downloaded_rendered_view',type='Bool',on=_('Rendered'),off=_('List'),
                value=function()
                    local saved=Config:readSetting('downloaded_view') or {}
                    return Config:readSetting('downloaded_rendered_view',saved.display=='rendered')
                end},
            {text=_('Formatted view text size'),key='work_view_font_size',type='Number',min=12,max=32,default=18,
                value=function() return require('ao3lib.ui.work_view').baseTextSize() end},
            {text=_('AO3 symbols'),key='ao3_eink_symbols',type='Bool',on=_('E-reader'),off=_('Original'),
                changed=function() require('ao3lib.bookshelf.badges').refresh() end},
            {text=_('Show adult work warning'),key='show_adult_warning',type='Bool'},
            {text=_('Chapter progress format'),key='show_current_chapter',type='Bool',on=_('First unread'),off=_('Unread count')},
        }},
        {title=_('Downloads'),options={
            {text=_('Download folder'),key='fanfic_folder_path',type='Folder'},
            {text=_('Download layout'),key='author_folders',type='Bool',on=_('Author/Title'),off=_('Flat')},
            {text=_('Flat filename template'),key='filename_template',type='String',default='%I',
                description=_('%I = work ID, %T = title, %A = author'),check=checkFilenameTemplate},
            {text=_('HTML download fallback'),key='html_download_fallback',type='Bool'},
        }},
        {title=_('Update checks'),options={
            {text=_('Delay between checks'),key=Pacing.key,type='Number',min=Pacing.min,max=Pacing.max,default=Pacing.default,
                unit=_('s'),title=_('Delay between checks (seconds)'),value=function() return Pacing.delay('check') end},
        }},
        {title=_('Advanced'),options={
            {text=_('AO3 URL'),key='AO3_domain',type='String',default='https://archiveofourown.org'},
        }},
    }
    local render
    local function current(option)
        if option.value then return option.value() end
        return Config:readSetting(option.key,option.default)
    end
    local function refresh(group)
        owner.menuWidget:switchItemTable(nil,render(group))
        owner.menuWidget:updateItems()
    end
    local function save(option,value,group,dialog)
        Config:saveSetting(option.key,value)
        if option.changed then option.changed() end
        if dialog then UI:close(dialog) end
        refresh(group)
    end
    local function edit(option,group)
        local value=current(option)
        if option.type=='Bool' then
            local dialog
            local function choice(label,state)
                return {{text=label,checked_func=function() return (not not value)==state end,
                    callback=function() save(option,state,group,dialog) end}}
            end
            dialog=ButtonDialog:new{title=option.text,buttons={
                choice(option.on or _('On'),true),choice(option.off or _('Off'),false),
            }}
            UI:show(dialog)
        elseif option.type=='Number' then
            UI:show(require('ui/widget/spinwidget'):new{
                title_text=option.title or option.text,value=value,value_min=option.min,value_max=option.max,value_step=1,
                default_value=option.default,callback=function(spin)
                    local number=tonumber(spin.value)
                    if not number or number~=number or number<option.min or number>option.max or number%1~=0 then
                        UI:show(InfoMessage:new{text=string.format(_('Enter a whole number from %d to %d.'),option.min,option.max)});return
                    end
                    save(option,number,group)
                end,
            })
        elseif option.type=='Folder' then
            local FM=require('apps/filemanager/filemanagerutil')
            FM.showChooseDialog(option.text,function(path) save(option,path,group) end,value,FM.getDefaultDir())
        else
            local dialog
            dialog=InputDialog:new{title=option.description or option.text,input=value or '',input_type='text',buttons={{
                {text=_('Cancel'),callback=function() UI:close(dialog) end},
                {text=_('Save'),is_enter_default=true,callback=function()
                    local input=dialog:getInputText()
                    if option.check then
                        local ok,err=option.check(input)
                        if not ok then UI:show(InfoMessage:new{text=err});return end
                    end
                    save(option,input,group,dialog)
                end},
            }}}
            UI:show(dialog);dialog:onShowKeyboard()
        end
    end
    render=function(group)
        local rows={}
        for __,option in ipairs(group.options) do
            local value=current(option)
            if option.type=='Bool' then value=value and (option.on or _('On')) or (option.off or _('Off')) end
            rows[#rows+1]={text=option.text,mandatory=tostring(value or '')..(option.unit and (' '..option.unit) or ''),
                callback=function() edit(option,group) end}
        end
        return rows
    end
    local rows={}
    for __,group in ipairs(groups) do
        rows[#rows+1]={text=group.title,callback=function()
            owner.menuWidget:GoDownInMenu(group.title,render(group))
        end}
    end
    rows[#rows+1]={text=_('Library maintenance…'),callback=function()
        local dialog
        local function action(text,callback)
            return {{text=text,callback=function() UI:close(dialog);callback() end}}
        end
        dialog=ButtonDialog:new{title=_('Library maintenance'),buttons={
            action(_('Rescan library'),function() require('ao3lib.ui.library_rescan').show() end),
            action(_('Organize downloaded works…'),function() require('ao3lib.ui.organizer').show(owner.fanfic) end),
            action(_('Replace converted EPUBs with native…'),function() require('ao3lib.ui.update_review').showNative(owner.fanfic) end),
        }}
        UI:show(dialog)
    end}
    owner.menuWidget:GoDownInMenu(_('Settings'),rows)
end
return M
