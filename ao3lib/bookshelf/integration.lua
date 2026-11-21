-- Runtime extension owned by AO3Lib. Bookshelf files stay untouched.
local Metadata = require("ao3lib.bookshelf.metadata")
local _ = require("gettext")
local M = {}
local Fields = require("ao3lib.bookshelf.fields")
local KEYS = {}
for __, field in ipairs(Fields.list()) do KEYS[#KEYS+1] = field.key end
local function active(value) return type(value) == "table" and next(value) ~= nil end
local function isDimension(key)
    for __, candidate in ipairs(KEYS) do if candidate == key then return true end end
    return false
end
local label = Fields.label
local function metadata(fp, unread)
    if type(fp) ~= "string" or not fp:lower():match("%.epub$") then return nil end
    local ok, data = pcall(Metadata.get, fp, unread)
    if ok and type(data) == "table" then return data end
end
local copy = require("ao3lib.core.table").shallowCopy

function M.install()
    require("ao3lib.ui.icons").installBookshelf()
    require("ao3lib.bookshelf.badges").install()
    require("ao3lib.bookshelf.tokens").install()
    local ok_filter, Filter = pcall(require, "lib/bookshelf_filter")
    local ok_repo, Repo = pcall(require, "lib/bookshelf_book_repository")
    if not ok_filter or not ok_repo then return false end
    require("ao3lib.bookshelf.sources").install(Repo)
    if Filter._fanfic_bookshelf_installed then
        require("ao3lib.bookshelf.details").install(Repo)
        return true
    end
    -- Feature detection keeps older Bookshelf versions usable.
    for __, name in ipairs({"dimensions", "isActive", "signature", "compile", "matches", "summary", "dimSummary"}) do
        if type(Filter[name]) ~= "function" then return false end
    end
    for __, name in ipairs({"getAllFilepaths", "lightMetaFor", "applyFilter", "searchBooks", "distinctFilterValues", "filterValueCounts"}) do
        if type(Repo[name]) ~= "function" then return false end
    end
    local original = copy(Filter)
    local repo_original = copy(Repo)

    Filter.dimensions = function(...)
        local dims = original.dimensions(...)
        for __, field in ipairs(Fields.list()) do
            dims[#dims+1] = {key=field.key, label=field.label, kind="multi"}
        end
        return dims
    end
    Filter.isActive = function(filter)
        if original.isActive(filter) then return true end
        for __, key in ipairs(KEYS) do if active(filter and filter[key]) then return true end end
        return false
    end
    Filter.signature = function(filter)
        local parts = {original.signature(filter)}
        local has_ao3 = false
        for __, key in ipairs(KEYS) do
            if active(filter and filter[key]) then
                has_ao3 = true
                local values = {}
                for value in pairs(filter[key]) do values[#values+1] = tostring(value) end
                table.sort(values)
                parts[#parts+1] = key
                for __, value in ipairs(values) do parts[#parts+1] = #value .. ":" .. value end
            end
        end
        if has_ao3 then
            local History = require("ao3lib.library.history")
            parts[#parts+1] = "ao3_revision:" .. tostring(History.revision and History.revision() or 0)
        end
        return table.concat(parts, "|")
    end
    Filter.compile = function(filter, opts)
        local compiled = original.compile(filter, opts)
        for __, key in ipairs(KEYS) do
            if active(filter and filter[key]) then
                compiled._fanfic_ao3 = compiled._fanfic_ao3 or {}
                local selected = {}
                for value in pairs(filter[key]) do selected[tostring(value):lower()] = true end
                compiled._fanfic_ao3[key] = selected
            end
        end
        return compiled
    end
    Filter.matches = function(book, compiled)
        if not original.matches(book, compiled) then return false end
        local picks = compiled and compiled._fanfic_ao3
        if not picks then return true end
        local data = metadata(book.filepath, picks.ao3_unread ~= nil)
        if not data then return false end
        for key, selected in pairs(picks) do
            local hit = false
            for __, value in ipairs(data[key] or {}) do
                if selected[tostring(value):lower()] then hit = true; break end
            end
            if not hit then return false end
        end
        return true
    end
    Filter.dimSummary = function(filter, key, max_chars)
        if not isDimension(key) then return original.dimSummary(filter, key, max_chars) end
        local display = copy(filter)
        display[key] = {}
        for value in pairs(type(filter and filter[key]) == "table" and filter[key] or {}) do
            display[key][label(key, value)] = true
        end
        return original.dimSummary(display, key, max_chars)
    end
    Filter.summary = function(filter)
        local core, n = copy(filter), 0
        for __, key in ipairs(KEYS) do
            if active(core[key]) then n = n+1 end
            core[key] = nil
        end
        if n == 0 then return original.summary(filter) end
        n = n + (tonumber(original.summary(core):match("%d+")) or 0)
        return string.format(_("%d active"), n)
    end

    local function records(source)
        local kind = type(source) == "table" and source.kind
        if kind then
            local ok, Sources = pcall(require, "lib/bookshelf_sources")
            if ok and Sources.get(kind) then
                if Sources.isPaged(kind) then return {} end -- Never fetch remote catalogues.
                return Sources.list(kind, source) or {}
            end
        end
        local out = {}
        for __, fp in ipairs(Repo.getAllFilepaths()) do
            out[#out+1] = copy(Repo.lightMetaFor(fp) or {filepath=fp})
        end
        return out
    end
    local function counts(dim, filter, source)
        local candidates = records(source)
        if filter and Filter.isActive(filter) then candidates = Repo.applyFilter(candidates, filter) end
        local out, seen = {}, {}
        for __, book in ipairs(candidates) do
            if book.filepath and not seen[book.filepath] then
                seen[book.filepath] = true
                local data = metadata(book.filepath, dim == "ao3_unread")
                local counted = {}
                for __, value in ipairs(data and data[dim] or {}) do
                    if not counted[value] then out[value] = (out[value] or 0)+1; counted[value] = true end
                end
            end
        end
        return out
    end
    Repo.distinctFilterValues = function(dim, source)
        if not isDimension(dim) then return repo_original.distinctFilterValues(dim, source) end
        local choices = {}
        for value, count in pairs(counts(dim, nil, source)) do
            choices[#choices+1] = {value=value, label=label(dim, value), count=count}
        end
        table.sort(choices, function(a,b) return a.label:lower() < b.label:lower() end)
        return choices
    end
    Repo.filterValueCounts = function(dim, filter, source)
        if not isDimension(dim) then return repo_original.filterValueCounts(dim, filter, source) end
        local reduced = copy(filter)
        reduced[dim] = nil
        if not Filter.isActive(reduced) then return nil end
        return counts(dim, reduced, source)
    end
    Repo.searchBooks = function(query, limit)
        local out = repo_original.searchBooks(query, limit) or {}
        if not query or not query:find("%S") or (limit and #out >= limit) then return out end
        local seen = {}
        for __, book in ipairs(out) do if book.filepath then seen[book.filepath] = true end end
        local Settings = require("lib/bookshelf_settings_store")
        local skip_tags = Settings.read("search_include_genres") == false
        for __, fp in ipairs(Repo.getAllFilepaths()) do
            if not seen[fp] then
                local data = metadata(fp)
                if data then
                    local book = copy(Repo.lightMetaFor(fp))
                    book.filepath = fp
                    book.title = book.title or data.title
                    book.author = book.author or table.concat(data.ao3_authors or {}, ", ")
                    book.authors = book.authors or data.ao3_authors
                    book.filename = book.filename or fp:match("([^/]+)$")
                    local parts = {book.title or "", book.author or "", book.series_name or "", book.filename or ""}
                    for __, author in ipairs(book.authors or {}) do parts[#parts+1] = author end
                    if not skip_tags then
                        for __, genre in ipairs(book.genres or {}) do parts[#parts+1] = genre end
                    end
                    for __, field in ipairs(Fields.list()) do
                        local key = field.key
                        if not field.no_search and (not skip_tags or not field.tags) then
                            for __, value in ipairs(data[key] or {}) do parts[#parts+1] = label(key, value) end
                        end
                    end
                    local haystack, hit = table.concat(parts, " "):lower(), true
                    for word in query:lower():gmatch("%S+") do
                        if not haystack:find(word, 1, true) then hit = false; break end
                    end
                    if hit then
                        seen[fp] = true
                        out[#out+1] = book
                        if limit and #out >= limit then break end
                    end
                end
            end
        end
        return out
    end
    Filter._fanfic_bookshelf_installed = true
    require("ao3lib.bookshelf.details").install(Repo)
    return true
end

return M
