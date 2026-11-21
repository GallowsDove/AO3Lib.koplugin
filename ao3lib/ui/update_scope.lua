-- Match local metadata exactly; coauthors and crossover fandoms each qualify.
local Fields=require('ao3lib.library.fields')
local _=require('gettext')
local M={}
function M.values(work,kind)
    local author=type(work.authors)=='table' and #work.authors>0 and work.authors or work.author
    local value=kind=='author' and author or work.fandoms
    local out,seen={},{}
    for __,name in ipairs(Fields.list(value,true)) do
        name=tostring(name):match('^%s*(.-)%s*$')
        if name~='' and not seen[name] then out[#out+1]=name;seen[name]=true end
    end
    if #out==0 then out[1]=kind=='author' and _('Anonymous') or _('Unknown Fandom') end
    return out
end
function M.isComplete(work)
    local current,total=(work.chapters or ""):match("^%s*(%d+)%s*/%s*(%d+)%s*$")
    current,total=tonumber(current),tonumber(total)
    if current and total and total>0 then return current>=total end
    return work.iswip=="Complete" or work.iswip=="Completed"
end
function M.matches(work,scope)
    if scope and scope.incomplete_only and M.isComplete(work) then return false end
    if scope and scope.kind=='selection' then return scope.keys[tostring(work.id)..'\n'..tostring(work.path)]==true end
    if not scope or not scope.kind or scope.kind=='library' then return true end
    for __,name in ipairs(M.values(work,scope.kind)) do if name==scope.value then return true end end
    return false
end
function M.groups(entries,kind,incomplete_only)
    local groups={}
    for __,entry in ipairs(entries) do
        if not incomplete_only or not M.isComplete(entry.work) then
            for __,name in ipairs(M.values(entry.work,kind)) do groups[name]=(groups[name] or 0)+1 end
        end
    end
    local out={}
    for name,count in pairs(groups) do out[#out+1]={name=name,count=count} end
    table.sort(out,function(a,b) if a.name:lower()~=b.name:lower() then return a.name:lower()<b.name:lower() end;return a.name<b.name end)
    return out
end
function M.label(scope)
    if scope and scope.kind=='selection' then return scope.label end
    local label=_('Entire library')
    if scope and (scope.kind=='author' or scope.kind=='fandom') then label=(scope.kind=='author' and _('Author: ') or _('Fandom: '))..scope.value end
    if scope and scope.incomplete_only then label=label..' · '.._('Incomplete only') end
    return label
end
return M
