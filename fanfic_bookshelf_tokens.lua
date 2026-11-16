-- Local EPUB metadata exposed through Bookshelf's public token API.
local Metadata = require("fanfic_bookshelf")
local Fields = require("fanfic_bookshelf_fields")
local _ = require("gettext")
local M = {}

local function metadata(book)
    local path = type(book) == "table" and book.filepath
    if type(path) ~= "string" or not path:lower():match("%.epub$") then return nil end
    return Metadata.get(path, false)
end

function M.install()
    local ok, Tokens = pcall(require, "lib/bookshelf_tokens")
    if not ok or Tokens.API ~= 1 or type(Tokens.register) ~= "function" then return false end
    local defs = {}
    local function add(name, description, value)
        defs[name] = {
            description = description,
            expand = function(book)
                local data = metadata(book)
                return data and value(data) or ""
            end,
        }
    end
    local function joined(key)
        return function(data) return table.concat(data[key] or {}, ", ") end
    end
    add("ao3_id", _("AO3 work ID"), function(data) return data.id end)
    add("ao3_words", _("AO3 word count in the downloaded EPUB"), function(data)
        return data.wordcount and tostring(data.wordcount) or ""
    end)
    add("ao3_chapters", _("AO3 downloaded/total chapters (for example, 12/20 or 12/?)"), function(data)
        return data.chapters ~= "?/?" and data.chapters or ""
    end)
    add("ao3_authors", _("AO3 authors, comma-separated"), joined("ao3_authors"))
    add("ao3_fandoms", _("AO3 fandoms, comma-separated"), joined("ao3_fandoms"))
    add("ao3_relationships", _("AO3 relationships, comma-separated"), joined("ao3_relationships"))
    add("ao3_characters", _("AO3 characters, comma-separated"), joined("ao3_characters"))
    add("ao3_category", _("AO3 categories (F/M, M/M, Gen, etc.)"), joined("ao3_categories"))
    add("ao3_rating", _("AO3 content rating (General Audiences, Explicit, etc.)"), joined("ao3_ratings"))
    add("ao3_warnings", _("AO3 archive warnings, comma-separated"), joined("ao3_warnings"))
    add("ao3_tags", _("AO3 additional tags, comma-separated"), joined("ao3_tags"))
    add("ao3_status", _("AO3 work status: Complete or Work in progress"), function(data)
        local status = (data.ao3_completion or {})[1]
        if not status or status == "unknown" then return "" end
        return Fields.label("ao3_completion", status)
    end)
    return Tokens.register("AO3", defs)
end

return M
