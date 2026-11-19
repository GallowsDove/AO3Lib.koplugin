local NetworkMgr = require("ui/network/manager")
local unpack = unpack or table.unpack

local Network = {}

-- Defer the whole UI operation, including processing its return values.
-- Retrying only a data-fetching method loses the caller's continuation.
function Network.defer(callback)
    if not NetworkMgr:isConnected() then
        NetworkMgr:runWhenConnected(function() Network.run(callback) end)
        return true
    end
    local Background = require("ao3lib.ao3.background")
    if Background.available() and not coroutine.running() then
        Background.wrap(callback)
        return true
    end
    return false
end

function Network.run(callback, ...)
    local args = { n = select("#", ...), ... }
    if Network.defer(function() callback(unpack(args, 1, args.n)) end) then return end
    return callback(unpack(args, 1, args.n))
end

function Network.wrap(callback)
    return function(...) return Network.run(callback, ...) end
end

function Network.schedule(delay,callback)
    require("ui/uimanager"):scheduleIn(delay,Network.wrap(callback))
end

return Network
