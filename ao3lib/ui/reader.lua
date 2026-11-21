local Network = require("ao3lib.ao3.network")
-- Based upon code found in rakuyomi.koplugin maintained by hanatsumi , https://github.com/hanatsumi/rakuyomi
local ReaderUI = require("apps/reader/readerui")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Event = require("ui/event")
local DownloadedFanfics = require("ao3lib.library.history")
local AO3LibClient = require("ao3lib.ao3.client")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local FanficBookmarkDialog = require("ao3lib.ui.bookmark_dialog")
local logger = require("logger")

local FFIUtil = require("ffi/util")
local T = FFIUtil.template

local FanficReader = {
    on_return_callback = nil,
    on_end_of_book_callback = nil,
    is_showing = false,
    current_fanfic = nil,
    current_chapter = nil,
}

function FanficReader:show(options)
    -- ReaderUI initialization verifies the EPUB and owns activation. Set the
    -- requested chapter before opening: ReaderReady may run synchronously.
    local pending = {path=options.fanfic_path, chapter=options.chapter_opening_at}
    self._pending_open = pending
    local instance = ReaderUI.instance
    if instance and instance.document then
        instance:switchDocument(options.fanfic_path)
    else
        UIManager:broadcastEvent(Event:new("SetupShowReader"))
        ReaderUI:showReader(options.fanfic_path)
    end
    -- A failed open must not leave a chapter jump armed for a later open.
    if self._pending_open == pending then self._pending_open = nil end
end

function FanficReader:isActiveReader(ui)
    return self.is_showing and ui and self._reader_ui == ui and ui.document
        and self.current_fanfic and ui.document.file == self.current_fanfic.path
end

function FanficReader:saveAccountState(fields)
    if not self.account_only then
        DownloadedFanfics.update(self.current_fanfic, false)
        return
    end
    local stored=DownloadedFanfics.checkIfStored(self.current_fanfic.id)
    if stored then
        for _,key in ipairs(fields) do
            stored[key]=self.current_fanfic[key]
        end
        DownloadedFanfics.update(stored, false)
    end
end

