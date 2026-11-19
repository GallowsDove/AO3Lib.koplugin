-- Legacy display fields may be comma-separated strings. Stored metadata must
-- keep a single string intact because AO3 tag names can themselves contain commas.
local M = {}

function M.list(value, split_commas)
    if type(value) == "table" then return value end
    if type(value) ~= "string" then return {} end
    if not split_commas then return {value} end
    local result = {}
    for item in value:gmatch("([^,]+)") do
        result[#result + 1] = require("util").trim(item)
    end
    return result
end

function M.normalize(work, fields, split_commas)
    for __, field in ipairs(fields) do
        work[field] = M.list(work[field], split_commas)
    end
    return work
end

return M
