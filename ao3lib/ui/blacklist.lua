local Config=require('ao3lib.core.config')
local UI=require('ui/uimanager')
local ButtonDialog=require('ui/widget/buttondialog')
local InputDialog=require('ui/widget/inputdialog')
local Network=require('ao3lib.ao3.network')
local _=require('gettext')
local M={}
local kinds={{'Fandom',_('Fandom')},{'Character',_('Character')},
    {'Relationship',_('Relationship')},{'Freeform',_('Additional tag')},
    {'Rating',_('Rating')},{'Category',_('Category')},{'Warning',_('Archive warning')}}

function M.show(owner)
    local menu=owner.menuWidget
    local function entries() return require('ao3lib.library.blacklist').entries() end
    local render
    local function refresh() menu:switchItemTable(nil,render());menu:updateItems() end
    local function add(kind,name)
        if require('ao3lib.library.blacklist').add(kind,name) then refresh() end
    end
    local function search(kind)
        local input
        input=InputDialog:new{title=_('Search AO3 tags'),input_type='text',buttons={{
            {text=_('Cancel'),callback=function() UI:close(input) end},
            {text=_('Add exact text'),callback=function()
                local name=input:getInputText();UI:close(input);add(kind,name)
            end},
            {text=_('Search'),is_enter_default=true,callback=Network.wrap(function()
                local query=input:getInputText()
                if not query:find('%S') then return end
                local ok,results=owner.fanfic:searchForTags(query,kind)
                if not ok then return end
                UI:close(input)
                local buttons={}
                for _,tag in ipairs(results or {}) do
                    if tag.name then buttons[#buttons+1]={text=tag.name,callback=function()
                        menu:onReturn();add(kind,tag.name)
                    end} end
                end
                if #buttons==0 then
                    UI:show(require('ui/widget/infomessage'):new{text=_('No matching tags found.')});return
                end
                menu:GoDownInMenu(_('Select a tag'),buttons)
            end)},
        }}}
        UI:show(input);input:onShowKeyboard()
    end
    local function selectOption(kind,label)
        local choices={}
        for index,option in ipairs(require('ao3lib.library.blacklist').options[kind]) do
            local name=option.name
            choices[#choices+1]={text=_(name),callback=function() menu:onReturn();add(kind,name) end}
        end
        menu:GoDownInMenu(label,choices)
    end
    render=function()
        local rows={{text=_('Add tag…'),callback=function()
            local dialog,buttons
            buttons={}
            for _,kind in ipairs(kinds) do
                local value,label=kind[1],kind[2]
                buttons[#buttons+1]={{text=label,callback=function()
                    UI:close(dialog)
                    if require('ao3lib.library.blacklist').options[value] then selectOption(value,label) else search(value) end
                end}}
            end
            dialog=ButtonDialog:new{title=_('Tag type'),buttons=buttons};UI:show(dialog)
        end}}
        for index,entry in ipairs(entries()) do
            rows[#rows+1]={text=entry.name,mandatory=entry.type,callback=function()
                local dialog
                dialog=ButtonDialog:new{title=entry.name,buttons={{{text=_('Remove from blacklist'),callback=function()
                    local all={};for i,value in ipairs(entries()) do if i~=index then all[#all+1]=value end end
                    Config:saveSetting('tag_blacklist',all);UI:close(dialog);refresh()
                end},{text=_('Cancel'),callback=function() UI:close(dialog) end}}}}
                UI:show(dialog)
            end}
        end
        return rows
    end
    menu:GoDownInMenu(_('Tag blacklist'),render())
end
return M
