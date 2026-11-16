-- Offline, read-only metadata provider for Bookshelf. The EPUB establishes
-- identity; saved AO3 state contributes chapter progress only.
local M = {}

local function list(value, split)
    local out, seen = {}, {}
    if type(value) == "string" then
        if split then
            local parts = {}
            for part in value:gmatch("[^,\n]+") do parts[#parts+1] = part end
            value = parts
        else value = {value} end
    end
    for _, item in ipairs(type(value) == "table" and value or {}) do
        if type(item) == "string" then
            item = item:match("^%s*(.-)%s*$")
            if item ~= "" and not seen[item] then
                seen[item] = true
                out[#out+1] = item
            end
        end
    end
    return out
end

function M.fromWork(work)
    local authors = list(work.authors or work.author, true)
    if #authors == 0 then authors = {"Anonymous"} end
    local count, total = (work.chapters or ""):match("^(%d+)/([%d?]+)$")
    count, total = tonumber(count), tonumber(total)
    local completion = "unknown"
    if count then completion = total and count >= total and "complete" or "in_progress" end
    local result = {
        id = tostring(work.id),
        title = work.title,
        wordcount = work.wordcount,
        chapters = work.chapters,
        ao3_authors = authors,
        ao3_categories = list(work.categories or work.category, true),
        ao3_ratings = list(work.rating),
        ao3_warnings = list(work.warnings),
        ao3_fandoms = list(work.fandoms),
        ao3_relationships = list(work.relationships),
        ao3_characters = list(work.characters),
        ao3_tags = list(work.tags),
        ao3_completion = {completion},
    }
    return result
end

function M.get(filepath, need_unread)
    local work = require("fanfic_epub").read(filepath)
    if not work then return nil end
    local result = M.fromWork(work)
    if not need_unread then return result end
    local count = tonumber((work.chapters or ""):match("^(%d+)/"))

    local saved = require("downloaded_fanfics").get(work.id) or {}
    local chapters = saved.chapter_data
    local unread
    if type(chapters) == "table" and #chapters > 0 then
        local n = count or #chapters
        unread = 0
        for i = 1, n do
            if not chapters[i] or not chapters[i].read then unread = unread + 1 end
        end
    else
        -- Imported EPUBs have no chapter map. KOReader can still tell us
        -- whether the downloaded book was finished, without creating a sidecar.
        local ok, value = pcall(function()
            local DocSettings = require("docsettings")
            if DocSettings:hasSidecarFile(filepath) then
                local settings = DocSettings:open(filepath)
                local summary = settings:readSetting("summary")
                local status = type(summary) == "table" and summary.status
                local percent = tonumber(settings:readSetting("percent_finished"))
                if status == "complete" or (percent and percent >= 1) then return 0 end
                if percent then return count or 1 end
            elseif saved.read then return 0
            else return count or 1 end
        end)
        if ok then unread = value end
    end
    result.ao3_unread = {unread == nil and "unknown" or (unread > 0 and "unread" or "read")}
    result.unread_chapters = unread
    return result
end

return M
