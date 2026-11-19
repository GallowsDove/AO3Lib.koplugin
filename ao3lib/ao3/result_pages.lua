-- One request/error contract for all AO3 result lists. A failed request never
-- advances the sequential cursor; numbered requests have their own cursor.
local Paging = require("ao3lib.ao3.work_paging")
local M = {}

function M.open(request, options, onError)
    local function fetch(page)
        local result = request(page)
        if not result.success then
            onError(result.error)
            return nil
        end
        return result[options.field]
    end

    local first = fetch(1)
    if not first then return false end
    local current = 1
    local function nextPage()
        local batch = fetch(current + 1)
        if not batch then
            if options.failure == false then return false end
            return {}
        end
        if #batch > 0 or options.advance_empty then current = current + 1 end
        return batch
    end
    if options.numbered then Paging.attach(first, nextPage, fetch) end
    return true, first, nextPage
end

return M