function FanficReader:workManagementButtons(close)
    return {
                {
                    {
                        text = self.current_fanfic.markedForLater and "Mark as read" or "Mark for later",
                        callback = Network.wrap(function()

                            local request_result = AO3LibClient:markForLaterWork(self.current_fanfic.id,
                                self.current_fanfic.markedForLater)

                            if request_result.success then
                                self.current_fanfic.markedForLater = not self.current_fanfic.markedForLater
                                self:saveAccountState({"markedForLater"})
                                UIManager:show(InfoMessage:new({
                                    text = self.current_fanfic.markedForLater and "Work marked for later" or
                                        "Work marked as read",
                                }))
                            else
                                UIManager:show(InfoMessage:new({
                                    text = "Error: " .. request_result.error,
                                }))
                            end

                            close()
                        end),
                    }
                    },
                    {
                        {
                            text = self.current_fanfic.subscriptionID and "Unsubscribe from work" or "Subscribe to work",
                            callback = Network.wrap(function()

                                local request_result = AO3LibClient:setWorkSubscription(self.current_fanfic.id,
                                    self.current_fanfic.subscriptionID)
                                if request_result.success then
                                    if request_result.subscription_id then
                                        self.current_fanfic.subscriptionID = request_result.subscription_id
                                    else
                                        self.current_fanfic.subscriptionID = false
                                    end
                                    self:saveAccountState({"subscriptionID"})

                                    UIManager:show(InfoMessage:new({
                                        text = self.current_fanfic.subscriptionID and "Subscribed to work" or
                                        "Unsubscribed from work",
                                    }))
                                else
                                    UIManager:show(InfoMessage:new({
                                        text = "Error: " .. request_result.error .. (self.current_fanfic.subscriptionID or ""),
                                    }))
                                end

                                close()
                            end),
                        }
                    },
                    {
                        {
                            text = self.current_fanfic.bookmarkID and "Edit Bookmark" or "Bookmark work",
                            callback = Network.wrap(function()

                                local request_result = AO3LibClient:getUsersWorkBookmark(self.current_fanfic.id)
                                if  request_result.success then
                                    self.current_fanfic.bookmarkContent = request_result.bookmark_data

                                    if request_result.bookmark_id then
                                        self.current_fanfic.bookmarkID = request_result.bookmark_id
                                    else
                                        self.current_fanfic.bookmarkID = false
                                    end
                                    self:saveAccountState({"bookmarkID","bookmarkContent"})

                                else
                                    local info_message = InfoMessage:new({
                                        text = "Error: " .. request_result.error,
                                    })
                                    info_message[1].ignore = "height"
                                    UIManager:show(info_message)
                                    return
                                end


                                local fanficBookmark_dialog =  FanficBookmarkDialog:new({
                                    current_fanfic = self.current_fanfic,
                                    bookmark_notes_original = self.current_fanfic.bookmarkContent and self.current_fanfic.bookmarkContent.notes or nil,
                                    bookmark_tags_original = self.current_fanfic.bookmarkContent and self.current_fanfic.bookmarkContent.tags or nil,
                                    bookmark_collections_original = self.current_fanfic.bookmarkContent and self.current_fanfic.bookmarkContent.collections or nil,
                                    bookmark_private = self.current_fanfic.bookmarkContent and self.current_fanfic.bookmarkContent.private or false,
                                    bookmark_rec = self.current_fanfic.bookmarkContent and self.current_fanfic.bookmarkContent.rec or false,
                                    save_dialog_callback = function(bookmark_data)

                                        local request_result = AO3LibClient:updateBookmark(
                                            self.current_fanfic.id,
                                            self.current_fanfic.bookmarkID,
                                            bookmark_data.notes,
                                            bookmark_data.tags,
                                            bookmark_data.collections,
                                            bookmark_data.private,
                                            bookmark_data.rec
                                        )

                                        if request_result.success then
                                            local originalBMID = self.current_fanfic.bookmarkID

                                            self.current_fanfic.bookmarkContent = bookmark_data

                                            if request_result.bookmark_id then
                                                self.current_fanfic.bookmarkID = request_result.bookmark_id
                                            else
                                                self.current_fanfic.bookmarkID = false
                                            end
                                            self:saveAccountState({"bookmarkID","bookmarkContent"})

                                            UIManager:show(InfoMessage:new({
                                                text = originalBMID and "Updated Bookmark" or "Created Bookmark",
                                            }))
                                            return true
                                        else
                                            logger.dbg("Error saving bookmark: " .. request_result.error)
                                            UIManager:show(InfoMessage:new({
                                                text = "Error: " .. request_result.error,
                                            }))
                                            return false
                                        end

                                    end,
                                    delete_dialog_callback = function()

                                        local request_result = AO3LibClient:deleteBookmark(self.current_fanfic.bookmarkID)

                                        if request_result.success then
                                            self.current_fanfic.bookmarkID = false
                                            self.current_fanfic.bookmarkContent = {}
                                            self:saveAccountState({"bookmarkID","bookmarkContent"})

                                            UIManager:show(InfoMessage:new({
                                                text = "Deleted Bookmark",
                                            }))
                                            return true
                                        else
                                            logger.dbg("Error deleting bookmark: " .. request_result.error)
                                            UIManager:show(InfoMessage:new({
                                                text = "Error: " .. request_result.error,
                                            }))
                                            return false
                                        end

                                    end,

                                    search_collections_callback = function(collection_name)


                                        local request_result = AO3LibClient:searchForCollections(collection_name)

                                        if request_result.success then
                                            return request_result.collections
                                        else
                                            logger.dbg("Error searching collections: " .. request_result.error)
                                            UIManager:show(InfoMessage:new({
                                                text = "Error: " .. request_result.error,
                                            }))
                                            return nil
                                        end
                                    end

                                })
                                fanficBookmark_dialog.close_widget_callback = function()
                                    UIManager:close(fanficBookmark_dialog)
                                end
                                UIManager:show(fanficBookmark_dialog)
                                fanficBookmark_dialog:onShowKeyboard()

                                close()

                            end)
                        }
                    }
                }
end

