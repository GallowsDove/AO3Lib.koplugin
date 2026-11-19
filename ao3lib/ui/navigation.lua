-- AO3 screens stay mounted beneath their children, preserving pagination,
-- scroll position and form state. Repainting/replacing a screen keeps its
-- place in this stack rather than creating another navigation step.
local UI = require("ui/uimanager")
local M = {}

local function stack(owner)
    owner._ao3_navigation = owner._ao3_navigation or {}
    owner.menu_stack = owner.menu_stack or {}
    return owner._ao3_navigation
end

function M.update(window)
    local frame = window._ao3_navigation
    if not frame then return end
    local title = window.title_bar or window.titlebar
    if not title or not title.setRightIcon then return end
    local root = frame.options.root and frame.options.root()
    local icon = "close"
    if not root then
        local BD = require("ui/bidi")
        icon = BD.mirroredUILayout and BD.mirroredUILayout() and "chevron.right" or "chevron.left"
    end
    title:setRightIcon(icon)
end

function M.release(window)
    local frame = window._ao3_navigation
    if not frame then return end
    local frames = stack(frame.owner)
    window._ao3_navigation = nil
    frame.owner.menu_stack[window] = nil
    for i, candidate in ipairs(frames) do
        if candidate == frame then
            local was_top = i == #frames
            table.remove(frames, i)
            local parent = frames[#frames]
            if was_top and parent and not frame.owner._ao3_closing_all then
                if parent.options.resume then parent.options.resume(parent.window) end
                M.update(parent.window)
            end
            break
        end
    end
end

function M.back(window)
    local frame = window._ao3_navigation
    if not frame then return true end
    if frame.options.back and frame.options.back() then
        M.update(window)
        return true
    end
    M.release(window)
    if frame.close then
        frame.close(window)
    else
        UI:close(window)
        if window.close_callback then window.close_callback() end
    end
    return true
end

function M.menu(window)
    local frame = window._ao3_navigation
    if not frame then return true end
    local menu = frame.owner.ui and frame.owner.ui.menu
    if menu and type(menu.onShowMenu) == "function" then
        -- Use the host's native FileManager/Reader top menu, just as Bookshelf
        -- does. AO3 windows remain mounted so dismissing it resumes browsing.
        menu:onShowMenu()
    end
    return true
end

function M.bind(owner, window, options)
    options = options or {}
    local frames = stack(owner)
    local frame = {owner=owner, window=window, options=options, close=window.onClose}
    local replaced = options.replace and options.replace._ao3_navigation
    if replaced then
        for i, candidate in ipairs(frames) do
            if candidate == replaced then frames[i] = frame; break end
        end
        options.replace._ao3_navigation = nil
        owner.menu_stack[options.replace] = nil
    else
        frames[#frames + 1] = frame
    end
    options.replace = nil -- Do not retain the discarded widget in history.
    window._ao3_navigation = frame
    owner.menu_stack[window] = true
    -- Menu redraws automatically show back.top whenever onReturn exists.
    -- Keep that legacy control hidden on AO3 screens, which use header Back.
    -- Restrict the overrides to this button instance, leaving pagination and
    -- other KOReader menus alone.
    local arrow = window.page_return_arrow
    if arrow and arrow.hide then
        arrow:hide()
        arrow.show = arrow.hide
        arrow.focusable = false
        if arrow.disable then
            arrow:disable()
            arrow.enable = arrow.disable
        end
    end
    window.onClose = function(self) return M.back(self) end
    window.onCloseWithKey = window.onClose
    -- PocketBook's remaining front buttons emit Home and Menu, not Back.
    -- Copy the table so bindings never leak through a widget prototype.
    window.key_events = require("ao3lib.core.table").shallowCopy(window.key_events)
    window.key_events.Home = {{"Home"}}
    window.key_events.LeftButtonTap = nil -- Menu's native binding is a no-op for AO3 lists.
    window.key_events.AO3Menu = {{"Menu"}}
    window.onHome = window.onClose
    window.onAO3Menu = function(self) return M.menu(self) end
    local closed = window.onCloseWidget
    window.onCloseWidget = function(self, ...)
        M.release(self)
        if closed then return closed(self, ...) end
    end
    M.update(window)
    return window
end

function M.closeAll(owner)
    owner._ao3_closing_all = true
    local windows = {}
    for window in pairs(owner.menu_stack or {}) do windows[#windows + 1] = window end
    for __, window in ipairs(windows) do
        M.release(window)
        UI:close(window)
    end
    owner.menu_stack, owner._ao3_navigation = {}, {}
    owner._ao3_closing_all = nil
end

return M
