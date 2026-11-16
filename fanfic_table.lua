-- Copy policies shared by settings, saved metadata and Bookshelf snapshots.
local M = {}

function M.shallowCopy(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end

function M.deepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in next, value do
        result[M.deepCopy(key, seen)] = M.deepCopy(item, seen)
    end
    return setmetatable(result, M.deepCopy(getmetatable(value), seen))
end

return M
