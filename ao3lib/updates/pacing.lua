-- Check pacing is independent of server-requested retry/backoff delays.
local M={default=4,min=1,max=120,key='update_check_delay_seconds'}
function M.seconds(value)
    value=tonumber(value)
    if not value or value~=value then return M.default end
    return math.floor(math.max(M.min,math.min(M.max,value)))
end
function M.delay(operation)
    if operation~='check' then return 3+math.random()*2 end
    return M.seconds(require('ao3lib.core.config'):readSetting(M.key,M.default))
end
return M
