local https = require("ssl.https")
local socketutil = require("socketutil")
local url = require("socket.url")
local M = {}

local function failure(status, headers, message)
    return { success = false, status = status, response_headers = headers or {}, error = message,
        retry_later = status == nil or status == 429 or status >= 500 }
end

local function statusError(status)
    if status == 429 then return "AO3 is rate-limiting requests (HTTP 429). Please try again later." end
    if status == 503 then return "AO3 is temporarily unavailable or under maintenance (HTTP 503). Please try again later." end
    if status and status >= 500 then return "AO3 is temporarily unavailable (HTTP " .. status .. "). Please try again later." end
    return "AO3 request failed (HTTP " .. tostring(status or "unknown") .. ")."
end

local function unavailablePage(body)
    -- Inspect the document title, not story content that might mention downtime.
    body = body:lower()
    local title = body:match("<title[^>]*>(.-)</title%s*>") or ""
    if title:match("|%s*archive of our own%s*$")
            and (body:find('id%s*=%s*"main"') or body:find("id%s*=%s*'main'")) then return false end
    return title:find("maintenance", 1, true) or title:find("unavailable", 1, true)
        or title:find("down for", 1, true) or title:find("just a moment", 1, true)
        or title:find("access denied", 1, true) or title:find("too many requests", 1, true)
end

-- GET redirects are bounded. Mutating requests retain their redirect response
-- for the caller to interpret, and are never replayed after a network failure.
function M.request(request, handler, retries)
    local target = request.url
    local method = request.method or "GET"
    local attempts = method == "GET" and not request.stream and math.max(1, math.min(retries or 1, 3)) or 1
    for redirect = 0, 5 do
        local result, chunks, prefix
        for attempt = 1, attempts do
            chunks, prefix = {}, ""
            local received = 0
            request.headers = request.headers or handler.get_default_headers()
            request.headers.Cookie = handler:getCookies(request.cookies, target)
            local function sink(chunk)
                if not chunk then return 1 end
                if #prefix < 4096 then prefix = prefix .. chunk:sub(1, 4096 - #prefix) end
                if request.stream then return request.sink(chunk) end
                received = received + #chunk
                if received > 32 * 1024 * 1024 then return nil, "AO3 response is too large" end
                chunks[#chunks + 1] = chunk
                return 1
            end
            local ok, response, status, headers = pcall(function()
                socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
                return https.request{
                    url = target, method = method, headers = request.headers,
                    sink = sink, source = request.source, redirect = false,
                    protocol = "tlsv1_3", options = "all",
                }
            end)
            -- Restore socket defaults on success, failure, and Lua exceptions.
            socketutil:reset_timeout()
            headers = type(headers) == "table" and headers or {}
            status = tonumber(status)
            if not ok or response ~= 1 or not status then
                result = failure(nil, headers, "Could not connect to AO3. Please check your connection and try again.")
                if attempt == attempts then return result end
            else
                handler:setCookies(headers, target)
                result = { status = status, response_headers = headers, response = response }
                break
            end
        end
        local status, headers = result.status, result.response_headers
        local is_redirect = status == 301 or status == 302 or status == 303 or status == 307 or status == 308
        if is_redirect and method == "GET" then
            if type(headers.location) ~= "string" or headers.location == "" then
                return failure(status, headers, "AO3 returned a redirect without a destination.")
            end
            if redirect == 5 then return failure(status, headers, "AO3 redirected too many times. Please try again later.") end
            target = url.absolute(target, headers.location)
            if not target or not target:match("^https?://") then
                return failure(status, headers, "AO3 returned an invalid redirect.")
            end
            -- Streaming downloads may already contain redirect-page bytes.
            if request.stream then request.reset_sink() end
        elseif (status >= 200 and status < 300) or (is_redirect and method ~= "GET") then
            local body = request.stream and prefix or table.concat(chunks)
            if status >= 200 and status < 300 and unavailablePage(body) then
                local unavailable = failure(status, headers, "AO3 returned a maintenance or access-check page. Please try again later.")
                unavailable.retry_later = true
                return unavailable
            end
            if not request.stream then
                local ok, err = request.sink(body)
                if not ok then return failure(status, headers, tostring(err or "Could not read AO3 response.")) end
            end
            if not request.stream then request.sink(nil) end
            result.success = true
            return result
        else
            return failure(status, headers, statusError(status))
        end
    end
end

return M
