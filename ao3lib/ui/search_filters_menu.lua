local Network = require("ao3lib.ao3.network")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local FanficBrowser = require("ao3lib.ui.work_browser")
local Config = require("ao3lib.core.config")
local UIManager = require("ui/uimanager")
local util = require("util")
local logger = require("logger")
local _ = require("gettext")

function util.contains(tableValue, value, comparisonFunction)
    logger.dbg(tableValue)
    if comparisonFunction == nil then
        comparisonFunction = function(v1, v2)
            return v1 == v2
        end
    end

    for _, v in pairs(tableValue) do
        if comparisonFunction(v, value) then
            return true
        end
    end
    return false
end

function util.remove(tableValue, value)
    for i, v in ipairs(tableValue) do
        if v == value then
            table.remove(tableValue, i)
            break
        end
    end
end

local deepcopy = require("ao3lib.core.table").deepCopy

local CustomFilterMenu = {}

function CustomFilterMenu:goBack()
    self.menuWidget:onReturn()
    self.menuWidget:updateItems(1)
end

function CustomFilterMenu:checkboxWidget(title, options, settingValue)
    local excludeSettingValue = "exclude_" .. settingValue -- Corrected typo
    logger.dbg("exclude setting value:" .. excludeSettingValue)
    if self.filter[settingValue] == nil then
        self.filter[settingValue] = {}
    end
    if self.filter[excludeSettingValue] == nil then
        self.filter[excludeSettingValue] = {}
    end
    self.menuWidget.lock_return = true
    local menu_items = {}
    for __, option in pairs(options) do
        table.insert(menu_items, {
            text_func = function()
                local show_checked = util.contains(self.filter[settingValue], option.value)
                local show_crossed = util.contains(self.filter[excludeSettingValue], option.value)
                if show_checked then
                    return "✓ " .. option.text
                elseif show_crossed then
                    return "× " .. option.text
                else
                    return option.text
                end
            end,
            callback = function()
                if util.contains(self.filter[settingValue], option.value) then
                    util.remove(self.filter[settingValue], option.value)
                    table.insert(self.filter[excludeSettingValue], option.value)
                elseif util.contains(self.filter[excludeSettingValue], option.value) then
                    util.remove(self.filter[excludeSettingValue], option.value)
                else
                    table.insert(self.filter[settingValue], option.value)
                end
                self.menuWidget:updateItems()
            end,
        })
    end

    table.insert(menu_items, {
        text = "← Back to filters",
        callback = function()
            if #self.filter[settingValue] == 0 then
                self.filter[settingValue] = nil
            end
            if #self.filter[excludeSettingValue] == 0 then
                self.filter[excludeSettingValue] = nil
            end
            self.menuWidget.lock_return = false
            self:goBack()
            self.menuWidget:updateItems()
        end,
    })

    self.menuWidget:GoDownInMenu(title, menu_items, "Tap to add to add to filter, and again for exclude filter")
end

function CustomFilterMenu:textboxWidget(title, setting)
    local inputDialog
    inputDialog = InputDialog:new({
        title = title,
        input = self.filter[setting] or "",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(inputDialog)
                    end,
                },
                {
                    text = _("Enter"),
                    is_enter_default = true,
                    callback = function()
                        local value = inputDialog:getInputText()
                        if value == "" then
                            value = nil
                        end
                        self.filter[setting] = value
                        self.menuWidget:updateItems()
                        UIManager:close(inputDialog)
                    end,
                },
            },
        },
    })
    UIManager:show(inputDialog)
    inputDialog:onShowKeyboard()
end

function CustomFilterMenu:selectionWidget(title, options, setting)
    self.menuWidget.lock_return = true
    local menu_items = {}
    for __, option in pairs(options) do
        table.insert(menu_items, {
            text = option.text,
            callback = function()
                self.filter[setting] = option.value
                self.menuWidget.lock_return = false
                self:goBack()
            end,
        })
    end
    self.menuWidget:GoDownInMenu(title, menu_items, "Select option to filter by")
end

