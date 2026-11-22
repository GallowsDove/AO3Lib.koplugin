-- Global online-browsing exclusions. Saved filters and local library data are untouched.
local Config=require('ao3lib.core.config')
local M={}
local fields={Fandom='fandoms',Character='characters',Relationship='relationships',Freeform='tags',
    Rating='rating',Category='category',Warning='warnings'}
M.options={
    Rating={{id='9',name='Not Rated'},{id='10',name='General Audiences'},
        {id='11',name='Teen and Up Audiences'},{id='12',name='Mature'},{id='13',name='Explicit'}},
    Category={{id='116',name='F/F'},{id='22',name='F/M'},{id='21',name='Gen'},
        {id='23',name='M/M'},{id='2246',name='Multi'},{id='24',name='Other'}},
    Warning={{id='14',name='Creator Chose Not To Use Archive Warnings'},
        {id='17',name='Graphic Depictions Of Violence'},{id='18',name='Major Character Death'},
        {id='16',name='No Archive Warnings Apply'},{id='19',name='Rape/Non-Con'},
        {id='20',name='Underage Sex'}},
}
local function normalized(value)
    local name=tostring(value or ''):gsub('%s+',' '):match('^%s*(.-)%s*$'):lower()
    if name=='creator choose not to use archive warnings' then name='creator chose not to use archive warnings' end
    return name
end
function M.entries()
    local entries=Config:readSetting('tag_blacklist',{})
    return type(entries)=='table' and entries or {}
end
function M.enabled() return Config:readSetting('tag_blacklist_enabled',true) end
function M.contains(kind,name)
    for _,entry in ipairs(M.entries()) do
        if entry.type==kind and normalized(entry.name)==normalized(name) then return true end
    end
    return false
end
function M.add(kind,name)
    if not fields[kind] or type(name)~='string' then return false end
    name=name:match('^%s*(.-)%s*$')
    if name=='' or M.contains(kind,name) then return false end
    local entries=M.entries()
    entries[#entries+1]={type=kind,name=name}
    Config:saveSetting('tag_blacklist',entries)
    return true
end
function M.conflicts(filter)
    if not M.enabled() then return {} end
    local included,seen,result={},{},{}
    for _,field in ipairs({'fandom_names','characters','relationships','additional_tags'}) do
        for _,name in ipairs(filter[field] or {}) do included[normalized(name)]=true end
    end
    for _,kind in ipairs({'Rating','Category','Warning'}) do
        local field=kind=='Rating' and 'rating' or kind=='Category' and 'categories' or 'warnings'
        local values=filter[field]
        if type(values)~='table' then values=values and {values} or {} end
        for _,id in ipairs(values) do
            for _,option in ipairs(M.options[kind]) do
                if tostring(id)==option.id then included[normalized(option.name)]=true end
            end
        end
    end
    for _,entry in ipairs(M.entries()) do
        local name=normalized(entry.name)
        if fields[entry.type] and name~='' and included[name] and not seen[name] then
            seen[name]=true;result[#result+1]=entry.name
        end
    end
    return result
end
function M.exclusions(existing)
    local values,seen={},{}
    local function add(name)
        if type(name)~='string' or normalized(name)=='' or seen[normalized(name)] then return end
        seen[normalized(name)]=true;values[#values+1]=name
    end
    for _,name in ipairs(existing or {}) do add(name) end
    if M.enabled() then for _,entry in ipairs(M.entries()) do if fields[entry.type] then add(entry.name) end end end
    return values
end
function M.match(work)
    local result,seen={},{}
    if not M.enabled() or not work then return result end
    for _,entry in ipairs(M.entries()) do
        local field=fields[entry.type]
        local value=field and (field=='tags' and work.tag_names or work[field])
        if field=='category' and work.categories then value=work.categories end
        if type(value)=='string' then
            if entry.type=='Category' then
                local parts={};for part in value:gmatch('[^,]+') do parts[#parts+1]=part end;value=parts
            else value={value} end
        end
        if type(value)=='table' and normalized(entry.name)~='' then
            for _,tag in ipairs(value) do
                local name=normalized(entry.name)
                if type(tag)=='string' and normalized(tag)==name and not seen[name] then
                    seen[name]=true;result[#result+1]=entry.name;break
                end
            end
        end
    end
    return result
end
return M