function FanficReader:addToMainMenu(menu_items)
    if not self.current_fanfic then return end
    menu_items.AO3_formatting = {
        text = "AO3 formatting", sorting_hint = "main",
        sub_item_table = {
            {text="Clean up formatting", keep_menu_open=false, callback=function()
                require("ao3lib.ui.cleanup_reader").clean(self, self._reader_ui)
            end},
            {text="Revert formatting cleanup", keep_menu_open=false, callback=function()
                require("ao3lib.ui.cleanup_reader").revert(self, self._reader_ui)
            end},
        },
    }
    local function commentOwner()
        self.comments_owner=self.plugin_owner or self.comments_owner or {ui=self._reader_ui,menu_stack={}}
        return self.comments_owner
    end
    local function showCommentDialog(chapter_index)
        local chapter=self.current_fanfic.chapter_data and self.current_fanfic.chapter_data[chapter_index]
        self.input_dialog=require("ao3lib.ui.comments").compose(commentOwner(),self.current_fanfic,{
            chapter_id=chapter and chapter.id,chapter_name=chapter and chapter.name,
        })
    end
    menu_items.AO3Lib_read_comments={
        text="Read comments",sorting_hint="main",keep_menu_open=false,
        callback=Network.wrap(function() require("ao3lib.ui.comments").show(commentOwner(),self.current_fanfic) end),
    }

    menu_items.AO3_manage_work = {
        text = "Manage work", sorting_hint = "main", keep_menu_open = false,
        callback = function()
            local dialog
            dialog=ButtonDialog:new{
                title=T("Options for '%1'",self.current_fanfic.title),
                buttons=self:workManagementButtons(function() UIManager:close(dialog) end),
            }
            UIManager:show(dialog)
        end,
    }
    menu_items.AO3Lib_kudos_work = {
        text = "Give kudos to work ♥",
        sorting_hint = "main",
        keep_menu_open = true,
        callback = Network.wrap(function()

            local request_result = AO3LibClient:kudosWork(self.current_fanfic.id)

            if request_result.success then
                UIManager:show(InfoMessage:new({
                    text = "Thank you for leaving kudos!",
                }))
                return
            end

            UIManager:show(InfoMessage:new({
                text = "Error: " .. request_result.error,
            }))
        end),
    }

    menu_items.AO3Lib_comment_work = {
        text = "Comment on work",
        sorting_hint = "main",
        keep_menu_open = true,
    }

    if self.current_fanfic.chapter_data and #self.current_fanfic.chapter_data > 0 then
        local chapter_menu_options = {}
        for idx, chapter in pairs(self.current_fanfic.chapter_data) do
            local option = {
                text = chapter.name,
                callback = function()
                    showCommentDialog(idx)
                end,
                keep_menu_open = true,
            }
            table.insert(chapter_menu_options, option)
        end
        menu_items.AO3Lib_comment_work.sub_item_table = chapter_menu_options
    else
        menu_items.AO3Lib_comment_work.callback = function()
            showCommentDialog(nil)
        end
    end

end

function FanficReader:initializeFromReaderUI(ui)
    local pending = self._pending_open
    self._pending_open = nil
    self.is_showing, self.current_fanfic, self._reader_ui = false, nil, nil
    self.current_chapter, self.chapter_opening_at = nil, nil
    -- Every entry point (Bookshelf, History, file manager, AO3) takes this
    -- path. Download history contributes progress only after EPUB identity.
    local path = ui.document and ui.document.file
    local ok, work = pcall(function()
        local epub = require("ao3lib.library.epub").read(path)
        if epub then return DownloadedFanfics.rememberLocal(epub) end
    end)
    if not ok then logger.warn("AO3 reader identification failed:", work); return end
    if not work then return end
    self.current_fanfic, self._reader_ui, self.is_showing = work, ui, true
    if pending and pending.path == path then self.chapter_opening_at = pending.chapter end
    if not ui._ao3_reader_menu then
        ui.menu:registerToMainMenu(self)
        ui._ao3_reader_menu = true
    end
    ui:registerPostInitCallback(function()
        if self:isActiveReader(ui) then self:hookWithPriorityOntoReaderUiEvents(ui) end
    end)
end

