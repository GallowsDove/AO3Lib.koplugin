-- Cookies stay scoped to the exact origin by the client. Never send an
-- expired, insecure or out-of-path cookie, including persistent login tokens.
local M = {}
local months={Jan=1,Feb=2,Mar=3,Apr=4,May=5,Jun=6,Jul=7,Aug=8,Sep=9,Oct=10,Nov=11,Dec=12}
local function date(value)
    local d,m,y,h,n,s=value:match('(%d+)%s+(%a+)%s+(%d+)%s+(%d+):(%d+):(%d+)')
    if not months[m] then return end
    local t=os.time{year=tonumber(y),month=months[m],day=tonumber(d),hour=tonumber(h),min=tonumber(n),sec=tonumber(s),isdst=false}
    local utc=os.date('!*t',t);utc.isdst=false
    return t+os.difftime(t,os.time(utc))
end
function M.expired(c)
    return c.value=='' or (c.expires_at and c.expires_at<=os.time())
end
function M.matches(c,url)
    if M.expired(c) then return false end
    if (c.secure or c.Secure) and not url:match('^https://') then return false end
    local path=url:match('^https?://[^/]+([^?#]*)') or '/'
    if path=='' then path='/' end
    local cp=c.path or c.Path or '/'
    return path==cp or (path:sub(1,#cp)==cp and (cp:sub(-1)=='/' or path:sub(#cp+1,#cp+1)=='/'))
end
function M.parse(headers,url)
    local out={}
    if type(headers)=='table' then
        for _,header in ipairs(headers) do for _,c in ipairs(M.parse(header,url)) do out[#out+1]=c end end
        return out
    end
    if type(headers)~='string' then return out end
    -- A comma in Expires is not a cookie separator; a following name= is.
    local normalized=headers:gsub(',%s*([^%s;,=]+)%s*=', '\n%1=')
    for raw in normalized:gmatch('[^\n]+') do
        local first=true
        local c,maxage
        for part in raw:gmatch('[^;]+') do
            local key,value=part:match('^%s*([^=%s]+)%s*=?%s*(.-)%s*$')
            if first then
                c={name=key,value=value,path=(url:match('^https?://[^/]+(/.*)/') or '/')}
                first=false
            elseif key then
                key=key:lower()
                if key=='path' then c.path=value
                elseif key=='secure' then c.secure=true
                elseif key=='expires' then c.expires_at=date(value)
                elseif key=='max-age' then maxage=tonumber(value)
                end
            end
        end
        if c and c.name then
            if maxage then c.expires_at=os.time()+maxage end
            out[#out+1]=c
        end
    end
    return out
end
return M
