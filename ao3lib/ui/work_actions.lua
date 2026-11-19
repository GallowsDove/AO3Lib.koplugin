-- The same downloaded-work actions, regardless of where the work was found.
local UI = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local History = require("ao3lib.library.history")
local _ = require("gettext")
local T = require("ffi/util").template
local M = {}

function M.delete(work, options)
    options = options or {}
    local dialog
    dialog = ButtonDialog:new{
        title=T(_("Are you sure you want to delete '%1'?"), work.title),
        buttons={{
            {text=_("Delete"), callback=function()
                local ok, err = require("util").removeFile(work.path)
                UI:close(dialog)
                if not ok then
                    UI:show(InfoMessage:new{
                        text=T(_("Failed to delete file for '%1': %2"), work.title, err),
                    })
                    return
                end
                History.delete(work.id)
                pcall(function() require('ao3lib.library.local_cache').removePath(work.path) end)
                if options.deleted then options.deleted(work) end
                if options.refresh then options.refresh() end
                UI:show(InfoMessage:new{text=T(_("'%1' has been deleted."), work.title)})
            end},
            {text=_("Cancel"), callback=function() UI:close(dialog) end},
        }},
    }
    UI:show(dialog)
    return dialog
end

local function open(plugin, work, chapter)
    work.last_accessed = os.date("%Y-%m-%d %H:%M:%S")
    History.update(work)
    plugin:onOpenFanficReader(work.path, work, chapter)
end

function M.chapters(plugin, work)
    local items = {}
    for index, chapter in ipairs(work.chapter_data or {}) do
        items[#items + 1] = {
            text=(chapter.read and "✓ " or "") .. (chapter.name or T(_("Chapter %1"), index)),
            callback=function() open(plugin, work, index) end,
        }
    end
    if #items == 0 then return end
    local menu = require("ui/widget/menu"):new(require("ao3lib.ui.widgets").menu{
        title=_("Select chapter"), item_table=items,
        onMenuSelect=function(self, item)
            if item.callback then item.callback() end
            return true
        end,
    })
    require("ao3lib.ui.navigation").bind(plugin, menu)
    UI:show(menu)
    return menu
end

function M.show(plugin, work, options)
    options = options or {}
    -- Lists can remain open while reading state or a reviewed update changes.
    local saved = History.get and History.get(work.id)
    if saved and saved.path == work.path then work = saved end
    local dialog
    local function action(callback)
        return function()
            UI:close(dialog)
            callback()
        end
    end
    dialog = ButtonDialog:new{
        title=T(_("Options for '%1'"), work.title),
        buttons={
            {
                {text=_("Work details"), callback=action(function()
                    plugin:onShowFanficBrowser({options.details or work, total=1}, nil, _("AO3 work details"))
                end)},
                {text=_("Check for updates"), callback=action(function()
                    require("ao3lib.ui.update_review").showWork(plugin, work)
                end)},
            },
            {
                {text=_("Open for reading"), callback=action(function() open(plugin, work) end)},
                {text=_("Select chapter"), enabled=#(work.chapter_data or {}) > 0,
                    callback=action(function() M.chapters(plugin, work) end)},
            },
            {
                {text=_("Delete local copy"), callback=action(function() M.delete(work, options) end)},
                {text=_("Cancel"), callback=function() UI:close(dialog) end},
            },
        },
    }
    UI:show(dialog)
    return dialog
end

return M
