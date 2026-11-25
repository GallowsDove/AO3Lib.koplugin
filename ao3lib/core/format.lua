-- Format counts at presentation boundaries without changing stored metadata.
local _=require('gettext')
local M={}
function M.integer(value)
    local text=tostring(value or '')
    local digits=text:gsub('[,%s]','')
    if not digits:match('^%d+$') then return text end
    digits=digits:gsub('^0+','')
    if digits=='' then return '0' end
    return (digits:reverse():gsub('(%d%d%d)','%1,'):reverse():gsub('^,',''))
end
function M.isZero(value)
    local digits=tostring(value or ''):gsub('[,%s]','')
    return digits:match('^0+$')~=nil
end
function M.newChapters(count)
    if count==1 then return _('1 new chapter') end
    return string.format(_('%d new chapters'),count)
end
return M
