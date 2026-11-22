-- Build visibility reasons once for every online work presentation.
local _=require('gettext')
local M={}
function M.reasons(work, options)
    if not work or options.revealed then return nil end
    local reasons={}
    if options.blacklist then
        for __,name in ipairs(require('ao3lib.library.blacklist').match(work)) do
            reasons[#reasons+1]=name
        end
    end
    if options.mutes then
        for __,name in ipairs(require('ao3lib.ao3.mute_cache').match(work)) do
            reasons[#reasons+1]=_('Muted author: ')..name
        end
    end
    if #reasons>0 then return reasons end
end
return M