function FanficReader:onReaderReady(ui)
    ui = ui or self._reader_ui
    if not self:isActiveReader(ui) then return end
    ui._ao3_tracking_page = nil
    local chapter = self.chapter_opening_at
    self.chapter_opening_at = nil
    if chapter then
        UIManager:nextTick(function()
            if not self:isActiveReader(ui) then return end
            local toc = ui.document:getToc()
            local target = toc and toc[chapter + 1]
            if target and target.page then UIManager:broadcastEvent(Event:new("GotoPage", target.page)) end
        end)
    elseif type(ui.getCurrentPage) == "function" then
        -- The restored page may have been reported before our post-init
        -- listener was attached. Reconcile it once rendering is ready.
        self:onPageUpdate(ui:getCurrentPage(), ui)
    end
end

function FanficReader:hookWithPriorityOntoReaderUiEvents(ui)
    assert(ui.name == "ReaderUI", "expected to be inside ReaderUI")
    if ui._ao3_reader_listener then return end
    local eventListener = WidgetContainer:new({})
    eventListener.onCloseWidget = function() self:onReaderUiCloseWidget(ui) end
    eventListener.onPageUpdate = function(__, pageno) self:onPageUpdate(pageno, ui) end
    eventListener.onPosUpdate = function(__, pos, pageno) self:onPageUpdate(pageno, ui) end
    eventListener.onReaderReady = function() self:onReaderReady(ui) end
    -- Re-evaluate the same page when layout, ToC or navigation ticks change.
    eventListener.onTocReset = function() ui._ao3_tracking_page = nil end
    eventListener.onDocumentRerendered = function() ui._ao3_tracking_page = nil end
    ui._ao3_reader_listener = eventListener
    table.insert(ui, 2, eventListener)
end

function FanficReader:onFinishChapter(chapter_index)
    local chapter = self.current_fanfic and self.current_fanfic.chapter_data
        and self.current_fanfic.chapter_data[chapter_index]
    if not chapter then return end
    if chapter.read then
        return
    end

    -- Update fanfic chapter read status
    local updated = DownloadedFanfics.markChapterAsRead(self.current_fanfic.id, chapter_index)
    if updated then chapter.read = true end
end

function FanficReader:onFinishSingleChapterWork()
    if not self.current_fanfic or self.current_fanfic.read then
        return
    end

    local updated = DownloadedFanfics.markWorkAsRead(self.current_fanfic.id)
    if updated then self.current_fanfic.read = true end
end

function FanficReader:onPageUpdate(pageno, ui)
    ui = ui or self._reader_ui
    if not self:isActiveReader(ui) or type(pageno) ~= "number" then return end
    if self._formatting_reload_path == ui.document.file then return end
    local total = ui.document:getPageCount()
    if not total or pageno < 1 or pageno > total then return end
    local previous = ui._ao3_tracking_page
    if previous and previous.page == pageno and previous.total == total then return end
    ui._ao3_tracking_page = {page=pageno,total=total}
    local chapters = self.current_fanfic.chapter_data or {}
    if #chapters > 0 then
        local index = ui.toc and ui.toc:getTocIndexByPage(pageno)
        if index and index > 1 and index-1 <= #chapters and not chapters[index-1].read
                and ui.toc:isChapterEnd(pageno) then
            self:onFinishChapter(index-1)
        end
        -- isChapterEnd checks the page before the NEXT ToC entry, so it
        -- never catches a final chapter with no afterword/next chapter.
        if pageno == total then self:onFinishChapter(#chapters) end
    elseif pageno == total then
        -- Imported EPUBs without a chapter-ID map still track whole-work
        -- completion, without treating their first chapter as the whole book.
        self:onFinishSingleChapterWork()
    end
end

function FanficReader:onReaderUiCloseWidget(ui)
    if ui and ui ~= self._reader_ui then return end
    if DownloadedFanfics.flushPending then
        local ok, err = DownloadedFanfics.flushPending()
        if not ok then logger.warn("Could not save pending AO3 progress:", err) end
    end
    self.is_showing, self.current_fanfic, self._reader_ui = false, nil, nil
    self.current_chapter, self.chapter_opening_at = nil, nil
end

return FanficReader
