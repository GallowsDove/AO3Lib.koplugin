-- Keep whole-library metadata, filtering and grouping off the UI thread.
local Background = require('fanfic_background')
local _ = require('gettext')
local M = {}
local copy = require("fanfic_table").shallowCopy
local function clones(list)
    local out={};for i,v in ipairs(list or {}) do out[i]=copy(v) end;return out
end
-- Filters are maps; their insertion order must not create distinct cache entries.
local function key(value)
    if type(value)~='table' then
        local text=type(value)..':'..tostring(value)
        return #text..':'..text
    end
    local parts={}
    for k,v in pairs(value) do
        local part=key(k)..'='..key(v);parts[#parts+1]=#part..':'..part
    end
    table.sort(parts)
    return '{'..table.concat(parts,';')..'}'
end
function M.new(options)
    local self={catalog={},queries={},previous={},queue={},epoch=0}
    local pump
    local function synchronize()
        local stamp=options.stamp()
        if stamp~=self.stamp then
            self.stamp=stamp;self.epoch=self.epoch+1
            for id,entry in pairs(self.queries) do
                if entry.list then self.previous[id]=entry end
            end
            self.queries={};self.queue={};self.catalog_stamp=nil
            local job=self.job;self.job=nil
            if job then job:cancel() end
        end
    end
    function self:clear()
        self.stamp=nil;self.catalog={};self.members_index=nil
        self.queries={};self.previous={};synchronize()
    end
    local function request(query)
        synchronize()
        local id=key(query)
        if options.busy() then return self.queries[id] end
        if not self.queries[id] then
            self.queries[id]={pending=true}
            -- Shelf editors can mutate filters while another query is queued.
            local buffer=require('string.buffer')
            self.queue[#self.queue+1]={id=id,query=buffer.decode(buffer.encode(query))}
            pump()
        end
        return self.queries[id]
    end
    pump=function()
        if self.job or #self.queue==0 then return end
        local item=table.remove(self.queue,1)
        local epoch,stamp=self.epoch,self.stamp
        self.job=Background.run(function()
            self.worker=true
            local catalog=self.catalog_stamp==stamp and self.catalog or options.build()
            self.worker_catalog=catalog
            local list=item.query.kind and options.group(item.query) or nil
            local members={}
            for _,spec in ipairs(options.specs) do
                local index={};members[spec.key]=index
                for _,group in ipairs(options.groupAll(catalog,spec)) do
                    local name=group.title
                    if group._fanfic_ao3.unknown then name=false end
                    index[name]=group.books
                end
            end
            return {catalog=catalog,members=members,list=list}
        end,function(result,err)
            if epoch~=self.epoch then return end
            self.job=nil
            if options.stamp()~=stamp then synchronize();options.changed();return end
            local entry=self.queries[item.id]
            if result then
                self.catalog,self.members_index=result.catalog,result.members
                self.catalog_stamp=stamp
                entry.list=result.list;entry.pending=nil
                self.previous[item.id]=nil
                -- Bound retained filter/sort variants. Pending requests must survive.
                local count=0
                for id,cached in pairs(self.queries) do
                    if not cached.pending then
                        count=count+1
                        if count>64 and id~=item.id then self.queries[id]=nil end
                    end
                end
                options.changed()
            else
                entry.pending=nil;entry.failed=true
                if not Background.isCancelled(err) then
                    require('logger').warn('AO3 shelf calculation failed:',err)
                    require('ui/uimanager'):show(require('ui/widget/infomessage'):new{
                        text=_('Could not prepare the AO3 shelf. Refresh the shelf to try again.')})
                end
            end
            pump()
        end,{valid=function() return epoch==self.epoch and options.stamp()==stamp end})
    end
    function self:records()
        if self.worker then return clones(self.worker_catalog) end
        synchronize()
        if self.catalog_stamp~=self.stamp then request({}) end
        return clones(self.catalog)
    end
    function self:groups(source,filter,priority,offset,limit)
        local entry=request({kind=source.kind,source=source,filter=filter,priority=priority})
        local previous=self.previous[key({kind=source.kind,source=source,filter=filter,priority=priority})]
        local list=entry and entry.list or previous and previous.list or {}
        local page,total={},#list
        for i=(offset or 0)+1,math.min((offset or 0)+(limit or total),total) do
            local group=copy(list[i]);group.books=clones(group.books)
            page[#page+1]=group
        end
        return page,total
    end
    function self:members(field,value,unknown)
        synchronize()
        if self.catalog_stamp~=self.stamp then request({}) end
        local index=self.members_index and self.members_index[field]
        if unknown then value=false end
        return clones(index and index[value])
    end
    return self
end
return M
