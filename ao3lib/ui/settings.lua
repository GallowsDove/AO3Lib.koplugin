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
            {text=_('Work view controls…'),type='Action',callback=function() require('ao3lib.ui.work_view_help').show() end},
            {text=_('Downloaded works view'),key='downloaded_rendered_view',type='Bool',on=_('Rendered'),off=_('List'),
                value=function()
                    local saved=Config:readSetting('downloaded_view') or {}
                    return Config:readSetting('downloaded_rendered_view',saved.display=='rendered')
                end},
            {text=_('Formatted view text size'),key='work_view_font_size',type='Number',min=12,max=32,default=20,
                value=function() return require('ao3lib.ui.work_view').baseTextSize() end},
            {text=_('AO3 symbols'),key='ao3_symbol_style',type='Choice',
                choices={{'original',_('Original')},{'eink',_('E-reader')},
                    {'zerafina',_('Zerafina (color)')},{'zerafina_eink',_('Zerafina (E-reader)')}},
                value=function() return require('ao3lib.bookshelf.badges').style() end,
                changed=function() require('ao3lib.bookshelf.badges').refresh() end},
            {text=_('Show adult work warning'),key='show_adult_warning',type='Bool'},
            {text=_('Chapter progress format'),key='show_current_chapter',type='Bool',on=_('First unread'),off=_('Unread count')},
        }},
        {title=_('Blacklist'),options={
            {text=_('Enable tag blacklist'),key='tag_blacklist_enabled',type='Bool',default=true},
            {text=_('Manage tag blacklist…'),type='Action',callback=function() require('ao3lib.ui.blacklist').show(owner) end},
            {text=_('Manage muted AO3 users…'),type='Action',callback=function() require('ao3lib.ui.muted_users').show(owner) end},
        }},
        {title=_('Downloads'),options={
            {text=_('Download folder'),key='fanfic_folder_path',type='Folder'},
            {text=_('Download layout template'),key='download_layout_template',type='String',default='%A/%T',check=checkFilenameTemplate},
            {text=_('Download layout tokens…'),type='Action',callback=function()
                UI:show(require('ui/widget/textviewer'):new{title=_('Download layout tokens'),text=table.concat({
                    _('Use / between folders. The .epub extension is added automatically.'),
                    '',
                    _('%A — First author (account when available)'),
                    _('%B — All authors'),
                    _('%T — Title'),
                    _('%I — AO3 work ID'),
                    _('%F — Fandom; multiple fandoms use Crossover'),
                    _('%L — Language'),
                    _('%Y — Published year'),
                    _('%S — Work status'),
                    _('%R — First listed series; No series when absent'),
                    _('%t — Title with underscores'),
                    _('%a — All authors with underscores'),
                    '',
                    _('Example: %F/%A/%T'),
                },'\n')})
            end},
            {text=_('HTML download fallback'),key='html_download_fallback',type='Bool'},
        }},
        {title=_('Update checks'),options={
            {text=_('Delay between checks'),key=Pacing.key,type='Number',min=Pacing.min,max=Pacing.max,default=Pacing.default,
                unit=_('s'),title=_('Delay between checks (seconds)'),value=function() return Pacing.delay('check') end},
            {text=_('Show check progress overlay'),key='update_progress_overlay',type='Bool',default=true,
                changed=function() local overlay=package.loaded['ao3lib.ui.update_overlay'];if overlay then overlay.refresh() end end},
            {text=_('Progress overlay position'),key='update_progress_corner',type='Choice',default='top_right',
                choices={{'top_left',_('Top left')},{'top_right',_('Top right')}},
                changed=function() local overlay=package.loaded['ao3lib.ui.update_overlay'];if overlay then overlay.refresh() end end},
        }},
        {title=_('Advanced'),options={
            {text=_('AO3 URL'),key='AO3_domain',type='String',default='https://archiveofourown.org'},
        }},
    }
    local render
    local function current(option)
        if option.type=='Action' then return nil end
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
        if option.type=='Action' then return option.callback() end
        local value=current(option)
        if option.type=='Choice' then
            local dialog
            local buttons={}
            for _,choice in ipairs(option.choices) do
                local key=choice[1]
                buttons[#buttons+1]={{text=choice[2],checked_func=function() return value==key end,
                    no_refresh_checkmark=true,callback=function() save(option,key,group,dialog) end}}
            end
            dialog=ButtonDialog:new{title=option.text,buttons=buttons};UI:show(dialog)
        elseif option.type=='Bool' then
            local dialog
            local function choice(label,state)
                return {{text=label,checked_func=function() return (not not value)==state end,
                    no_refresh_checkmark=true,
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
            if option.type=='Choice' then
                for _,choice in ipairs(option.choices) do if choice[1]==value then value=choice[2];break end end
            end
            if option.type=='Bool' then value=value and (option.on or _('On')) or (option.off or _('Off')) end
            rows[#rows+1]={text=option.text,mandatory=option.type~='Action' and (tostring(value or '')..(option.unit and (' '..option.unit) or '')) or nil,
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
