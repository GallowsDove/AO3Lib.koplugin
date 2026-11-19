local Network = require("ao3lib.ao3.network")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local FanficSearch = {}

function FanficSearch:show(onSearchCallback)
    local fanfic_lookup_dialog
    local closed = false
    fanfic_lookup_dialog = InputDialog:new{
        title = _("Search work by ID"),
        input = "",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        closed = true
                        UIManager:close(fanfic_lookup_dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local inputText = require("util").trim(fanfic_lookup_dialog:getInputText())
                        if not inputText:match("^%d+$") or not inputText:match("[1-9]") then
                            UIManager:show(InfoMessage:new{
                                text = _("Enter a valid AO3 work ID."),
                            })
                            return
                        end

                        Network.run(function()
                            if closed then return end
                            if onSearchCallback(inputText) == false then return end
                            closed = true
                            UIManager:close(fanfic_lookup_dialog)
                        end)
                    end,
                },
            }
        },
    }
    local onCloseWidget = fanfic_lookup_dialog.onCloseWidget
    fanfic_lookup_dialog.onCloseWidget = function(self, ...)
        closed = true
        if onCloseWidget then return onCloseWidget(self, ...) end
    end

    UIManager:show(fanfic_lookup_dialog)
    fanfic_lookup_dialog:onShowKeyboard()
end

return FanficSearch
