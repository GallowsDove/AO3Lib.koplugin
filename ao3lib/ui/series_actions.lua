local _=require('gettext')
local UI=require('ui/uimanager')
local Network=require('ao3lib.ao3.network')
local Client=require('ao3lib.ao3.client')
local M={}
local function message(text)
    UI:show(require('ui/widget/infomessage'):new{text=text})
end
function M.bookmark(series)
    if Network.defer(function() M.bookmark(series) end) then return end
    local result=Client:getUsersSeriesBookmark(series.id)
    if not result.success then message(result.error or _('Could not load bookmark.'));return end
    local data=result.bookmark_data or {}
    local current={id=series.id,bookmarkID=result.bookmark_id}
    local dialog
    dialog=require('ao3lib.ui.bookmark_dialog'):new{
        title=_('Bookmark series'),current_fanfic=current,
        bookmark_notes_original=data.notes,bookmark_tags_original=data.tags,
        bookmark_collections_original=data.collections,bookmark_private=data.private,bookmark_rec=data.rec,
        save_dialog_callback=function(values)
            local saved=Client:updateBookmark(series.id,current.bookmarkID,values.notes,values.tags,
                values.collections,values.private,values.rec,'series')
            if not saved.success then message(saved.error or _('Could not save bookmark.'));return false end
            message(current.bookmarkID and _('Bookmark updated.') or _('Bookmark created.'))
            return true
        end,
        delete_dialog_callback=function()
            local deleted=Client:deleteBookmark(current.bookmarkID)
            if not deleted.success then message(deleted.error or _('Could not delete bookmark.'));return false end
            message(_('Bookmark deleted.'));return true
        end,
        search_collections_callback=function(name)
            local found=Client:searchForCollections(name)
            if not found.success then message(found.error or _('Could not search collections.'));return nil end
            return found.collections
        end,
    }
    dialog.close_widget_callback=function() UI:close(dialog) end
    UI:show(dialog);dialog:onShowKeyboard()
    return dialog
end
function M.show(owner,series)
    if not series or not series.id then return end
    local dialog
    dialog=require('ui/widget/buttondialog'):new{title=series.title or _('Series'),buttons={
        {{text=_('Manage bookmark'),callback=function() UI:close(dialog);M.bookmark(series) end}},
        {{text=_('Manage subscription'),callback=function()
            UI:close(dialog);require('ao3lib.ui.subscriptions').manage(owner,'Series',series.id,series.title)
        end}},
        {{text=_('Cancel'),callback=function() UI:close(dialog) end}},
    }}
    UI:show(dialog)
    return dialog
end
return M