function CustomFilterMenu:tagSelectionWidget(title, tagCatagoryForSearch, settingValue)
    self.menuWidget.lock_return = true
    local excludeSettingValue = "exclude_" .. settingValue

    if self.filter[settingValue] == nil then
        self.filter[settingValue] = {}
    end
    if self.filter[excludeSettingValue] == nil then
        self.filter[excludeSettingValue] = {}
    end

    local function refresh()
        local menu_items = {}
        table.insert(menu_items, {
            text = "← Back to filters menu",
            callback = function()
                if #self.filter[settingValue] == 0 then
                    self.filter[settingValue] = nil
                end
                if #self.filter[excludeSettingValue] == 0 then
                    self.filter[excludeSettingValue] = nil
                end

                self.menuWidget.lock_return = false
                self:goBack()
            end,
        })

        if settingValue=="additional_tags" or settingValue=="fandom_names" then
            table.insert(menu_items,{
                text="Enter tag by name",
                callback=function()
                    local dialog
                    dialog=InputDialog:new{title=title,input="",input_type="text",buttons={{
                        {text=_("Cancel"),callback=function() UIManager:close(dialog) end},
                        {text=_("Exclude"),callback=function()
                            local value=(dialog:getInputText() or ""):match("^%s*(.-)%s*$")
                            if value~="" then
                                util.remove(self.filter[settingValue],value)
                                if not util.contains(self.filter[excludeSettingValue],value) then table.insert(self.filter[excludeSettingValue],value) end
                            end
                            self.menuWidget.item_table=refresh();self.menuWidget:updateItems();UIManager:close(dialog)
                        end},
                        {text=_("Add"),callback=function()
                            local value=(dialog:getInputText() or ""):match("^%s*(.-)%s*$")
                            if value~="" then
                                util.remove(self.filter[excludeSettingValue],value)
                                if not util.contains(self.filter[settingValue],value) then table.insert(self.filter[settingValue],value) end
                            end
                            self.menuWidget.item_table=refresh();self.menuWidget:updateItems();UIManager:close(dialog)
                        end},
                    }}}
                    UIManager:show(dialog);dialog:onShowKeyboard()
                end,
            })
        end

        table.insert(menu_items, {
            text = "\u{f002} Search for tags to add to filter",
            callback = function()
                local inputDialog
                inputDialog = InputDialog:new({
                    title = title,
                    input = "",
                    input_type = "text",
                    buttons = {
                        {
                            {
                                text = _("Cancel"),
                                callback = function()
                                    UIManager:close(inputDialog)
                                end,
                            },
                            {
                                text = _("Search"),
                                is_enter_default = true,
                                callback = Network.wrap(function()
                                    local value = inputDialog:getInputText()
                                    if value == "" then
                                        return
                                    end
                                    local success, tagSearchResults = self.fanfic:searchForTags(value, tagCatagoryForSearch)
                                    if success then
                                        self:tagSearchSelectionWidget(
                                            "Tap on character tags to add to filter",
                                            tagSearchResults,
                                            settingValue,
                                            refresh
                                        )
                                        UIManager:close(inputDialog)
                                    end
                                end),
                            },
                        },
                    },
                })
                UIManager:show(inputDialog)
                inputDialog:onShowKeyboard()
            end,
        })

        table.insert(menu_items,{
            text=_("AO3 favorite tags"),callback=Network.wrap(function()
                local result=require('ao3lib.ao3.client'):getFavoriteTags()
                if not result.success then UIManager:show(InfoMessage:new{text=result.error});return end
                require('ao3lib.ao3.favorite_cache').remember(result)
                local rows={}
                for __,tag in ipairs(result.tags) do
                    local name=tag.name
                    rows[#rows+1]={text=name,callback=function()
                        util.remove(self.filter[excludeSettingValue],name)
                        if not util.contains(self.filter[settingValue],name) then table.insert(self.filter[settingValue],name) end
                        local paths=self.menuWidget.paths
                        if paths and paths[#paths] then paths[#paths].items=refresh() end
                        self.menuWidget:updateItems()
                    end}
                end
                if #rows==0 then rows[1]={text=_("No favorite tags on AO3."),enabled=false} end
                self.menuWidget:GoDownInMenu(_("AO3 favorite tags"),rows,_("All favorite tag types"))
            end),
        })

        local function addSelectedTags(source, destination, prefix, move_label)
            for __, tag in ipairs(self.filter[source]) do
                table.insert(menu_items, {
                    text = prefix .. tag,
                    value = tag,
                    callback = function()
                        local optionsDialog
                        optionsDialog = ButtonDialog:new{buttons={
                            {{text=move_label, callback=function()
                                util.remove(self.filter[source], tag)
                                if not util.contains(self.filter[destination], tag) then
                                    table.insert(self.filter[destination], tag)
                                end
                                self.menuWidget.item_table=refresh()
                                self.menuWidget:updateItems(1)
                                UIManager:close(optionsDialog)
                            end}},
                            {{text=_("Remove tag"), callback=function()
                                util.remove(self.filter[source], tag)
                                self.menuWidget.item_table=refresh()
                                self.menuWidget:updateItems(1)
                                UIManager:close(optionsDialog)
                            end}},
                            {{text=_("Cancel"), callback=function() UIManager:close(optionsDialog) end}},
                        }}
                        UIManager:show(optionsDialog)
                    end,
                })
            end
        end
        addSelectedTags(settingValue, excludeSettingValue, "✓ ", _("Move to exclude filter"))
        addSelectedTags(excludeSettingValue, settingValue, "× ", _("Move to include filter"))

        return menu_items
    end

    self.menuWidget:GoDownInMenu(title, refresh())
end

function CustomFilterMenu:tagSearchSelectionWidget(title, tagSearchResults, settingValue, refreshCallback)
    local menu_items = {}
    local excludeSettingValue = "exclude_" .. settingValue

    table.insert(menu_items, {
        text = "← Exit search",
        callback = function()
            self.menuWidget.lock_return = false
            self:goBack()
            self.menuWidget.lock_return = true
            self.menuWidget.item_table = refreshCallback()
            self.menuWidget:updateItems()
        end,
    })

    for __, tag in pairs(tagSearchResults) do
        table.insert(menu_items, {
            hold_callback = function()
                local kinds={fandom_names='Fandom',characters='Character',relationships='Relationship',additional_tags='Freeform'}
                require('ao3lib.ui.tag_actions').show(self.fanfic,kinds[settingValue],tag.name)
            end,
            text_func = function()
                local show_checked = util.contains(self.filter[settingValue], tag.name)
                local show_cross = util.contains(self.filter[excludeSettingValue], tag.name)
                if show_checked then
                    return "✓ " .. tag.name
                elseif show_cross then
                    return "× " .. tag.name
                else
                    return tag.name
                end
            end,
            callback = function()
                if util.contains(self.filter[settingValue], tag.name) then
                    util.remove(self.filter[settingValue], tag.name)
                    table.insert(self.filter[excludeSettingValue], tag.name)
                elseif util.contains(self.filter[excludeSettingValue], tag.name) then
                    util.remove(self.filter[excludeSettingValue], tag.name)
                else
                    table.insert(self.filter[settingValue], tag.name)
                end
                local paths=self.menuWidget.paths
                if paths and paths[#paths] then paths[#paths].items=refreshCallback() end
                self.menuWidget:updateItems()
            end,
        })
    end

    self.menuWidget:GoDownInMenu(title, menu_items, "Tap tag to add to filter, again for exclude filter")
end

function CustomFilterMenu:filterMenuRows()
    return {
        {text="Work Info filters \u{23F5}", callback=function() self:WorkInfoSubmenu() end},
        {text="Work Tags filters \u{23F5}", callback=function() self:WorkTagsSubmenu() end},
        {text="Work Stats filters \u{23F5}", callback=function() self:WorkStatSubmenu() end},
        {text="Search Order filters \u{23F5}", callback=function() self:WorkOrderSubmenu() end},
        {text="\u{2193} Save current filter", callback=function() self:SaveFilters() end},
        {text="\u{f002} Execute Search", callback=function() self:executeSearch() end},
    }
end
function CustomFilterMenu:FilterCrafter()
    self.filter={}
    self.current_filter=nil
    self.menuWidget:GoDownInMenu("Create filter",self:filterMenuRows())
end

function CustomFilterMenu:UpdateFilterCrafter(filter)
    local normalized=require("ao3lib.ui.saved_searches").normalize(filter.parameters)
    self.filter=deepcopy(normalized)
    self.current_filter=filter
    local filterMenuOptions=self:filterMenuRows()
    if filter.title and filter.title~="" then
        table.remove(filterMenuOptions,5)
        table.insert(filterMenuOptions,5,{text="\u{2193} Save as current filter",callback=function()
            local dialog
            dialog=ButtonDialog:new{title="Do you want to overwrite the filter '"..filter.title.."' ?",buttons={{
                {text="Cancel",callback=function() UIManager:close(dialog) end},
                {text="Overwrite",callback=function() UIManager:close(dialog);self:OverwriteFilter(filter) end},
            }}}
            UIManager:show(dialog)
        end})
        table.insert(filterMenuOptions,6,{text="\u{2193} Save as new filter",callback=function() self:SaveFilters() end})
        self.menuWidget:GoDownInMenu("Edit filter: "..filter.title,filterMenuOptions)
    else
        self.menuWidget:GoDownInMenu("Create filter",filterMenuOptions)
    end
end

function CustomFilterMenu:OverwriteFilter(filter)
    local filters=require("ao3lib.ui.saved_searches").saved(Config)
    filters[filter.title]={title=filter.title,parameters=deepcopy(self.filter)}
    Config:saveSetting("saved_filters",filters)
    UIManager:show(InfoMessage:new{text='Filter "'..filter.title..'" has been overwritten'})
    self.menuWidget:updateMenuBack(1,nil,self.refreshSearchRows(),nil)
end

function CustomFilterMenu:SaveFilters()
    local dialog
    dialog=InputDialog:new{title="Enter title to save filter under",input="",input_type="text",buttons={{
        {text=_("Cancel"),callback=function() UIManager:close(dialog) end},
        {text=_("Save"),is_enter_default=true,callback=function()
            local title=dialog:getInputText()
            if not title or title=="" then return end
            local filters=require("ao3lib.ui.saved_searches").saved(Config)
            if filters[title] then
                UIManager:show(InfoMessage:new{text='Title "'..title..'" is already being used, enter different title'});return
            end
            local saved={title=title,parameters=deepcopy(self.filter)}
            filters[title]=saved;Config:saveSetting("saved_filters",filters)
            UIManager:show(InfoMessage:new{text='Filter "'..title..'" has been saved'})
            UIManager:close(dialog)
            self.menuWidget:updateMenuBack(1,nil,self.refreshSearchRows(),nil)
        end},
    }}}
    UIManager:show(dialog);dialog:onShowKeyboard()
end

function CustomFilterMenu:WorkTagsSubmenu()
    local menu_items = {
        {
            text_func = function()
                local fandomStrings = {}

                if self.filter.fandom_names then
                    for __, fandom in pairs(self.filter.fandom_names) do
                        table.insert(fandomStrings, fandom)
                    end
                end

                if self.filter.exclude_fandom_names then
                    for __, fandom in pairs(self.filter.exclude_fandom_names) do
                        table.insert(fandomStrings, "-" .. fandom)
                    end
                end
                return "Fandoms: " .. ((#fandomStrings > 0) and table.concat(fandomStrings, ", ") or "Any")
            end,
            callback = function()
                self:selectedFandoms()
            end,
        },
        {
            text_func = function()
                local key_to_rating = {
                    ["9"] = "not rated",
                    ["10"] = "general audiences",
                    ["11"] = "teen and up audiences",
                    ["12"] = "mature",
                    ["13"] = "explicit",
                }

                return "Rating: " .. (key_to_rating[self.filter.rating] or "Any")
            end,
            callback = function()
                self:selectRating()
            end,
        },
        {
            text_func = function()
                local key_to_warnings = {
                    ["14"] = "Creator Choose Not To Use Archive Warnings",
                    ["17"] = "Graphic Depictions Of Violence",
                    ["18"] = "Major Character Death",
                    ["16"] = "No Archive Warnings Apply",
                    ["19"] = "Rape/Non-Con",
                    ["20"] = "Underage Sex",
                }
                local warningStrings = {}
                if self.filter.warnings then
                    for __, warning in pairs(self.filter.warnings) do
                        table.insert(warningStrings, key_to_warnings[warning] or "")
                    end
                end

                if self.filter.exclude_warnings then
                    for __, warning in pairs(self.filter.exclude_warnings) do
                        table.insert(warningStrings, ("-" .. key_to_warnings[warning]) or "")
                    end
                end
                return "Warnings: " .. ((#warningStrings > 0) and table.concat(warningStrings, ", ") or "Any")
            end,

            callback = function()
                self:selectWarnings()
            end,
        },
        {
            text_func = function()
                local key_to_catagory = {
                    ["116"] = "F/F",
                    ["22"] = "F/M",
                    ["21"] = "Gen",
                    ["23"] = "M/M",
                    ["2246"] = "Multi",
                    ["24"] = "Other",
                }

                local catagoryStrings = {}

                if self.filter.categories then
                    for __, catagory in pairs(self.filter.categories) do
                        table.insert(catagoryStrings, key_to_catagory[catagory])
                    end
                end

                if self.filter.exclude_categories then
                    for __, catagory in pairs(self.filter.exclude_categories) do
                        table.insert(catagoryStrings, "-" .. key_to_catagory[catagory])
                    end
                end
                logger.dbg(catagoryStrings)
                return "Catagories: " .. ((#catagoryStrings > 0) and table.concat(catagoryStrings, ", ") or "Any")
            end,
            callback = function()
                self:selectCatagories()
            end,
        },
        {
            text_func = function()
                local characterStrings = {}

                if self.filter.characters then
                    for __, character in pairs(self.filter.characters) do
                        table.insert(characterStrings, character)
                    end
                end

                if self.filter.exclude_characters then
                    for __, character in pairs(self.filter.exclude_characters) do
                        table.insert(characterStrings, "-" .. character)
                    end
                end
                logger.dbg(characterStrings)
                return "Characters: " .. ((#characterStrings > 0) and table.concat(characterStrings, ", ") or "Any")
            end,
            callback = function()
                self:selectCharacters()
            end,
        },
        {
            text_func = function()
                local relationshipStrings = {}

                if self.filter.relationships then
                    for __, relationship in pairs(self.filter.relationships) do
                        table.insert(relationshipStrings, relationship)
                    end
                end

                if self.filter.exclude_relationships then
                    for __, relationship in pairs(self.filter.exclude_relationships) do
                        table.insert(relationshipStrings, "-" .. relationship)
                    end
                end
                return "Relationships: "
                    .. ((#relationshipStrings > 0) and table.concat(relationshipStrings, ", ") or "Any")
            end,
            callback = function()
                self:selectRelationships()
            end,
        },
        {
            text_func = function()
                local freemformStrings = {}

                if self.filter.additional_tags then
                    for __, tag in pairs(self.filter.additional_tags) do
                        table.insert(freemformStrings, tag)
                    end
                end

                if self.filter.exclude_additional_tags then
                    for __, tag in pairs(self.filter.exclude_additional_tags) do
                        table.insert(freemformStrings, "-" .. tag)
                    end
                end
                return "Additional Tags: "
                    .. ((#freemformStrings > 0) and table.concat(freemformStrings, ", ") or "Any")
            end,
            callback = function()
                self:selectAdditionalTags()
            end,
        },
    }
    self.menuWidget:GoDownInMenu("Create filter: Work Tags", menu_items)
end

function CustomFilterMenu:WorkInfoSubmenu()
    local menu_items = {
        {
            text_func = function() return _("Title: ") .. (self.filter.work_title or _("Any")) end,
            callback = function() self:textboxWidget(_("Work title"), "work_title") end,
        },
        {
            text_func = function()
                local key_to_completion = {
                    ["T"] = "Complete works only",
                    ["F"] = "Works in progress only",
                }

                return "Completion status: " .. (key_to_completion[self.filter.completion_status] or "All works")
            end,
            callback = function()
                self:selectCompletionStatus()
            end,
        },
        {
            text_func = function()
                local key_to_crossovers = {
                    ["F"] = "Exclude crossovers",
                    ["T"] = "Only crossovers",
                }

                return "Crossovers: " .. (key_to_crossovers[self.filter.crossovers] or "Include crossovers")
            end,
            callback = function()
                self:selectCrossovers()
            end,
        },
        {
            text_func = function()
                return "Single Chapter: " .. (self.filter.single_chapter and "Single chapter works only" or "All works")
            end,
            callback = function()
                self:selectSingleChapter()
            end,
        },
        {
            text_func = function()
                return "Word Count: " .. (self.filter.word_count or "Any")
            end,
            callback = function()
                self:selectWordCount()
            end,
        },
        {
            text_func = function()
                return "Language: " .. (self.filter.language_id or "Any")
            end,
            callback = function()
                self:selectLanguage()
            end,
        },
        {
            text_func = function()
                return "Date Updated from: " .. (self.filter.date_from or "Any")
            end,
            callback = function()
                self:selectDateFrom()
            end,
        },
        {
            text_func = function()
                return "Date Updated to: " .. (self.filter.date_to or "Any")
            end,
            callback = function()
                self:selectDateTo()
            end,
        },
    }
    self.menuWidget:GoDownInMenu("Create filter: Work Info", menu_items)
end

function CustomFilterMenu:WorkStatSubmenu()
    local menu_items = {
        {
            text_func = function()
                return "Hits: " .. (self.filter.hits or "any amount")
            end,
            callback = function()
                self:selectHits()
            end,
        },
        {
            text_func = function()
                return "Kudos: " .. (self.filter.kudos or "any amount")
            end,
            callback = function()
                self:selectKudos()
            end,
        },
        {
            text_func = function()
                return "Comments: " .. (self.filter.comments or "any amount")
            end,
            callback = function()
                self:selectComments()
            end,
        },
        {
            text_func = function()
                return "Bookmarks: " .. (self.filter.bookmarks or "any amount")
            end,
            callback = function()
                self:selectBookmarks()
            end,
        },
    }
    self.menuWidget:GoDownInMenu("Create filter: Work Stats", menu_items)
end

function CustomFilterMenu:WorkOrderSubmenu()
    local menu_items = {
        {
            text_func = function()
                local key_to_sort = {
                    ["authors_to_sort_on"] = "Author",
                    ["title_to_sort_on"] = "Title",
                    ["created_at"] = "Date Posted",
                    ["revised_at"] = "Date Updated",
                    ["word_count"] = "Word Count",
                    ["hits"] = "Hits",
                    ["kudos_count"] = "Kudos",
                    ["comments_count"] = "Comments",
                    ["bookmarks_count"] = "Bookmarks",
                }

                return "Sort By: " .. (key_to_sort[self.filter.sort_by] or "Date Updated")
            end,
            callback = function()
                self:selectSortBy()
            end,
        },
        {
            text_func = function()
                local key_to_direction = {
                    ["asc"] = "Ascending",
                    ["desc"] = "Descending",
                }

                return "Sort by: " .. (key_to_direction[self.filter.sort_direction] or "Descending")
            end,
            callback = function()
                self:selectSortDirection()
            end,
        },
    }
    self.menuWidget:GoDownInMenu("Create filter: Search Order", menu_items)
end

function CustomFilterMenu:selectCompletionStatus()
    local title = "Select Completion Status"

    local options = {
        {
            text = "All works",
            value = nil,
        },
        {
            text = "Complete works only",
            value = "T",
        },
        {
            text = "Works in progress only",
            value = "F",
        },
    }

    local setting = "completion_status"

    self:selectionWidget(title, options, setting)
end

function CustomFilterMenu:selectCrossovers()
    local title = "Select Crossover filter"

    local options = {
        {
            text = "Include crossovers",
            value = nil,
        },
        {
            text = "Exclude crossovers",
            value = "F",
        },
        {
            text = "Only crossovers",
            value = "T",
        },
    }

    local setting = "crossovers"

    self:selectionWidget(title, options, setting)
end

function CustomFilterMenu:selectSingleChapter()
    local title = "Select chapter count filter"

    local options = {
        {
            text = "All works",
            value = nil,
        },
        {
            text = "Single chapter works only",
            value = "1",
        },
    }

    local setting = "single_chapter"

    self:selectionWidget(title, options, setting)
end

function CustomFilterMenu:selectRating()
    local title = "Select Rating"

    local options = {
        {
            text = "Any",
            value = nil,
        },
        {
            text = "Not Rated",
            value = "9",
        },
        {
            text = "General Audiences",
            value = "10",
        },
        {
            text = "Teen and Up Audiences",
            value = "11",
        },
        {
            text = "Mature",
            value = "12",
        },
        {
            text = "Explicit",
            value = "13",
        },
    }

    local setting = "rating"

    self:selectionWidget(title, options, setting)
end

function CustomFilterMenu:selectWordCount()
    local value=tostring(self.filter.word_count or "")
    local minimum,maximum
    local range=value:match("^(%d+)%-(%d+)$")
    if range then minimum,maximum=value:match("^(%d+)%-(%d+)$")
    elseif value:match("^>%d+$") then minimum=tostring((tonumber(value:sub(2)) or 1)+1)
    elseif value:match("^<%d+$") then maximum=tostring((tonumber(value:sub(2)) or 1)-1)
    elseif value:match("^%d+$") then minimum,maximum=value,value end
    local dialog
    dialog=MultiInputDialog:new{title=_("Word count"),fields={
        {text=minimum or "",hint=_("Minimum"),input_type="number"},
        {text=maximum or "",hint=_("Maximum"),input_type="number"},
    },buttons={{
        {text=_("Cancel"),callback=function() UIManager:close(dialog) end},
        {text=_("Clear"),callback=function() self.filter.word_count=nil;self.menuWidget:updateItems();UIManager:close(dialog) end},
        {text=_("Apply"),is_enter_default=true,callback=function()
            local fields=dialog:getFields();local low_text,high_text=fields[1] or "",fields[2] or ""
            local low,high=tonumber(low_text),tonumber(high_text)
            if low_text~="" and (not low or low<0 or low%1~=0) then
                UIManager:show(InfoMessage:new{text=_("Enter a whole number for the minimum word count.")});return
            end
            if high_text~="" and (not high or high<0 or high%1~=0) then
                UIManager:show(InfoMessage:new{text=_("Enter a whole number for the maximum word count.")});return
            end
            if low and high and low>high then
                UIManager:show(InfoMessage:new{text=_("Minimum word count must not exceed maximum.")});return
            end
            if low and high then self.filter.word_count=low.."-"..high
            elseif low then self.filter.word_count=low==0 and nil or ">"..(low-1)
            elseif high then self.filter.word_count="<"..(high+1) else self.filter.word_count=nil end
            self.menuWidget:updateItems();UIManager:close(dialog)
        end},
    }}}
    UIManager:show(dialog)
end

function CustomFilterMenu:selectLanguage()
    local title = "Enter language id (eg en for English, es for Spanish)"
    local setting = "language_id"
    self:textboxWidget(title, setting)
end

function CustomFilterMenu:selectDateFrom()
    self:showDatePicker("date_from")
end

function CustomFilterMenu:selectDateTo()
    self:showDatePicker("date_to")
end

function CustomFilterMenu:showDatePicker(setting)
    local DateTimeWidget=require("ui/widget/datetimewidget")
    local today=os.date("*t")
    local date=self.filter[setting] or string.format("%04d-%02d-%02d",today.year,today.month,today.day)
    local year,month,day=date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    local picker
    picker=DateTimeWidget:new{year=tonumber(year) or today.year,month=tonumber(month) or today.month,
        day=tonumber(day) or today.day,year_min=2000,year_max=today.year,
        title_text=setting=="date_from" and _("Date Updated from") or _("Date Updated to"),
        ok_text=_("Set date"),extra_text=_("Clear date"),keep_shown_on_apply=true,
        extra_callback=function()
            self.filter[setting]=nil;self.menuWidget:updateItems();picker:onClose()
        end,
        callback=function(selected)
            self.filter[setting]=string.format("%04d-%02d-%02d",selected.year,selected.month,selected.day)
            self.menuWidget:updateItems();picker:onClose()
        end}
    UIManager:show(picker)
end

function CustomFilterMenu:selectedFandoms()
    self:tagSelectionWidget(_("Select fandoms"),"Fandom","fandom_names")
end

function CustomFilterMenu:selectWarnings()
    local title = "Select warnings"
    local menu_items = {
        {
            text = "Creator Choose Not To Use Archive Warnings",
            value = "14",
        },
        {
            text = "Graphic Depictions Of Violence",
            value = "17",
        },
        {
            text = "Major Character Death",
            value = "18",
        },
        {
            text = "No Archive Warnings Apply",
            value = "16",
        },
        {
            text = "Rape/Non-Con",
            value = "19",
        },
        {
            text = "Underage Sex",
            value = "20",
        },
    }

    local setting = "warnings"
    self:checkboxWidget(title, menu_items, setting)
end

function CustomFilterMenu:selectCatagories()
    local title = "Select catagories"
    local options = {
        {
            text = "F/F",
            value = "116",
        },
        {
            text = "F/M",
            value = "22",
        },
        {
            text = "Gen",
            value = "21",
        },
        {
            text = "M/M",
            value = "23",
        },
        {
            text = "Multi",
            value = "2246",
        },
        {
            text = "Other",
            value = "24",
        },
    }
    local setting = "categories"
    self:checkboxWidget(title, options, setting)
end

function CustomFilterMenu:selectCharacters()
    self:tagSelectionWidget("Select character tags", "Character", "characters")
end

function CustomFilterMenu:selectRelationships()
    self:tagSelectionWidget("Select Relationship tags", "Relationship", "relationships")
end

function CustomFilterMenu:selectAdditionalTags()
    self:tagSelectionWidget("Select Additional tags", "Freeform", "additional_tags")
end

function CustomFilterMenu:selectHits()
    local title = "Enter Hits Range (amount or <amount or >amount or min-max)"
    local setting = "hits"
    self:textboxWidget(title, setting)
end

function CustomFilterMenu:selectKudos()
    local title = "Enter Kudos Range (amount or <amount or >amount or min-max)"
    local setting = "kudos"
    self:textboxWidget(title, setting)
end

function CustomFilterMenu:selectComments()
    local title = "Enter Comment Count Range (amount or <amount or >amount or min-max)"
    local setting = "comments"
    self:textboxWidget(title, setting)
end

function CustomFilterMenu:selectBookmarks()
    local title = "Enter Bookmark Count Range (amount or <amount or >amount or min-max)"
    local setting = "bookmarks"
    self:textboxWidget(title, setting)
end

function CustomFilterMenu:selectSortBy()
    local title = "Select value to sort by"
    local options = {
        {
            text = "Author",
            value = "authors_to_sort_on",
        },
        {
            text = "Title",
            value = "title_to_sort_on",
        },
        {
            text = "Date posted",
            value = "created_at",
        },
        {
            text = "Date Updated",
            value = "revised_at",
        },
        {
            text = "Word Count",
            value = "word_count",
        },
        {
            text = "Hits",
            value = "hits",
        },
        {
            text = "Kudos",
            value = "kudos_count",
        },
        {
            text = "Comments",
            value = "comment_count",
        },
        {
            text = "Bookmarks",
            value = "bookmarks_count",
        },
    }
    local setting = "sort_by"
    self:selectionWidget(title, options, setting)
end

function CustomFilterMenu:selectSortDirection()
    local title = "Select sort direction"
    local options = {
        {
            text = "Ascending",
            value = "asc",
        },
        {
            text = "Descending",
            value = "desc",
        },
    }
    local setting = "sort_direction"
    self:selectionWidget(title, options, setting)
end

-- Execute the search with the crafted filter
function CustomFilterMenu:executeSearch(submitted,conflict_confirmed,disable_blacklist)
    local f=deepcopy(submitted or self.filter or {})
    if not conflict_confirmed then
        local conflicts=require('ao3lib.library.blacklist').conflicts(f)
        if #conflicts>0 then
            local dialog
            local function choose(disable)
                UIManager:close(dialog)
                self:executeSearch(f,true,disable)
            end
            dialog=require('ui/widget/buttondialog'):new{
                title=_("These included tags are also on your blacklist:")..'\n\n'..table.concat(conflicts,'\n'),
                buttons={
                    {{text=_("Disable blacklist for this search"),callback=function() choose(true) end}},
                    {{text=_("Search with blacklist"),callback=function() choose(false) end}},
                    {{text=_("Cancel"),callback=function() UIManager:close(dialog) end}},
                },
            }
            UIManager:show(dialog)
            return
        end
    end
    if Network.defer(function() self:executeSearch(f,conflict_confirmed,disable_blacklist) end) then return end
    Network.schedule(0,function()
        local function join(values) return values and #values>0 and table.concat(values,",") or nil end
        local excluded={}
        for _,field in ipairs({"exclude_fandom_names","exclude_characters","exclude_relationships","exclude_additional_tags"}) do
            for _,value in ipairs(f[field] or {}) do excluded[#excluded+1]=value end
        end
        local warning_names={ ["14"]="Creator Chose Not To Use Archive Warnings",["17"]="Graphic Depictions Of Violence",
            ["18"]="Major Character Death",["16"]="No Archive Warnings Apply",["19"]="Rape/Non-Con",["20"]="Underage Sex" }
        local category_names={ ["116"]="F/F",["22"]="F/M",["21"]="Gen",["23"]="M/M",["2246"]="Multi",["24"]="Other" }
        for _,value in ipairs(f.exclude_warnings or {}) do if warning_names[tostring(value)] then excluded[#excluded+1]=warning_names[tostring(value)] end end
        for _,value in ipairs(f.exclude_categories or {}) do if category_names[tostring(value)] then excluded[#excluded+1]=category_names[tostring(value)] end end
        if not disable_blacklist then excluded=require('ao3lib.library.blacklist').exclusions(excluded) end
        local parameters={
            ["work_search[title]"]=f.work_title,
            ["work_search[complete]"]=f.completion_status,["work_search[crossover]"]=f.crossovers,
            ["work_search[single_chapter]"]=f.single_chapter,["work_search[word_count]"]=f.word_count,
            ["work_search[language_id]"]=f.language_id,["work_search[date_from]"]=f.date_from,["work_search[date_to]"]=f.date_to,
            ["work_search[fandom_names]"]=join(f.fandom_names),["work_search[rating_ids]"]=f.rating,
            ["work_search[archive_warning_ids][]"]=f.warnings,["work_search[category_ids][]"]=f.categories,
            ["work_search[character_names]"]=join(f.characters),["work_search[relationship_names]"]=join(f.relationships),
            ["work_search[freeform_names]"]=join(f.additional_tags),["work_search[hits]"]=f.hits,
            ["work_search[kudos_count]"]=f.kudos,["work_search[comments_count]"]=f.comments,
            ["work_search[bookmarks_count]"]=f.bookmarks,["work_search[sort_column]"]=f.sort_by or "revised_at",
            ["work_search[sort_direction]"]=f.sort_direction or "desc",
        }
        if #excluded>0 then parameters["work_search[excluded_tag_names]"]=table.concat(excluded,",") end
        local success,results,nextPage=self.fanfic:executeSearch(parameters)
        if not success then
            UIManager:show(InfoMessage:new{text=_("Failed to fetch results for the custom filter."),timeout=2})
            return
        end
        self.fanfic:onShowFanficBrowser(results,nextPage,nil,{blacklist=not disable_blacklist})
    end)
end

return CustomFilterMenu
