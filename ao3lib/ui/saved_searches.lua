local copy=require("ao3lib.core.table").deepCopy
local M={}
local tag_fields={"fandom_names","characters","relationships","additional_tags","exclude_fandom_names",
    "exclude_characters","exclude_relationships","exclude_additional_tags"}
local function hasTag(parameters,tag)
    for _,field in ipairs(tag_fields) do
        for _,value in ipairs(parameters[field] or {}) do if value==tag then return true end end
    end
    return false
end
function M.normalize(parameters)
    local p=copy(parameters or {})
    local changed=false
    if p.main_tag and p.main_tag~="" then
        local tag=p.main_tag
        if not hasTag(p,tag) then
            p.additional_tags=p.additional_tags or {}
            p.additional_tags[#p.additional_tags+1]=tag
        end
        p.main_tag=nil;changed=true
    end
    return p,changed
end
function M.saved(config)
    local original=config:readSetting("saved_filters",{}) or {}
    local output=copy(original);local changed=false
    for key,item in pairs(output) do
        if type(item)=="table" and type(item.parameters)=="table" then
            local parameters,did=M.normalize(item.parameters)
            if did then item.parameters=parameters;changed=true end
        end
    end
    if changed then config:saveSetting("saved_filters",output) end
    return output
end
return M
