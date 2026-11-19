local UIManager = require('ui/uimanager')
local InfoMessage = require('ui/widget/infomessage')
local TextViewer = require('ui/widget/textviewer')
local Config = require('ao3lib.core.config')
local Organizer = require('ao3lib.library.organizer')
local _ = require('gettext')
local M = {}

function M.show(fanfic)
    local ops, err = Organizer.fileOps()
    if not ops then UIManager:show(InfoMessage:new{text=err}); return end
    local cancelled = false
    local scanning = InfoMessage:new{
        text=_("Scanning AO3 EPUBs for the organization preview…"),
        dismiss_callback=function() cancelled=true end,
    }
    UIManager:show(scanning)
    local root = Config:readSetting('fanfic_folder_path')
    local roots = {root, require('apps/filemanager/filemanagerutil').getHomeFolder()}
    require('ao3lib.library.discovery').scan(roots, function(works)
        scanning.dismiss_callback=nil
        UIManager:close(scanning)
        local plan, plan_err = Organizer.plan(works, root)
        if not plan then UIManager:show(InfoMessage:new{text=plan_err}); return end
        local preview
        preview = TextViewer:new{
            title=_("Organize downloaded works — preview"), text=Organizer.describe(plan),
            buttons_table={{
                {text=_("Cancel"), callback=function() UIManager:close(preview) end},
                {text=_("Organize"), enabled=#plan.moves > 0, callback=function()
                    UIManager:close(preview)
                    local working=InfoMessage:new{text=_("Backing up reading state and organizing books…")}
                    UIManager:show(working)
                    UIManager:scheduleIn(0.1, function()
                        local ok, summary, execute_err=pcall(Organizer.execute, plan, function(done,total)
                            if done % 20 == 0 or done == total then
                                UIManager:close(working)
                                working=InfoMessage:new{text=string.format(_("Organizing books: %d / %d"),done,total)}
                                UIManager:show(working)
                                UIManager:forceRePaint()
                            end
                        end)
                        UIManager:close(working)
                        if not ok or not summary then
                            UIManager:show(InfoMessage:new{text=tostring(ok and execute_err or summary)})
                            return
                        end
                        if fanfic.ui.file_chooser then pcall(function() fanfic.ui.file_chooser:refreshPath() end) end
                        UIManager:show(require("ao3lib.ui.navigation").bind(fanfic, TextViewer:new{
                            title=_("Organization results"),
                            text=string.format(_("%d moved; %d skipped after preview; %d failed.\n\nReading-state backups and move journal:\n%s"),
                                summary.moved,summary.skipped,summary.failed,summary.journal)
                                .. (#summary.errors > 0 and ('\n\n' .. table.concat(summary.errors,'\n')) or ''),
                        }))
                    end)
                end},
            }},
        }
        require("ao3lib.ui.navigation").bind(fanfic, preview)
        UIManager:show(preview)
    end, function() return cancelled end)
end

return M
