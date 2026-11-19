-- Map the browser's one-work pages to AO3's numbered result batches.
-- Keep this out of work arrays: the legacy browser iterates their metadata.
local M={}
local pagers=setmetatable({}, {__mode='k'})
function M.get(fetch) return fetch and pagers[fetch] end
function M.attach(first,fetch,nextBatch)
    local pager={works={},batches={},loaded=0,page_size=math.max(20,#first),fetch=nextBatch}
    function pager:setTotal(value)
        local count=tonumber(value)
        if count and count>=0 then self.total=count end
    end
    function pager:store(page,batch)
        self.batches[page]=batch
        local offset=(page-1)*self.page_size
        for i,work in ipairs(batch) do self.works[offset+i]=work end
        while self.works[self.loaded+1] do self.loaded=self.loaded+1 end
        if batch.total then self:setTotal(batch.total) end
    end
    function pager:cached(index) return self.works[index] end
    function pager:load(index)
        local work=self:cached(index)
        if work then return work end
        local page=math.floor((index-1)/self.page_size)+1
        -- Failed and empty batches remain retryable. Successful batches are
        -- shared by both views, including first/last and neighbouring jumps.
        local batch=self.batches[page] or self.fetch(page)
        if type(batch)~='table' or #batch==0 then return end
        self:store(page,batch)
        return self:cached(index)
    end
    pager:store(1,first)
    pagers[fetch]=pager
    return fetch
end
return M
