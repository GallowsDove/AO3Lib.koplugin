
local logger = require("logger")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local Config = require("ao3lib.core.config")
local util = require("util")
local ltn12 = require("ltn12")
local htmlparser = require("htmlparser")
htmlparser_looplimit = 1000000000

local function getAO3URL()
    return Config:readSetting("AO3_domain")
end

local AO3LibClient = {}

local AO3WebParser = {}

local HTTPQueryHandler = {}

local encodeHelper = {}


function encodeHelper:urlEncode(str)
    if str then
        str = str:gsub("([^%w%-%.%_%~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
    end
    return str
end

function encodeHelper:formEncode(str)
    if str then
        str = string.gsub(str, " ", "+")
        str = str:gsub("([^%w%-%.%_%~%+])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
    end
    return str
end

function encodeHelper:unescapeText(str)
    local unescape_map = {
        ["lt"] = "<",
        ["gt"] = ">",
        ["amp"] = "&",
        ["quot"] = '"',
        ["apos"] = "'",
    }

    local gsub = string.gsub
    local result = gsub(str, "(&(#?)([%d%a]+);)", function(orig, n, s)
        if unescape_map[s] then
            return unescape_map[s]
        elseif n == "#" then -- unescape unicode
            local codepoint
            -- Determine if the code point is written as a decimal or hexadecimal number
            if string.sub(s, 1, 1) == "x" then
                codepoint = tonumber(string.sub(s, 2), 16)
            else
                codepoint = tonumber(s)
            end
            return util.unicodeCodepointToUtf8(codepoint)
        else
            return orig
        end
    end)
    return result
end

function encodeHelper:parseToCodepoints(str)
    return self:unescapeText(str)
end

function encodeHelper:parseFromHTML(str)
    return encodeHelper:parseToCodepoints(
                    str
                        :gsub("<br%s*/?>", "\n") -- Replace <br> tags with new lines
                        :gsub("</p>", "\n\n") -- Add double new lines for paragraph breaks
                        :gsub("<[^>]+>", "") -- Remove other HTML tags
                        :gsub("^%s*(.-)%s*$", "%1") -- Trim whitespace
                )
end

function encodeHelper:generateParametersStringForm(params)
    local form_parts = {}
    for key, value in pairs(params) do
        table.insert(form_parts, encodeHelper:formEncode(key) .. "=" .. encodeHelper:formEncode(value))
    end
    return table.concat(form_parts, "&")
end

function AO3LibClient:requestAO3Token()
    logger.dbg("AO3Lib.koplugin: Requesting AO3 token...")
    local tokenRequestURL = getAO3URL() .. "/token_dispenser.json"

    local response_body = {}

    local headers = HTTPQueryHandler:get_default_headers()
    headers["Accept"] = "application/json, text/javascript, */*; q=0.01"
    headers["Accept-Encoding"] = nil

    local request = {
        url = tokenRequestURL,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = request_result.error or T("Failed to request AO3 token. Status: %1", request_result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)

    local json = require("dkjson")
    local success, token_data = pcall(json.decode, html_body)

    if not success then
        return {
            success = false,
            error = T("Failed to parse AO3 token response."),
        }
    end

    if type(token_data) == "table" and type(token_data.token) == "string" and token_data.token ~= "" then
        return {
            success = true,
            token = token_data.token,
        }
    else
        return {
            success = false,
            error = T("AO3 token not found in response."),
        }
    end
end

function AO3LibClient:startLoggedInSession(username, password)
    local homepage_url = getAO3URL()

    local response_body = {}

    local request = {
        url = homepage_url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = request_result.error or T("Failed to access AO3 homepage. Status: %1", request_result.status or "unknown error"),
        }
    end

    local ao3_token = self:requestAO3Token()

    if not ao3_token.success then
        return {
            success = false,
            error = T("Failed to retrieve AO3 token: %1", ao3_token.error or "unknown error"),
        }
    end

    local headers = HTTPQueryHandler:get_default_headers()
    headers["Content-Type"] = "application/x-www-form-urlencoded"

    local form_data = encodeHelper:generateParametersStringForm({
        ["authenticity_token"] = ao3_token.token,
        ["user[login]"] = username,
        ["user[password]"] = password,
        ["commit"] = "Log+In",
    })

    headers["Content-Length"] = tostring(#form_data)
    local response_body = {}

    local request = {
        url = homepage_url .. "/users/login",
        method = "POST",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        source = ltn12.source.string(form_data),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success or request_result.status ~= 302 then
        return {
            success = false,
            error = request_result.error or T("Login failed. Status: %1", request_result.status or "unknown error"),
        }
    end

    local redirect_url = require("socket.url").absolute(homepage_url, request_result.response_headers["location"] or homepage_url)

    response_body = {}
    local request = {
        url = redirect_url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = request_result.error or T("Failed to complete login redirect. Status: %1", request_result.status or "unknown error"),
        }
    end

    local body_content = table.concat(response_body)

    if body_content:find('<body[^>]*class="[^"]*logged%-in[^"]*"') then
        return {
            success = true,
        }
    else
        return {
            success = false,
            error = T("Login failed. Please check your credentials."),
        }
    end
end

function AO3LibClient:endLoggedInSession()
    logger.dbg("AO3Lib.koplugin: Ending logged-in AO3 session...")
    local authenticity_token = self:requestAO3Token()

    if not authenticity_token.success then
        return {
            success = false,
            error = T("Failed to retrieve AO3 token for logout: %1", authenticity_token.error or "unknown error"),
        }
    end

    local logout_url = T("%1/users/logout", getAO3URL())

    local headers = HTTPQueryHandler:get_default_headers()
    headers["Content-Type"] = "application/x-www-form-urlencoded"

    local form_data = encodeHelper:generateParametersStringForm({
        ["_method"] = "delete",
        ["authenticity_token"] = authenticity_token.token,
    })
    headers["Content-Length"] = tostring(#form_data)

    local response_body = {}

    local request = {
        url = logout_url,
        method = "POST",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        source = ltn12.source.string(form_data),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success or request_result.status ~= 302 then
        return {
            success = false,
            error = request_result.error or T("Failed to perform logout request. Status: %1", request_result.status or "unknown error"),
        }
    end

    local redirect_url = require("socket.url").absolute(getAO3URL(), request_result.response_headers["location"] or getAO3URL())
    response_body = {}

    local request = {
        url = redirect_url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)
    if not request_result.success then
        return {
            success = false,
            error = request_result.error or T("Failed to complete logout redirect. Status: %1", request_result.status or "unknown error"),
        }
    end

    local body_content = table.concat(response_body)
    if body_content:find('<body[^>]*class="[^"]*logged%-out[^"]*"') then
        return {
            success = true,
        }
    else
        return {
            success = false,
            error = T("Logout may have failed; still appears to be logged in."),
        }
    end
end

function AO3LibClient:GetSessionStatus()
    logger.dbg("AO3Lib.koplugin: Checking AO3 session status...")
    local homepage_url = getAO3URL()
    local response_body = {}

    local request = {
        url = homepage_url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = request_result.error or T("Failed to access AO3 homepage. Status: %1", request_result.status or "unknown error"),
        }
    end

    local body_content = table.concat(response_body)
    local root = htmlparser.parse(body_content)

    if not root:select("#main")[1] then
        return { success = false, error = "AO3 returned an unexpected session page. Please try again later." }
    end
    local is_logged_in = #root:select('body.logged-in') > 0

    if is_logged_in then
        local usernames_select = root:select('a[href^="/users/"]')

        -- Filter out any links that do not match the expected "/users/username" pattern
        for index = #usernames_select, 1, -1 do
            local href = usernames_select[index].attributes and usernames_select[index].attributes.href
            if not href or not href:match('^/users/[^/]+$') then
                table.remove(usernames_select, index)
            end
        end

        if  #usernames_select == 0 then
            return {
                session_exists = true,
                success = false,
                error = T("Failed to parse username from AO3 homepage."),
            }
        end


        -- parse username from "/users/username" href
        local username = usernames_select[1].attributes.href:match("/users/([^/]+)")

        return {
            session_exists = true,
            logged_in = true,
            username = username,
            success = true,
        }
    else
        return {
            session_exists = true,
            logged_in = false,
            username = nil,
            success = true,
        }

    end
end

function AO3LibClient:getWorkMetadata(work_id)
    logger.dbg("AO3Lib.koplugin: Fetching metadata for work ID: " .. tostring(work_id))
    local url = T("%1/works/%2", getAO3URL(), work_id)

    local response_body = {}

    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
        cookies = {["view_adult"] = "true" },
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = request_result.error or T("Failed to fetch work metadata. Status: %1", request_result.status or "unknown error");
            status = request_result.status, retry_later = request_result.retry_later,
            response_headers = request_result.response_headers,
        }
    end

    local body = table.concat(response_body)
    local html_root = htmlparser.parse(body)

    local work_metadata = AO3WebParser:parseWorkPage(html_root);
    work_metadata.id = work_id

    return {
        success = true,
        work_metadata = work_metadata,
    }

end

local function downloadNative(self, download_link, filepath, allow_replace, before_commit, staging)
    if type(download_link) ~= "string" or not download_link:match("^https?://") then
        return { success = false, error = "Invalid or missing EPUB download URL." }
    end
    local function occupied()
        if allow_replace ~= false then return false end
        local lfs = require("libs/libkoreader-lfs")
        return (lfs.symlinkattributes or lfs.attributes)(filepath, "mode") ~= nil
    end
    if occupied() then return {success=false, error="The destination is already occupied. Please retry the download to choose a new filename."} end
    -- Write beside the destination, then rename only a complete ZIP download.
    -- A 503 page or interrupted update must never truncate an existing book.
    local token = os.tmpname()
    os.remove(token)
    local partial = staging or (filepath .. ".ao3-" .. token:match("([^/]+)$") .. ".part")
    local file, err = io.open(partial, "wb")
    if not file then return { success = false, error = "Could not create EPUB download: " .. tostring(err) } end
    local request = {
        url = download_link, stream = true,
        headers = { ["Accept"] = "application/epub+zip" },
        sink = function(chunk) return file:write(chunk) end,
        reset_sink = function()
            file:close()
            file = assert(io.open(partial, "wb"))
        end,
    }
    local ok, result = pcall(HTTPQueryHandler.performHTTPRequest, HTTPQueryHandler, request)
    local close_ok, closed, close_err = pcall(file.close, file)
    if not ok or not result.success or not close_ok or not closed then
        os.remove(partial)
        return { success = false, error = ok and (result.error or tostring(close_err)) or "EPUB download failed. Please try again later.",
            status = ok and result.status or nil, retry_later = not ok or result.retry_later,
            response_headers = ok and result.response_headers or nil }
    end
    local check = io.open(partial, "rb")
    local signature = check and check:read(4)
    if check then check:close() end
    local reader
    local valid, is_epub = pcall(function()
        if signature ~= "PK\003\004" then return false end
        reader = require("ffi/archiver").Reader:new()
        if not reader:open(partial) then return false end
        for _ in reader:iterate() do end
        return reader.entries["META-INF/container.xml"] and reader.entries.mimetype
            and reader:extractToMemory("mimetype") == "application/epub+zip"
    end)
    if reader then pcall(function() reader:close() end) end
    if not valid or not is_epub then
        os.remove(partial)
        return { success = false, retry_later = true, error = "AO3 did not return an EPUB file. It may be unavailable or require login. Please try again later." }
    end
    if staging then return {success=true,staged=partial} end
    if occupied() then
        os.remove(partial)
        return {success=false, error="The destination became occupied during the download. Please retry to choose a new filename."}
    end
    if before_commit then
        local checked, allowed, reason = pcall(before_commit)
        if not checked or not allowed then
            os.remove(partial)
            return {success=false, error=checked and (reason or "The book changed during download.") or tostring(allowed)}
        end
    end
    local renamed, rename_err = os.rename(partial, filepath)
    if not renamed then
        os.remove(partial)
        return { success = false, error = "Could not save EPUB: " .. tostring(rename_err) }
    end
    return { success = true, filepath = filepath }
end

-- A metadata table opts into HTML fallback; URL-only callers retain native behavior.
function AO3LibClient:downloadEpub(source, filepath, allow_replace, before_commit, staging)
    if type(source) ~= "table" then
        return downloadNative(self, source, filepath, allow_replace, before_commit, staging)
    end
    local native = downloadNative(self, source.epub_link, filepath, allow_replace, before_commit, staging)
    if native.success or not Config:readSetting("html_download_fallback", false) or not source.html_link then return native end
    local token = os.tmpname(); os.remove(token)
    local partial = staging or (filepath .. ".ao3-" .. token:match("([^/]+)$") .. ".part")
    local fetch_failure
    local function fetch(url)
        assert(type(url)=="string" and url:match("^https?://"), "Invalid HTML or image URL")
        local chunks, size = {}, 0
        local result = HTTPQueryHandler:performHTTPRequest{url=url, sink=function(chunk)
            if chunk then
                size=size+#chunk; assert(size<=16*1024*1024, "HTML or image exceeds 16 MiB")
                chunks[#chunks+1]=chunk
            end
            return 1
        end}
        if not result.success then fetch_failure=result end
        assert(result.success, result.error or "HTML download failed")
        return table.concat(chunks)
    end
    local ok, err = pcall(function()
        if allow_replace==false then
            local lfs=require("libs/libkoreader-lfs")
            assert(not (lfs.symlinkattributes or lfs.attributes)(filepath,"mode"), "The destination is already occupied.")
        end
        require("ao3lib.library.html_epub").convert(fetch(source.html_link), partial, source.id, fetch, source.html_link)
    end)
    if not ok then
        os.remove(partial)
        local failure=fetch_failure or {}
        failure.success=false
        failure.error="HTML fallback failed: "..tostring(err)
        return failure
    end
    if staging then return {success=true,staged=partial} end
    local allowed, reason = true
    if allow_replace==false then
        local lfs=require("libs/libkoreader-lfs")
        allowed=not (lfs.symlinkattributes or lfs.attributes)(filepath,"mode")
        reason="The destination became occupied during download."
    end
    if allowed and before_commit then
        local checked, value, why=pcall(before_commit)
        allowed=checked and value; reason=checked and why or tostring(value)
    end
    if not allowed then os.remove(partial); return {success=false,error=reason or "The book changed during download."} end
    local renamed, why=os.rename(partial,filepath)
    if not renamed then os.remove(partial); return {success=false,error="Could not save EPUB: "..tostring(why)} end
    return {success=true,filepath=filepath}
end

function AO3LibClient:searchByParameters(parameters, page_no)
    local page = page_no or 1 -- Default to the first page if no page is specified
    logger.dbg("AO3Lib.koplugin: Executing work search by parameters. Page no: " .. tostring(page_no))
    local query = {}

    -- Build the query string from the parameters
    for key, value in pairs(parameters) do
        if value == "" then
            table.insert(query, string.format("%s=", encodeHelper:urlEncode(key))) -- Include empty parameters
        elseif type(value) == "table" then
            -- Handle nested parameters (e.g., include_work_search[character_ids][])
            for _, subValue in ipairs(value) do
                table.insert(query, string.format("%s=%s", encodeHelper:urlEncode(key), encodeHelper:urlEncode(subValue))) -- Encode [] as %5B%5D
            end
        else
            table.insert(query, string.format("%s=%s", encodeHelper:urlEncode(key), encodeHelper:urlEncode(value)))
        end
    end
    table.insert(query, "page=" .. page)
    local queryString = table.concat(query, "&")

    -- Construct the full URL
    local global_search = parameters.tag_id == nil or parameters.tag_id == ""
    local url = global_search
        and string.format("%s/works/search?commit=Search&%s", getAO3URL(), queryString)
        or string.format("%s/works?commit=Sort+and+Filter&%s", getAO3URL(), queryString)

    local response_body = {}

    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local response_result = HTTPQueryHandler:performHTTPRequest(request)

    if not response_result.success then
        return {
            success = false,
            error = response_result.error or "AO3 search request failed."
        }
    end

    local html_body = table.concat(response_body)

    local root = htmlparser.parse(html_body)
    local works = AO3WebParser:parseWorkSearchResults(root)

    return {
        success = true,
        works = works,
    }
end

function AO3LibClient:searchByTag(tag_name, sort_by, page_no)
    local page = page_no or 1
    logger.dbg("AO3Lib.koplugin: Executing work search by tag: " .. tostring(tag_name) .. ", page no: " .. tostring(page_no))
    local sort_column = sort_by or "revised_at"

    local encoded_tag_name = tag_name
        :gsub("/", "*s*")
        :gsub("&", "*a*")
        :gsub("%.", "*d*")

    encoded_tag_name = encodeHelper:urlEncode(encoded_tag_name)

    local AO3URL = Config:readSetting("AO3_domain")
    local url = T("%1/tags/%2/works?page=%3&work_search[sort_column]=%4", AO3URL, encoded_tag_name, page, sort_column)

    local response_body = {}
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = request_result.error or T("Search request failed. Status: %1", request_result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)

    local root = htmlparser.parse(html_body)
    local works = AO3WebParser:parseWorkSearchResults(root)

    return {
        success = true,
        result_works = works,
    }
end

function AO3LibClient:searchForTags(search_query, tag_type)
    logger.dbg("AO3Lib.koplugin: Executing tag search for query: " .. tostring(search_query) .. ", tag type: " .. tostring(tag_type))
    if not search_query or search_query == "" then
        return {
            success = false,
            error = "Tag search query cannot be empty"
        }
    end

    tag_type = tag_type or "Fandom"

    local encoded_query = encodeHelper:urlEncode(search_query)

    local url = string.format(
        "%s/tags/search?tag_search%%5Bname%%5D=%s&tag_search%%5Bfandoms%%5D=&tag_search%%5Btype%%5D=%s&tag_search%%5Bwrangling_status%%5D=canonical&tag_search%%5Bsort_column%%5D=uses&tag_search%%5Bsort_direction%%5D=desc&commit=Search+Tags",
        getAO3URL(),
        encoded_query,
        tag_type
    )

    local response_body = {}

    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = request_result.error or T("HTTP tag search request failed. Status: %1", request_result.status or "unknown error"),
        }
    end

    local body = table.concat(response_body)

    local html_root = htmlparser.parse(body)

    local fandoms = AO3WebParser:parseTagSearchResults(html_root)


    return {
        success = true,
        result_tags = fandoms,
    }

end

function AO3LibClient:getWorksFromSeries(series_id, page_no)
    logger.dbg("AO3Lib.koplugin: Fetching works from series ID: " .. tostring(series_id) .. ", page no: " .. tostring(page_no))
    page_no = page_no or 1
    local url = T("%1/series/%2?page=%3", getAO3URL(), series_id, page_no)

    local response_body = {}
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = request_result.error or T("Failed to fetch series works. Status: %1", request_result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)

    local root = htmlparser.parse(html_body)

    local works = AO3WebParser:parseWorkSearchResults(root)

    return {
        success = true,
        works = works,
    }
end

function AO3LibClient:getWorksFromCollection(collection_id, page_no)
    logger.dbg("AO3Lib.koplugin: Fetching works from collection ID: " .. tostring(collection_id) .. ", page no: " .. tostring(page_no))
    page_no = page_no or 1
    local url = T("%1/collections/%2/works?page=%3", getAO3URL(), collection_id, page_no)

    local response_body = {}
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = request_result.error or T("Failed to fetch collection works. Status: %1", request_result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)

    local root = htmlparser.parse(html_body)

    local works = AO3WebParser:parseWorkSearchResults(root)

    return {
        success = true,
        works = works,
    }
end

function AO3LibClient:getWorksFromUserPage(username, pseud, catagory, fandom_id, page_no)
    local url
    if catagory == "gifts" then
        url = T("%1/users/%2/gifts", getAO3URL(), username)
    else
        url = T("%1/users/%2/pseuds/%3/%4", getAO3URL(), username, pseud, catagory)
    end

    page_no = page_no or 1

    logger.dbg("AO3Lib.koplugin: Fetching works from user page. Username: " .. tostring(username) .. ", category: " .. tostring(catagory) .. (fandom_id and (", fandom ID: " .. tostring(fandom_id)) or "") .. ", page no: " .. tostring(page_no))
    local parameters = {["fandom_id"] = fandom_id, ["page"] = page_no}

    local parameter_string = table.concat(
        (function()
            local parts = {}
            for key, value in pairs(parameters) do
                if value then
                    table.insert(parts, string.format("%s=%s", key, value))
                end
            end
            return parts
        end)(),
        "&"
    )

    url = url .. "?" .. parameter_string


    local response_body = {}
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = request_result.error or T("Failed to fetch user works. Status: %1", request_result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)

    local root = htmlparser.parse(html_body)

    local works = nil

    if catagory == "bookmarks" then
        works = AO3WebParser:parseUserBookmarks(root)
    else
         works = AO3WebParser:parseWorkSearchResults(root)
    end

    return {
        success = true,
        works = works,
    }

end

function AO3LibClient:getWorksFromAccountHistory(marked_for_later, page_no)

    local login_status = self:GetSessionStatus()

    if not login_status.success or not login_status.logged_in then
        return {
            success = false,
            error = T("User is not logged in. Please log in to access " .. (marked_for_later and "marked for later list." or "account history.")),
        }
    end

    local username = login_status.username

    local url

    url = T("%1/users/%2/readings", getAO3URL(), username)

    page_no = page_no or 1

    logger.dbg("AO3Lib.koplugin: Fetching works from account history page. Username: " .. tostring(username) .. ", page no: " .. tostring(page_no))
    local parameters = {["show"] = marked_for_later and "to-read" or "",["page"] = page_no}

    local parameter_string = table.concat(
        (function()
            local parts = {}
            for key, value in pairs(parameters) do
                if value then
                    table.insert(parts, string.format("%s=%s", key, value))
                end
            end
            return parts
        end)(),
        "&"
    )

    url = url .. "?" .. parameter_string


    local response_body = {}
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = request_result.error or T("Failed to fetch account history. Status: %1", request_result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)

    local root = htmlparser.parse(html_body)

    local works = nil

    works = AO3WebParser:parseAccountHistory(root)

    return {
        success = true,
        works = works,
    }

end

function AO3LibClient:getUserSeries(username, pseud, page_no)
    page_no = page_no or 1
    logger.dbg("AO3Lib.koplugin: Fetching series for user: " .. tostring(username) .. ", page no: " .. tostring(page_no))
    local url = T("%1/users/%2/pseuds/%3/series?page=%4", getAO3URL(), username, pseud, page_no)

    local response_body = {}
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = request_result.error or T("Failed to fetch user series. Status: %1", request_result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)

    local root = htmlparser.parse(html_body)

    local series = AO3WebParser:parseUserSeriesPage(root)

    return {
        success = true,
        series = series,
    }
end

function AO3LibClient:getUserCollections(username, page_no)
    page_no = page_no or 1
    logger.dbg("AO3Lib.koplugin: Fetching collections for user: " .. tostring(username) .. ", page no: " .. tostring(page_no))
    local url = T("%1/users/%2/collections?page=%3", getAO3URL(), username, page_no)

    local response_body = {}
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = request_result.error or T("Failed to fetch user collections. Status: %1", request_result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)

    local root = htmlparser.parse(html_body)

    local collections = AO3WebParser:parseUserCollectionsPage(root)

    return {
        success = true,
        collections = collections,
    }
end

function AO3LibClient:getUserData(username, pseud)
    local url = T("%1/users/%2/pseuds/%3", getAO3URL(),username, pseud)

    local response_body = {}
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if request_result.status == 404 then
        return {
            success = false,
            error = T("User '%1' not found.", username),
        }
    end

    if not request_result.success then
        return {
            success = false,
            error = request_result.error or T("Failed to fetch user data. Status: %1", request_result.status or "unknown error"),
        }
    end


    local html_body = table.concat(response_body)

    local root = htmlparser.parse(html_body)
    local user_data = AO3WebParser:parseUserPage(root)
    user_data.username = username

    return {
        success = true,
        user_data = user_data,
    }

end

function AO3LibClient:getUserPseuds(username)
    local url = T("%1/users/%2/pseuds", getAO3URL(), username)

    local response_body = {}
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if request_result.status == 404 then
        return {
            success = false,
            error = T("User '%1' not found.", username),
        }
    end

    if not request_result.success then
        return {
            success = false,
            error = request_result.error or T("Failed to fetch user pseuds. Status: %1", request_result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)
    local root = htmlparser.parse(html_body)
    local pseuds = AO3WebParser:parseUserPseuds(root)

    return {
        success = true,
        pseuds = pseuds,
    }
end

function AO3LibClient:getAccountPseudID(username)
    local url = T("%1/users/%2/pseuds/%2/edit", getAO3URL(), username)

    local response_body = {}
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if request_result.status == 404 then
        return {
            success = false,
            error = T("Pseud edit page for '%1' not found.", username),
        }
    end

    if not request_result.success then
        return {
            success = false,
            error = request_result.error or T("Failed to fetch accound pseud ID. Status: %1", request_result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)
    local root = htmlparser.parse(html_body)
    local pseud_id = AO3WebParser:parseAccountPseudID(root)

    if not pseud_id then
        return {
            success = false,
            error = T("Failed to parse accound pseud ID"),
        }
    end

    return {
        success = true,
        pseud_id = pseud_id,
    }
end

function AO3LibClient:searchForUsers(search_query, page_no)
    logger.dbg("AO3Lib.koplugin: Executing user search for query: " .. tostring(search_query) .. ", page no: " .. tostring(page_no))
    if not search_query or search_query == "" then
        return {
            success = false,
            error = "User search query cannot be empty"
        }
    end

    page_no = page_no or 1

    local encoded_query = encodeHelper:urlEncode(search_query)

    local url = string.format(
        "%s/people/search?people_search%%5Bquery%%5D=%s&page=%d",
        getAO3URL(),
        encoded_query,
        page_no
    )

    local response_body = {}

    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = request_result.error or T("HTTP user search request failed. Status: %1", request_result.status or "unknown error"),
        }
    end

    local body = table.concat(response_body)
    local html_root = htmlparser.parse(body)

    local users = AO3WebParser:parseUserSearchResults(html_root)

    return {
        success = true,
        result_users = users,
    }
end

function AO3LibClient:searchForCollections(search_query)
    logger.dbg("AO3Lib.koplugin: Executing collection search for query: " .. tostring(search_query))
    if (not search_query or search_query == "") then
        return {
            success = false,
            error = "Collection search query cannot be empty"
        }
    end

    local encoded_query = encodeHelper:urlEncode(search_query)

    local url = string.format(
        "%s/autocomplete/collection_title?term=%s",
        getAO3URL(),
        encoded_query
    )

    local response_body = {}
    local headers = HTTPQueryHandler:get_default_headers()
    headers["Accept"] = "application/json, text/javascript, */*; q=0.01"
    headers["X-Requested-With"] = "XMLHttpRequest"
    headers["Accept-Encoding"] = nil

    local request = {
        url = url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = request_result.error or T("HTTP collection search request failed. Status: %1", request_result.status or "unknown error"),
        }
    end

    local results = table.concat(response_body)
    local json = require("dkjson")
    local success, collection_results = pcall(json.decode, results)

    if not success or type(collection_results) ~= "table" then
        return {
            success = false,
            error = T("Failed to parse collection search results."),
        }
    end

    return {
        success = true,
        collections = collection_results,
    }

end

function AO3LibClient:kudosWork(work_id)
    logger.dbg("AO3Lib.koplugin: Sending kudos to work. Work ID: " .. tostring(work_id))
    local login_status = self:GetSessionStatus()
    if not login_status.success then
        return {
            success = false,
            error = T("Failed to check login status: %1", login_status.error or "unknown error"),
        }
    end

    if not login_status.logged_in then
        return {
            success = false,
            error = T("User must be logged in to kudos works."),
        }
    end

    local authenticity_token_request = self:requestAO3Token()

    if not authenticity_token_request.success then
        return {
            success = false,
            error = T("Failed to retrieve AO3 token for kudos: %1", authenticity_token_request.error or "unknown error"),
        }
    end

    local authenticity_token = authenticity_token_request.token

    local kudos_url = T("%1/kudos.js", getAO3URL())

    local response_body = {}
    local headers = HTTPQueryHandler:get_default_headers()
    headers["Content-Type"] = "application/x-www-form-urlencoded"

    local form_data = encodeHelper:generateParametersStringForm({
        ["authenticity_token"] = authenticity_token,
        ["kudo[commentable_id]"] = tostring(work_id),
        ["kudo[commentable_type]"] = "Work",
    })
    headers["Content-Length"] = tostring(#form_data)


    local request = {
        url = kudos_url,
        method = "POST",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        source = ltn12.source.string(form_data),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if request_result.success and request_result.status == 201 then
        return {
            success = true,
        }
    end

    if request_result.status == 422 then
        return {
            success = false,
            error = T("You have already left kudos here. :)"),
        }
    end

    return {
        success = false,
        error = request_result.error or T("Failed to kudos work. Status: %1", request_result.status or "unknown error"),
    }
end

function AO3LibClient:commentOnWork(comment_content, work_id, chapter_id)
    logger.dbg("AO3Lib.koplugin: Posting comment on work. Work ID: " .. tostring(work_id) .. ", chapter ID: " .. tostring(chapter_id))

    if not comment_content or comment_content == "" then
        return {
            success = false,
            error = T("Comment content cannot be empty."),
        }
    end

    if comment_content:len() > 10000 then
        return {
            success = false,
            error = T("Comment content exceeds maximum length of 10,000 characters."),
        }
    end

    local login_status = self:GetSessionStatus()
    if not login_status.success then
        return {
            success = false,
            error = T("Failed to check login status: %1", login_status.error or "unknown error"),
        }
    end

    if not login_status.logged_in then
        return {
            success = false,
            error = T("User must be logged in to comment on works."),
        }
    end

    local comment_url = getAO3URL()
        .. ((chapter_id and ("/chapters/" .. chapter_id)) or ("/works/" .. work_id))
        .. "/comments"

    local response_body = {}

    local request = {
        url = comment_url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
        cookies = { ["view_adult"] = "true"}
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = request_result.error or T("Failed to fetch comment comment form. Status: %1", request_result.status or "unknown error"),
        }
    end


    local body = table.concat(response_body)
    local html_root = htmlparser.parse(body)

    local form = html_root:select("#comment_for_" .. (chapter_id or work_id))[1]
    local token_field = form and form:select("[name='authenticity_token']")[1]
    local pseud_field = form and form:select("[name='comment[pseud_id]']")[1]
    local authenticity_token = token_field and token_field.attributes and token_field.attributes.value
    local pseud_id = pseud_field and pseud_field.attributes and pseud_field.attributes.value

    if not authenticity_token or not pseud_id then
        return {
            success = false,
            error = T("Failed to retrieve necessary tokens for commenting from comment form."),
        }
    end

    local headers = HTTPQueryHandler:get_default_headers()
    headers["Content-Type"] = "application/x-www-form-urlencoded"
    headers["Referer"] = comment_url

    local custom_cookies = {
        ["user_credentials"] = "1",
        ["view_adult"] = "true",
    }

    local form_data  = encodeHelper:generateParametersStringForm({
        ["authenticity_token"] = authenticity_token,
        ["comment[pseud_id]"] = pseud_id,
        ["comment[comment_content]"] = comment_content,
        ["controller_name"] = "comments",
        ["commit"] = "Comment",
    })

    headers["Content-Length"] = tostring(#form_data)

    local request = {
        url = comment_url,
        method = "POST",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        source = ltn12.source.string(form_data),
        cookies = custom_cookies,
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if not request_result.success then
        return {
            success = false,
            error = request_result.error or T("Failed to post comment. Status: %1", request_result.status or "unknown error"),
        }
    end

    if request_result.response == 1 then
        return {
            success = true,
        }
    end

    return {
        success = false;
        error = request_result.error or T("Failed to post comment. Status: %1", request_result.status or "unknown error"),
    }
end

function AO3LibClient:markForLaterWork(work_id, later_or_read)
    logger.dbg("AO3Lib.koplugin: Marking work. Work ID: " .. tostring(work_id))
    local login_status = self:GetSessionStatus()
    if not login_status.success then
        return {
            success = false,
            error = T("Failed to check login status: %1", login_status.error or "unknown error"),
        }
    end

    if not login_status.logged_in then
        return {
            success = false,
            error = T("User must be logged in to mark work."),
        }
    end

    local authenticity_token_request = self:requestAO3Token()

    if not authenticity_token_request.success then
        return {
            success = false,
            error = T("Failed to retrieve AO3 token for marking work: %1", authenticity_token_request.error or "unknown error"),
        }
    end

    local authenticity_token = authenticity_token_request.token

    -- Mark As Read True, Mark For Later False
    local kudos_url = T("%1/works/%2/%3", getAO3URL(), work_id, later_or_read and "mark_as_read" or "mark_for_later")

    local response_body = {}
    local headers = HTTPQueryHandler:get_default_headers()
    headers["Content-Type"] = "application/x-www-form-urlencoded"

    local form_data = encodeHelper:generateParametersStringForm({
        ["authenticity_token"] = authenticity_token,
        ["_method"] = "patch"
    })
    headers["Content-Length"] = tostring(#form_data)


    local request = {
        url = kudos_url,
        method = "POST",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        source = ltn12.source.string(form_data),
    }

    local request_result = HTTPQueryHandler:performHTTPRequest(request)

    if request_result.success and request_result.status == 302 then
        return {
            success = true,
        }
    end

    return {
        success = false,
        error = request_result.error or T("Failed to mark work. Status: %1", request_result.status or "unknown error"),
    }
end

function AO3LibClient:setWorkSubscription(work_id, subscription_id)
    logger.dbg("AO3Lib.koplugin: Setting subscription. Work ID: " .. tostring(work_id))

    local login_status = self:GetSessionStatus()
    if not login_status.success then
        return {
            success = false,
            error = T("Failed to check login status: %1", login_status.error or "unknown error"),
        }
    end

    if not login_status.logged_in then
        return {
            success = false,
            error = T("User must be logged in to subscribe."),
        }
    end

    local token_request = self:requestAO3Token()
    if not token_request.success then
        return {
            success = false,
            error = T("Failed to retrieve AO3 token: %1", token_request.error or "unknown error"),
        }
    end

    local authenticity_token = token_request.token

    local url
    local form

    if not subscription_id then
        url = T("%1/users/%2/subscriptions", getAO3URL(), login_status.username)

        form = encodeHelper:generateParametersStringForm({
            ["authenticity_token"] = authenticity_token,
            ["subscription[subscribable_id]"] = tostring(work_id),
            ["subscription[subscribable_type]"] = "Work",
        })
    else
        if not subscription_id then
            return {
                success = false,
                error = T("Subscription ID required to unsubscribe."),
            }
        end

        url = T("%1/users/%2/subscriptions/%3",
            getAO3URL(),
            login_status.username,
            subscription_id
        )

        form = encodeHelper:generateParametersStringForm({
            ["authenticity_token"] = authenticity_token,
            ["_method"] = "delete",
            ["subscription[subscribable_id]"] = tostring(work_id),
            ["subscription[subscribable_type]"] = "Work",
        })
    end

    local response_body = {}
    local headers = HTTPQueryHandler:get_default_headers()
    headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
    headers["Content-Length"] = tostring(#form)
    headers["Accept"] = "application/json, text/javascript, */*; q=0.01"
    headers["X-Requested-With"] = "XMLHttpRequest"
    headers["X-CSRF-Token"] = authenticity_token

    local request = {
        url = url,
        method = "POST",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        source = ltn12.source.string(form),
    }

    local result = HTTPQueryHandler:performHTTPRequest(request)

    local response_text = table.concat(response_body)

    if result.success and result.status == 201 then
        local json = require("dkjson")
        local decoded, _, err = json.decode(response_text)

        if type(decoded) == "table" and (type(decoded.item_id) == "number" or type(decoded.item_id) == "string") then
            return {
                success = true,
                subscription_id = tostring(decoded.item_id),
            }
        end

        return {
            success = false,
            error = "AO3 returned an invalid subscription response. Please check the subscription before trying again.",
        }
    end
    if result.success and (result.status == 302 or result.status == 200) then
        return {
            success = true
        }
    end

    return {
        success = false,
        error = result.error or T("Failed to update subscription. Status: %1", result.status or "unknown error"),
    }
end

function AO3LibClient:getUsersWorkBookmark(work_id)
    logger.dbg("AO3Lib.koplugin: Fetching bookmark for work. Work ID: " .. tostring(work_id))

    local login_status = self:GetSessionStatus()
    if not login_status.success then
        return {
            success = false,
            error = T("Failed to check login status: %1", login_status.error or "unknown error"),
        }
    end

    if not login_status.logged_in then
        return {
            success = false,
            error = T("User must be logged in to fetch bookmarks."),
        }
    end

    local url = T("%1/works/%2/bookmarks", getAO3URL(), work_id)

    local response_body = {}

    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local result = HTTPQueryHandler:performHTTPRequest(request)

    if not result.success then
        return {
            success = false,
            error = result.error or T("Failed to fetch bookmark. Status: %1", result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)
    local root = htmlparser.parse(html_body)


    local bookmark_trigger_button = root:select("a.bookmark_form_trigger_for_" .. work_id)[1]
    if not bookmark_trigger_button or not bookmark_trigger_button.attributes or not bookmark_trigger_button.attributes.href then
        return {
            success = false,
            error = T("Bookmark not found from this user for work ID: %1", work_id),
        }
    end

    local bookmark_form_url = T("%1%2", getAO3URL(), bookmark_trigger_button.attributes["href"])
    response_body = {}

    local request = {
        url = bookmark_form_url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }

    local result = HTTPQueryHandler:performHTTPRequest(request)

    if not result.success then
        return {
            success = false,
            error = result.error or T("Failed to fetch bookmark form. Status: %1", result.status or "unknown error"),
        }
    end

    local html_body = table.concat(response_body)
    logger.dbg("AO3Lib.koplugin: Bookmark form response body: " .. tostring(html_body))
    -- look foor bookmark_div.html("...") and parse html

    local root = htmlparser.parse(html_body)

    local bookmark_data = AO3WebParser:parseUsersWorkBookmark(root)

    return {
        success = true,
        bookmark_data = bookmark_data,
        bookmark_id = bookmark_trigger_button.attributes["href"]:match("/bookmarks/(%d+)/edit")
    }
end

function AO3LibClient:updateBookmark(work_id, bookmark_id, notes, tags, collections, private, rec)
    logger.dbg("AO3Lib.koplugin: Updating bookmark. Work ID: " .. tostring(work_id))

    local login_status = self:GetSessionStatus()
    if not login_status.success then
        return {
            success = false,
            error = T("Failed to check login status: %1", login_status.error or "unknown error"),
        }
    end

    if not login_status.logged_in then
        return {
            success = false,
            error = T("User must be logged in to edit bookmarks."),
        }
    end

    local token_request = self:requestAO3Token()
    if not token_request.success then
        return {
            success = false,
            error = T("Failed to retrieve AO3 token: %1", token_request.error or "unknown error"),
        }
    end

    local authenticity_token = token_request.token

    local url
    local form_data = {
        ["authenticity_token"] = authenticity_token,
        ["bookmark[bookmarker_notes]"] = notes or "",
        ["bookmark[tag_string]"] = tags or "",
        ["bookmark[collection_names]"] = collections or "",
        ["bookmark[private]"] = private and "1" or "0",
        ["bookmark[rec]"] = rec and "1" or "0",
    }

    if bookmark_id then
        url = T("%1/bookmarks/%2", getAO3URL(), bookmark_id)
        form_data["_method"] = "put"
        form_data["commit"] = "Update"
    else
        url = T("%1/works/%2/bookmarks", getAO3URL(), work_id)
        form_data["commit"] = "Create"

        local pseud_result = AO3LibClient:getAccountPseudID(login_status.username)

        if not pseud_result.success then
            return {
                success = false,
                error = T("Error: %1", pseud_result.error)
            }
        end

        form_data["bookmark[pseud_id]"] = tostring(pseud_result.pseud_id)
    end

    local form = encodeHelper:generateParametersStringForm(form_data)

    local response_body = {}
    local headers = HTTPQueryHandler:get_default_headers()
    headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
    headers["Content-Length"] = tostring(#form)
    headers["X-CSRF-Token"] = authenticity_token

    local request = {
        url = url,
        method = "POST",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        source = ltn12.source.string(form),
    }

    local result = HTTPQueryHandler:performHTTPRequest(request)

    if result.success and (result.status == 302 or result.status == 200) then
        local body_content = table.concat(response_body)
        local root = htmlparser.parse(body_content)

        local errors = root:select("#error")
        if #errors == 0 then errors = root:select("div.error") end
        if #errors > 0 then
            local error_message = errors[1]:getcontent()
            -- remove htmml tags from error message and convert code points eg &#39; to characters
            error_message = error_message:gsub("<[^>]+>", "")
            error_message = encodeHelper:unescapeText(error_message)

            return {
                success = false,
                error = T("Failed to update bookmark. Error message: %1", error_message or "unknown error"),
            }
        end

        return {
            success = true,
            bookmark_id = result.response_headers and result.response_headers["location"] and result.response_headers["location"]:match("/bookmarks/(%d+)")
        }
    end

    return {
        success = false,
        error = result.error or T("Failed to update bookmark. Status: %1", result.status or "unknown error"),
    }
end

function AO3LibClient:deleteBookmark(bookmark_id)
    logger.dbg("AO3Lib.koplugin: Deleting bookmark. Bookmark ID: " .. tostring(bookmark_id))

    local login_status = self:GetSessionStatus()
    if not login_status.success then
        return {
            success = false,
            error = T("Failed to check login status: %1", login_status.error or "unknown error"),
        }
    end

    if not login_status.logged_in then
        return {
            success = false,
            error = T("User must be logged in to delete bookmarks."),
        }
    end

    local token_request = self:requestAO3Token()
    if not token_request.success then
        return {
            success = false,
            error = T("Failed to retrieve AO3 token: %1", token_request.error or "unknown error"),
        }
    end

    local authenticity_token = token_request.token

    local url = T("%1/bookmarks/%2", getAO3URL(), bookmark_id)
    local form_data = {
        ["authenticity_token"] = authenticity_token,
        ["_method"] = "delete"
    }

    local form = encodeHelper:generateParametersStringForm(form_data)

    local response_body = {}
    local headers = HTTPQueryHandler:get_default_headers()
    headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
    headers["Content-Length"] = tostring(#form)
    headers["X-CSRF-Token"] = authenticity_token

    local request = {
        url = url,
        method = "POST",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        source = ltn12.source.string(form),
    }

    local result = HTTPQueryHandler:performHTTPRequest(request)

    if result.success and result.status == 302 then
        return {
            success = true,
        }
    end

    return {
        success = false,
        error = result.error or T("Failed to update bookmark. Status: %1", result.status or "unknown error"),
    }
end


-- AO3WebParser
-- Counts are shared by searches, bookmarks and history. Keep an unknown
-- count unknown rather than treating the loaded batch as the whole library.
function AO3WebParser:parseWorkCount(root)
    for _,selector in ipairs({"#main > h3","#main > h2"}) do
        for _,heading in ipairs(root:select(selector)) do
            local text=encodeHelper:parseFromHTML(heading:getcontent())
            local count=text:match("([%d,]+)%s+Found")
                or text:match("of%s+([%d,]+)%s+[Ww]orks")
                or text:match("of%s+([%d,]+)%s+[Bb]ookmarks")
                or text:match("([%d,]+)%s+[Ww]orks")
                or text:match("([%d,]+)%s+[Bb]ookmarks")
                or text:match("History%s*%(([%d,]+)%)")
            if count then return tonumber((count:gsub(",",""))) end
        end
    end
end

function AO3WebParser:parseWorkSearchResults(root)
    local works = {total=self:parseWorkCount(root)}
    local elements = root:select("li.work")
    local count = 1

    for _, element in ipairs(elements) do
        local work = self:parseWorkElement(element)
        -- Keep unavailable entries in their AO3 result slots so numbered
        -- jumps and neighbouring result batches cannot shift their indices.
        table.insert(works,count,work or {is_unavailable=true})
        count=count+1
    end

    return works
end

function AO3WebParser:parseUserBookmarks(root)
    local bookmarks = {total=self:parseWorkCount(root)}
    local elements = root:select("li.bookmark")

    local count = 1

    for _, element in ipairs(elements) do
        -- Check if bookmark is for deleted fic, if so, set title accordingly
        local deletedElement = element:select(".message")[1]
        if deletedElement and deletedElement:getcontent():find("This has been deleted, sorry!") then
            local work = {}
            work.title = "Deleted Work"
            work.id = nil
            work.is_deleted = true
            table.insert(bookmarks, count, work)
            count = count + 1

        else
            local work = self:parseWorkElement(element)
            table.insert(bookmarks,count,work or {is_unavailable=true})
            count=count+1
        end
    end

    return bookmarks

end

function AO3WebParser:parseUserSeriesPage(root)
    local series_list = {}
    local elements = root:select("li.series")

    local count = 1

    for _, element in ipairs(elements) do
        local titleElement = element:select(".heading > a")[1]
        if titleElement then
            local href = titleElement.attributes.href
            local id = tonumber(href:match("/series/(%d+)"))
            local title = titleElement:getcontent()

            local authorElement = element:select(".heading > a[rel='author']")[1]
            local author = authorElement and encodeHelper:parseToCodepoints(authorElement:getcontent()) or nil

            local dateElement = element:select(".datetime")[1]

            local date_posted = dateElement and encodeHelper:parseToCodepoints(dateElement:getcontent()) or ""

            local fandomElements = element:select(".fandoms > a")
            local fandoms = {}
            for _, fandomElement in pairs(fandomElements) do
                local content = fandomElement:getcontent()
                if content then
                    table.insert(fandoms, encodeHelper:parseToCodepoints(content))
                end
            end

            local warningElements = element:select(".warnings > strong > a")

            local warnings = {}

            for _, warningElement in pairs(warningElements) do
                local content = warningElement:getcontent()
                if content then
                    table.insert(warnings, encodeHelper:parseToCodepoints(content))
                end
            end

            local relationshipsElements = element:select(".relationships > a")
            local relationships = {}
            for _, relationshipElement in pairs(relationshipsElements) do
                local content = relationshipElement:getcontent()
                if content then
                    table.insert(relationships, encodeHelper:parseToCodepoints(content))
                end
            end

            local charactersElements = element:select(".characters > a")
            local characters = {}

            for _, characterElement in pairs(charactersElements) do
                local content = characterElement:getcontent()
                if content then
                    table.insert(characters, encodeHelper:parseToCodepoints(content))
                end
            end

            local otherTagsElements = element:select(".freeforms > a")
            local other_tags = {}

            for _, otherTagElement in pairs(otherTagsElements) do
                local content = otherTagElement:getcontent()
                if content then
                    table.insert(other_tags, encodeHelper:parseToCodepoints(content))
                end
            end

            local summaryElement = element:select(".summary")[1]
            local summary = summaryElement and encodeHelper:parseFromHTML(summaryElement:getcontent())

            local wordCountElement = element:select("dd.words")[1]
            logger.dbg(wordCountElement and wordCountElement:getcontent():gsub(",", "") or "No word count element found")
            local word_count = wordCountElement and tonumber(wordCountElement:getcontent():gsub(",", ""), 10) or 0

            local workCountElement = element:select("dd.works")[1]
            local work_count = workCountElement and tonumber(workCountElement:getcontent():gsub(",", ""), 10) or 0

            local bookmark_countElement = element:select("dd.bookmarks")[1]
            local bookmark_count = bookmark_countElement and tonumber(bookmark_countElement:getcontent():gsub(",", ""), 10) or 0

            local series = {
                id = id,
                title = title,
                author = author,
                date_posted = date_posted,
                fandoms = fandoms,
                warnings = warnings,
                relationships = relationships,
                characters = characters,
                tags = other_tags,
                summary = summary,
                word_count = word_count,
                work_count = work_count,
                bookmark_count = bookmark_count,
            }

            table.insert(series_list, count, series)
            count = count + 1
        end
    end

    return series_list
end

function AO3WebParser:parseUserCollectionsPage(root)
    local collection_list = {}
    local elements = root:select("li.collection")

    local count = 1

    for _, element in ipairs(elements) do
        local titleElement = element:select(".heading > a:not([class])")[1]
        if titleElement then

            --works
            --bookmarked items
            --prompts
            --challenges/subcollections

            local href = titleElement.attributes.href
            local id = href:match("/collections/([%w_-]+)")
            local title = titleElement:getcontent()

            local authorElements = element:select(".heading > a.owner")
            local author_table = {}
            for _, author in pairs(authorElements) do
                table.insert(author_table, encodeHelper:parseToCodepoints(author:getcontent()))
            end
            authorElements = element:select(".heading > a.mod")
            for _, author in pairs(authorElements) do
                table.insert(author_table, encodeHelper:parseToCodepoints(author:getcontent()))
            end
            local author = #author_table > 0 and table.concat(author_table, ", ") or nil

            local dateElement = element:select(".datetime")[1]

            local date_posted = dateElement and encodeHelper:parseToCodepoints(dateElement:getcontent()) or ""

            local tagElements = element:select(".tags > a.tag")
            local tags = {}

            for _, tagElement in pairs(tagElements) do
                local content = tagElement:getcontent()
                if content then
                    table.insert(tags, encodeHelper:parseToCodepoints(content))
                end
            end

            local typeElement = element:select("p.type")[1]
            local type = typeElement:getcontent():gsub("^%s*(.-)%s*$", "%1")

            local summaryElement = element:select(".summary")[1]
            local summary = (type and (type.." ") or "") .. (summaryElement and encodeHelper:parseToCodepoints(summaryElement:getcontent()
                :gsub("<br%s*/?>", "\n") -- Replace <br> tags with new lines
                :gsub("</p>", "\n\n") -- Add double new lines for paragraph breaks
                :gsub("<[^>]+>", "") -- Remove other HTML tags
                :gsub("^%s*(.-)%s*$", "%1") -- Trim whitespace) or ""
            ))

            local workCountElement = element:select("dd.works > a")[1]
            local work_count = workCountElement and tonumber(workCountElement:getcontent():gsub(",", ""), 10) or 0

            local collection = {
                id = id,
                title = title,
                author = author,
                date_posted = date_posted,
                tags = tags,
                summary = summary,
                work_count = work_count,
            }

            table.insert(collection_list, count, collection)
            count = count + 1
        end
    end

    return collection_list
end

function AO3WebParser:parseAccountHistory(root)
    local works = {}
    local elements = root:select("li.work")

    local count = 1

    for _, element in ipairs(elements) do
        local work = self:parseWorkElement(element)
        -- Keep unavailable entries in their AO3 result slots so numbered
        -- jumps and neighbouring result batches cannot shift their indices.
        table.insert(works,count,work or {is_unavailable=true})
        count=count+1
    end

    works["total"] = self:parseWorkCount(root) or -1

    return works
end

-- AO3 lists each membership separately: a work can belong to several series.
function AO3WebParser:parseWorkSeries(root)
    local rows=root:select("ul.series > li")
    local positions=root:select("dd.series .position")
    if #positions==0 then positions=root:select("dd.series") end
    local out,seen={},{}
    local function collect(items)
        for _,row in ipairs(items) do
            local plain=encodeHelper:parseFromHTML(row:getcontent())
            local position=plain:match("^%s*Part%s+([%d%.]+)%s+of%s")
            for _,link in ipairs(row:select("a")) do
                local id=(link.attributes.href or ""):match("/series/(%d+)")
                if id and not seen[id] then
                    local title=encodeHelper:parseFromHTML(link:getcontent())
                    if title~="" then
                        seen[id]=true
                        out[#out+1]={id=tonumber(id),title=title,position=position}
                    end
                end
            end
        end
    end
    collect(rows);collect(positions)
    return out
end

function AO3WebParser:parseWorkElement(element)
    local titleElement = element:select("h4.heading > a")[1] or element:select("h4.heading")[1]
    local restrictedElement = element:select("img[title='Restricted']")[1]
    local authorElements = element:select(".heading > a[rel='author']")
    local giftElements = element:select(".heading > a[href$='/gifts']")
    local summaryElement = element:select(".summary")[1]
    local tagsElement = element:select(".tags > .freeforms")
    local relationshipsElement = element:select(".tags > .relationships")
    local charactersElement = element:select(".tags > .characters")
    local warningsElement = element:select(".tags > .warnings")
    local fandomsElement = element:select(".fandoms")[1]
    local dateElement = element:select(".datetime")[1]
    local languageElement = element:select("dd.language")[1]
    local wordsElement = element:select("dd.words")[1]
    local chaptersElement = element:select("dd.chapters")[1]
    local hitsElement = element:select("dd.hits")[1]
    local commentsElement = element:select("dd.comments")[1]
    local kudosElement = element:select("dd.kudos")[1]
    local bookmarksElement = element:select("dd.bookmarks")[1]
    local ratingElement = element:select(".rating")[1]
    local categoryElement = element:select(".category")[1]
    local iswipElement = element:select(".iswip")[1]

    if titleElement then
        -- Extract the work ID from the href attribute
        local href = titleElement.attributes.href or ""
        local id = tonumber(href:match("/works/(%d+)")) -- Extract the numeric ID and convert to number
        local isRestricted = restrictedElement and true or false -- Set to true if restrictedElement exists, otherwise false

        -- Extract and clean tags
        local tags = {}
        if tagsElement then
            for __, tagset in ipairs(tagsElement) do
                for _, tag in ipairs(tagset:select("a")) do
                    local content = encodeHelper:parseToCodepoints(tag:getcontent())
                    if content then
                        table.insert(tags, content)
                    end
                end
            end
        end

        -- Extract and clean relationships
        local relationships = {}
        if relationshipsElement then
            for __, relationshipset in ipairs(relationshipsElement) do
                for _, relationship in ipairs(relationshipset:select("a")) do
                    local content = encodeHelper:parseToCodepoints(relationship:getcontent())
                    if content then
                        table.insert(relationships, content)
                    end
                end
            end
        end

        -- Extract and clean characters
        local characters = {}
        if charactersElement then
            for __, characterset in ipairs(charactersElement) do
                for _, character in ipairs(characterset:select("a")) do
                    local content = encodeHelper:parseToCodepoints(character:getcontent())
                    if content then
                        table.insert(characters, content)
                    end
                end
            end
        end

        -- Extract and clean warnings
        local warnings = {}
        if warningsElement then
            for __, warningset in ipairs(warningsElement) do
                for _, warning in ipairs(warningset:select("strong > a")) do
                    local content = encodeHelper:parseToCodepoints(warning:getcontent())
                    if content then
                        table.insert(warnings, content)
                    end
                end
            end
        end

        -- Extract and clean fandoms
        local fandoms = {}
        if fandomsElement then
            for _, fandom in ipairs(fandomsElement:select("a")) do
                local content = encodeHelper:parseToCodepoints(fandom:getcontent())
                if content then
                    table.insert(fandoms, content)
                end
            end
        end

        -- Extract additional metadata
        local date = dateElement and encodeHelper:parseToCodepoints(dateElement:getcontent()) or "N/A"
        local language = languageElement and encodeHelper:parseToCodepoints(languageElement:getcontent()) or "N/A"
        local words = wordsElement and encodeHelper:parseToCodepoints(wordsElement:getcontent()) or "N/A"
        local chapters = chaptersElement and encodeHelper:parseToCodepoints(chaptersElement:getcontent():gsub("<[^>]+>", ""))
            or "N/A"
        local hits = hitsElement and encodeHelper:parseToCodepoints(hitsElement:getcontent():gsub("<[^>]+>", "")) or "0"
        local comments = commentsElement and encodeHelper:parseToCodepoints(commentsElement:getcontent():gsub("<[^>]+>", ""))
            or "0"
        local kudos = kudosElement and encodeHelper:parseToCodepoints(kudosElement:getcontent():gsub("<[^>]+>", "")) or "0"
        local bookmarks = bookmarksElement and encodeHelper:parseToCodepoints(bookmarksElement:getcontent():gsub("<[^>]+>", ""))
            or "0"
        local rating = ratingElement and ratingElement.attributes["title"] or "N/A"
        local category = categoryElement and categoryElement.attributes["title"] or "N/A"
        local iswip = iswipElement and iswipElement.attributes["title"] or "N/A"
        local author_table = {}
        for _, author in pairs(authorElements) do
            table.insert(author_table, encodeHelper:parseToCodepoints(author:getcontent()))
        end

        local author = #authorElements > 0 and table.concat(author_table, ", ") or nil

        local giftedTo_table = {}
        for _, gift in pairs(giftElements) do
            table.insert(giftedTo_table, encodeHelper:parseToCodepoints(gift:getcontent()))
        end

        local gifted_to = #giftElements > 0 and table.concat(giftedTo_table, ", ") or nil
        local tags = #tags > 0 and table.concat(tags, ", ") or "N/A"

        -- Remove HTML formatting, replace <br> with new lines, and preserve paragraph formatting
        local summary = summaryElement
            and encodeHelper:parseFromHTML(summaryElement:getcontent())
            or "No summary available"

        -- Remove leading and trailing whitespace from the title
        local title = titleElement
            and encodeHelper:parseToCodepoints(titleElement:getcontent():gsub("<[^>]+>", ""):gsub("^%s*(.-)%s*$", "%1"))
            or "Unknown title" -- Trim whitespace and remove internal tags

        -- Create the work object
        local work = {
            id = id,
            title = title,
            rating = rating,
            category = category,
            iswip = iswip,
            link = getAO3URL() .. href,
            author = author,
            gifted_to = gifted_to,
            series = self:parseWorkSeries(element),
            summary = summary,
            tags = tags,
            relationships = relationships or {},
            characters = characters or {},
            warnings = warnings or {},
            fandoms = fandoms or {},
            date = date,
            language = language,
            words = words,
            chapters = chapters,
            hits = hits,
            comments = comments,
            kudos = kudos,
            bookmarks = bookmarks,
            is_restricted = isRestricted, -- Add the restricted status
        }

        return work
    end
    return nil
end

function AO3WebParser:parseTagSearchResults(root)
    local fandom_elements = root:select("li > span > a.tag") -- Adjust the selector based on AO3's HTML structure
--
    local fandoms = {}
    for _, element in ipairs(fandom_elements) do
        -- Extract the fandom name
        local fandom_name = element:getcontent()

        -- Extract the number of uses from the parent `<span>` element
        local parent_span = element.parent
        if parent_span then
            -- Remove the fandom name from the parent span content
            local parent_content = parent_span:getcontent()
            -- Extract the last set of parentheses
            local uses_text = parent_content:match(".*%((%d+)%)$") -- Match the last number in parentheses

            if fandom_name and uses_text then
                table.insert(fandoms, {
                    name = encodeHelper:parseToCodepoints(fandom_name),
                    uses = tonumber(uses_text),
                })
            end
        end
    end

    return fandoms
end

function AO3WebParser:parseWorkPage(root)
    -- Extract metadata
    local titleElement = root:select(".title")[1]
    local authorElements = root:select("a[rel='author']")
    local giftElements = root:select(".associations > li > a[href$='/gifts']")
    local summaryElement = root:select(".summary > blockquote")[1]
    local tagsElement = root:select(".freeform > ul")[1]
    local relationshipsElement = root:select(".relationship > ul")[1]
    local charactersElement = root:select(".character > ul")[1]
    local warningsElement = root:select(".warning > ul")[1]
    local epubElement = root:select(".download > .expandable > li > a")
    local ratingElement = root:select(".rating > ul > li > a")[1]
    local categoryElement = root:select(".category > ul > li > a")[1]
    local iswipElement = root:select("dt.status")[1]

    -- Extract logged in metadata
    local markedForLaterElement = root:select(".mark > form > button")[1]
    local subscriptionFormElement = root:select(".subscribe > form")[1]
    local bookmarkFormElement = root:select("#bookmark-form > form")[1]

    -- Extract additional metadata
    local fandomElement = root:select(".fandom > ul")[1]
    local publishedElement = root:select("dd.published")[1]
    local updatedElement = root:select("dd.status")[1]
    local chaptersElement = root:select("dd.chapters")[1]
    local languageElement = root:select("dd.language")[1]

    -- Extract stats
    local hitsElement = root:select("dd.hits")[1]
    local kudosElement = root:select("dd.kudos")[1]
    local commentsElement = root:select("dd.comments")[1]
    local bookmarksElement = root:select("dd.bookmarks > a")[1]
    local wordCountElement = root:select("dd.words")[1]
    local chapterIDElements = root:select("#chapter_index > li > form > p > select > option")

    -- Extract metadata values
    local title = titleElement
        and encodeHelper:parseToCodepoints(titleElement:getcontent():gsub("<[^>]+>", ""):gsub("^%s*(.-)%s*$", "%1"))
        or "Unknown title"


    local author_table = {}
    for _, author in pairs(authorElements) do
        table.insert(author_table, encodeHelper:parseToCodepoints(author:getcontent()))
    end

    local author = authorElements and table.concat(author_table, ", ") or "Anonymous"

    local giftedTo_table = {}
    for _, gift in pairs(giftElements) do
        table.insert(giftedTo_table, encodeHelper:parseToCodepoints(gift:getcontent()))
    end

    local gifted_to = giftElements and table.concat(giftedTo_table, ", ") or nil

    local summary = summaryElement
        and encodeHelper:parseFromHTML(summaryElement:getcontent())
        or "No summary available"

    local chapterData = {}
    if chapterIDElements then
        for __, option in pairs(chapterIDElements) do
            if option.attributes.value then
                table.insert(
                    chapterData,
                    { id = option.attributes.value, #chapterData + 1, name = option:getcontent() }
                )
            end
        end
    end

    if #chapterData == 0 then
        local chapter_title_elements = root:select(".chapter.preface.group > h3.title")
        for _, chapter_title_element in pairs(chapter_title_elements) do
            local content = chapter_title_element:getcontent()
            local chapter_title = string.match(content, "</a>:%s*(.+)") or ("Chapter " .. (#chapterData + 1))
            local chapter_id = string.match(content, "/chapters/(%d+)")
            table.insert(chapterData, { id = chapter_id, #chapterData + 1, name = tostring(#chapterData + 1) .. ". " .. chapter_title })
        end
    end

    local tags = {}
    if tagsElement then
        for _, tag in ipairs(tagsElement:select("li > a")) do
            local content = encodeHelper:parseToCodepoints(tag:getcontent())
            if content then
                table.insert(tags, content)
            end
        end
    end

    local relationships = {}
    if relationshipsElement then
        for _, relationship in ipairs(relationshipsElement:select("li > a")) do
            local content = encodeHelper:parseToCodepoints(relationship:getcontent())
            if content then
                table.insert(relationships, content)
            end
        end
    end

    local characters = {}
    if charactersElement then
        for _, character in ipairs(charactersElement:select("li > a")) do
            local content = encodeHelper:parseToCodepoints(character:getcontent())
            if content then
                table.insert(characters, content)
            end
        end
    end

    local warnings = {}
    if warningsElement then
        for _, warning in ipairs(warningsElement:select("li > a")) do
            local content = encodeHelper:parseToCodepoints(warning:getcontent())
            if content then
                table.insert(warnings, content)
            end
        end
    end

    -- Extract additional metadata values
    local fandoms = {}
    if fandomElement then
        for _, fandom in ipairs(fandomElement:select("li > a")) do
            local content = encodeHelper:parseToCodepoints(fandom:getcontent())
            if content then
                table.insert(fandoms, content)
            end
        end
    end

    local publishedDate = publishedElement and encodeHelper:parseToCodepoints(publishedElement:getcontent()) or "Unknown date"
    local updatedDate = updatedElement and encodeHelper:parseToCodepoints(updatedElement:getcontent()) or "Unknown date"
    local chapters = chaptersElement and encodeHelper:parseToCodepoints(chaptersElement:getcontent():gsub("<[^>]+>", ""))
        or "Unknown chapters"
    local language = languageElement and encodeHelper:parseToCodepoints(languageElement:getcontent()) or "Unknown language"

    -- Extract logged in metadata values
    local markedForLater = markedForLaterElement ~= nil and encodeHelper:parseToCodepoints(markedForLaterElement:getcontent()) == "Mark as Read"
    local subscriptionID = subscriptionFormElement and subscriptionFormElement.attributes and subscriptionFormElement.attributes.id:match("edit_subscription_(%d+)") or false
    local bookmarkID = bookmarkFormElement and bookmarkFormElement.attributes and bookmarkFormElement.attributes.action:match("/bookmarks/(%d+)") or false

    local bookmarkContent = {}

    local bookmarkNotesElement = root:select("#bookmark_notes")[1]
    bookmarkContent.notes = bookmarkNotesElement and encodeHelper:parseFromHTML(bookmarkNotesElement:getcontent()) or ""

    local bookmarkTagElement = root:select("#bookmark_tag_string")[1]
    bookmarkContent.tags = bookmarkTagElement and bookmarkTagElement.attributes and bookmarkTagElement.attributes.value or ""

    local bookmarkCollectionElement = root:select("#bookmark_collection_names")[1]
    bookmarkContent.collections = bookmarkCollectionElement and bookmarkCollectionElement.attributes and bookmarkCollectionElement.attributes.value or ""

    local bookmarkPrivElement = root:select("#bookmark_private")[1]
    bookmarkContent.private = bookmarkPrivElement and bookmarkPrivElement.attributes and bookmarkPrivElement.attributes.checked=="checked" or false

    local bookmarkRecElement = root:select("#bookmark_rec")[1]
    bookmarkContent.rec = bookmarkRecElement and bookmarkRecElement.attributes and bookmarkRecElement.attributes.checked=="checked" or false

    -- Extract available download links
    local epub_link, html_link
    for _, e in ipairs(epubElement) do
        if encodeHelper:parseToCodepoints(e:getcontent()):lower() == "epub" then
            epub_link = e.attributes.href:match("^https?://") and e.attributes.href or getAO3URL() .. e.attributes.href
        elseif encodeHelper:parseToCodepoints(e:getcontent()):lower() == "html" then
            html_link = e.attributes.href:match("^https?://") and e.attributes.href or getAO3URL() .. e.attributes.href
        end
    end

    -- Extract stats values
    local hits = hitsElement and encodeHelper:parseToCodepoints(hitsElement:getcontent():gsub("<[^>]+>", "")) or "0"
    local kudos = kudosElement and encodeHelper:parseToCodepoints(kudosElement:getcontent():gsub("<[^>]+>", "")) or "0"
    local comments = commentsElement and encodeHelper:parseToCodepoints(commentsElement:getcontent():gsub("<[^>]+>", "")) or "0"
    local bookmarks = bookmarksElement and encodeHelper:parseToCodepoints(bookmarksElement:getcontent():gsub("<[^>]+>", "")) or "0"
    local wordcount = wordCountElement and wordCountElement:getcontent():gsub(",", "") or "unknown"

    local iswip = iswipElement and iswipElement:getcontent():gsub(":", "") -- Remove colon
    if iswip == "Completed" then
        iswip = "Complete"
    elseif iswip == "Updated" then
        iswip = "Work in Progress"
    end

    -- Return metadata as a table
    local work = {
        title = title,
        author = author,
        gifted_to = gifted_to,
        chapterData = chapterData,
        series = self:parseWorkSeries(root),
        summary = summary,
        tags = #tags > 0 and table.concat(tags, ", ") or "No tags available",
        relationships = relationships or {},
        characters = characters or {},
        warnings = warnings or {},
        fandoms = fandoms or {},
        published = publishedDate,
        updated = updatedDate,
        wordcount = wordcount,
        chapters = chapters,
        language = language,
        epub_link = epub_link or nil,
        html_link = html_link,
        hits = hits,
        kudos = kudos,
        comments = comments,
        bookmarks = bookmarks,
        rating = ratingElement and ratingElement:getcontent(),
        category = categoryElement and categoryElement:getcontent(),
        iswip = iswip,
        markedForLater = markedForLater,
        subscriptionID = subscriptionID,
        bookmarkID = bookmarkID,
        bookmarkContent = bookmarkContent
    }

    return work
end

function AO3WebParser:parseUserPage(root)
    -- Implementation for parsing user page goes here
    local user_fandoms = root:select("div #user-fandoms > ol > li")


    local fandom_list = {}

    for _, fandom in pairs(user_fandoms) do
        local name = encodeHelper:parseToCodepoints(fandom:select("a")[1]:getcontent())
        local count = fandom:getcontent():gsub("<a[^>]*>.-</a>", ""):match("%((%d+)%)")
        local fandom_id = fandom:select("a")[1].attributes.href:match("fandom_id=(%d+)")
        if name then
            table.insert(fandom_list, {name = name, count = count and tonumber(count) or 0, id = fandom_id})
        end
    end

    local username_element = root:select("div.primary > h2.heading")[1]
    local author_full = username_element and encodeHelper:parseToCodepoints(username_element:getcontent())
    author_full = author_full and author_full:gsub("%s+","") or "Unknown User"

    local username, pseud
    if string.find(author_full, "%(") and string.find(author_full, "%)") then
        username = string.match(author_full, "%((.-)%)")
        pseud = string.match(author_full, "^(.-)%s*%(")
    else
        username = author_full
        pseud = author_full
    end

    local total_pseuds_search = T("a[href$='%1/pseuds']", username)
    local total_pseuds_element = root:select(total_pseuds_search)[1]

    local total_pseuds = nil
    if total_pseuds_element then
        local total_pseuds_text = total_pseuds_element:getcontent()
        total_pseuds = total_pseuds_text:match("All Pseuds%s*%((%d+)%)")

        total_pseuds = tonumber(total_pseuds)
    end

    local total_works_search = T("[href$='%1/works']", pseud)
    local total_works_element = root:select(total_works_search)[1]

    local total_works = nil
    if total_works_element then
        local total_works_text = total_works_element:getcontent()
        total_works = total_works_text:match("Works%s*%((%d+)%)")

        total_works = tonumber(total_works)
    end

    local total_series_search = T("[href$='%1/series']", pseud)
    local total_series_element = root:select(total_series_search)[1]

    local total_series = nil

    if total_series_element then
        local total_series_text = total_series_element:getcontent()
        total_series = total_series_text:match("Series%s*%((%d+)%)")
        logger.dbg("AO3Lib.koplugin: Found total series text: " .. tostring(total_series_text) .. ", extracted total series: " .. tostring(total_series))

        total_series = tonumber(total_series)
    end

    local total_bookmarks_search = T("[href$='%1/bookmarks']", pseud)
    local total_bookmarks_element = root:select(total_bookmarks_search)[1]
    local total_bookmarks = nil

    if total_bookmarks_element then
        local total_bookmarks_text = total_bookmarks_element:getcontent()
        total_bookmarks = total_bookmarks_text:match("Bookmarks%s*%((%d+)%)")

        -- Handle skipping the "My Bookmarks" element that appears in the header if the user is logged in
        if not total_bookmarks then
            total_bookmarks_element = root:select(total_bookmarks_search)[2]
            total_bookmarks_text = total_bookmarks_element and total_bookmarks_element:getcontent() or ""
            total_bookmarks = total_bookmarks_text:match("Bookmarks%s*%((%d+)%)")
        end

        total_bookmarks = tonumber(total_bookmarks)
    end

    local total_collections_search = T("[href$='%1/collections']", username)
    local total_collections_element = root:select(total_collections_search)[1]
    local total_collections = nil

    if total_collections_element then
        local total_collections_text = total_collections_element:getcontent()
        total_collections = total_collections_text:match("Collections%s*%((%d+)%)")

        total_collections = tonumber(total_collections)
    end

    local total_gifts_search = T("[href$='%1/gifts']", username)
    local total_gifts_element = root:select(total_gifts_search)[1]
    local total_gifts = nil

    if total_gifts_element then
        local total_gifts_text = total_gifts_element:getcontent()
        total_gifts = total_gifts_text:match("Gifts%s*%((%d+)%)")

        total_gifts = tonumber(total_gifts)
    end

    return {
        username = username,
        pseud = pseud,
        fandoms = fandom_list,
        total_pseuds = total_pseuds or 1,
        total_works = total_works or 0,
        total_series = total_series or 0,
        total_bookmarks = total_bookmarks or 0,
        total_collections = total_collections or 0,
        total_gifts = total_gifts or 0,
    }
end

function AO3WebParser:parseUserPseuds(root)
    local pseuds = {}
    local elements = root:select("li.pseud")

    local count = 1

    for _, element in ipairs(elements) do
        local pseudElement = element:select("h4.heading > a")[1]
        if pseudElement then
            local pseud_name = encodeHelper:parseToCodepoints(pseudElement:getcontent())

            local worksElement = element:select("h5.heading > a[href$='/works']")[1]
            local recsElement = element:select("h5.heading > a[href$='recs_only=true']")[1]

            local work_count = nil
            local rec_count = nil

            if worksElement then
                local works_text = worksElement:getcontent()
                work_count = tonumber(works_text:match("([%d,]+) work"):gsub(",", ""), 10)
            end

            if recsElement then
                local recs_text = recsElement:getcontent()
                rec_count = tonumber(recs_text:match("([%d,]+) rec"):gsub(",", ""), 10)
            end

            local pseud = {
                name = pseud_name,
                works_count = work_count or 0,
                recs_count = rec_count or 0,
            }

            table.insert(pseuds, count, pseud)
            count = count + 1
        end
    end

    return pseuds
end

function AO3WebParser:parseAccountPseudID(root)

    local element = root:select(".edit_pseud")[1]

    local pseud_id = element and element.attributes and element.attributes.id:match("edit_pseud_(%d+)") or false

    return pseud_id
end

function AO3WebParser:parseUserSearchResults(root)
    local users = {}
    local elements = root:select("li.user")

    local count = 1

    for _, element in ipairs(elements) do
        local usernameElements = element:select("h4.heading > a")
        if usernameElements then
            local username = nil
            local pseud = nil
            local work_count = nil
            local bookmark_count = nil

            if usernameElements[2] == nil then
                username = encodeHelper:parseToCodepoints(usernameElements[1]:getcontent())
                pseud = username
            else
                username = encodeHelper:parseToCodepoints(usernameElements[2]:getcontent())
                pseud = usernameElements[1]:getcontent()
            end

            local worksElement = element:select("h5.heading > a[href$='/works']")[1]
            local bookmarksElement = element:select("h5.heading > a[href$='/bookmarks']")[1]

            if worksElement then
                local works_text = worksElement:getcontent()
                work_count = tonumber(works_text:match("([%d,]+) works"):gsub(",", ""), 10)
            end

            if bookmarksElement then
                local bookmarks_text = bookmarksElement:getcontent()
                bookmark_count = tonumber(bookmarks_text:match("([%d,]+) bookmarks"):gsub(",", ""), 10)
            end





            local user = {
                username = username,
                pseud = pseud,
                works_count = work_count or 0,
                bookmarks_count = bookmark_count or 0,
            }

            table.insert(users, count, user)
            count = count + 1
        end
    end

    return users
end

function AO3WebParser:parseUsersWorkBookmark(root)
    local bookmark_details = {
        notes = "",
        tags = "",
        collections = "",
        private = false,
        rec = false,
    }

    local bookmarkForm = root:select("#bookmark-form > form")[1]


    if not bookmarkForm then
        return bookmark_details
    end

    bookmark_details.notes = bookmarkForm:select("textarea#bookmark_notes")[1] and encodeHelper:parseFromHTML(root:select("textarea#bookmark_notes")[1]:getcontent()) or ""

    -- Tags are stored in a text input field as comma-separated values
    local tags_input = bookmarkForm:select("input#bookmark_tag_string")[1]
    if tags_input and tags_input.attributes and tags_input.attributes.value then
        local tags_string = tags_input.attributes.value
        -- Split by comma and trim whitespace
        for tag in tags_string:gmatch("([^,]+)") do
            tag = tag:match("^%s*(.-)%s*$") -- trim whitespace
            if tag and tag ~= "" then
                bookmark_details.tags = bookmark_details.tags .. (bookmark_details.tags ~= "" and ", " or "") .. tag
            end
        end
    end

    -- Collections are stored in a text input field, not as li.added.tag elements
    local collections_input = bookmarkForm:select("input#bookmark_collection_names")[1]
    if collections_input and collections_input.attributes and collections_input.attributes.value then
        local collections_string = collections_input.attributes.value
        -- Split by comma and trim whitespace
        for collection in collections_string:gmatch("([^,]+)") do
            collection = collection:match("^%s*(.-)%s*$") -- trim whitespace
            if collection and collection ~= "" then
                bookmark_details.collections = bookmark_details.collections .. (bookmark_details.collections ~= "" and ", " or "") .. collection
            end
        end
    end

    bookmark_details.private = bookmarkForm:select("input#bookmark_private")[1] and bookmarkForm:select("input#bookmark_private")[1].attributes.checked == "checked" or false

    bookmark_details.rec = bookmarkForm:select("input#bookmark_rec")[1] and bookmarkForm:select("input#bookmark_rec")[1].attributes.checked == "checked" or false

    return bookmark_details
end
-- HTTPQueryHandler
HTTPQueryHandler.cookies = {}

local function parseSetCookie(set_cookie_value)
    local function isParameter(targetString)
        local parameter_names = { "Domain", "Expires", "HttpOnly", "Max-Age", "Partioned", "Path", "SameSite", "Secure" }
        for _, value in ipairs(parameter_names) do
            if string.lower(targetString) == string.lower(value) then
                return true
            end
        end
        return false
    end

    local cookies_values = {}
    -- Split the set-cookie string by ',' or ';' to handle each part separately
    local parts = {}
    local in_expires = false
    local buffer = ""

    for part in set_cookie_value:gmatch("[^,;]+") do
        -- Allow for expires value to contain single ,
        if part:find("expires=", 1, true) then
            in_expires = true
            buffer = part
        elseif in_expires then
            buffer = buffer .. "," .. part
            if part:find(" ") then
                table.insert(parts, buffer)
                in_expires = false
                buffer = ""
            end
        else
            table.insert(parts, part)
        end
    end

    if buffer ~= "" then
        table.insert(parts, buffer)
    end

    local current_cookie = nil
    for _, part in ipairs(parts) do
        -- Trim leading and trailing spaces
        part = part:match("^%s*(.-)%s*$")
        -- Match key-value pairs or key-only values
        local name, value = part:match("([^=]+)=?(.*)")
        if not isParameter(name) and value ~= "" and value ~= nil then
            if current_cookie then
                table.insert(cookies_values, current_cookie)
            end
            current_cookie = {}
            current_cookie["name"] = name
            current_cookie["value"] = value
        elseif name then
            current_cookie[name] = value or true
        end
    end
    if current_cookie then
        table.insert(cookies_values, current_cookie)
    end

    return cookies_values
end

function HTTPQueryHandler:saveCookiesToConfig()
    if self.in_worker then self.cookies_dirty=true;return end
    Config:saveSetting("cookies", self.cookies)
end

function HTTPQueryHandler:loadCookiesFromConfig()
    if self.in_worker then return end
    local savedCookies = Config:readSetting("cookies")
    if savedCookies then
        self.cookies = savedCookies
    end
end

function HTTPQueryHandler:getCookies(custom_cookies, url)
    self:loadCookiesFromConfig()
    local cookieHeader = {}
    local request_domain = url:match("^(https?://[^/]+)")
    local cookies_for_this_domain = self.cookies[request_domain] or {}

    for __, cookie in pairs(cookies_for_this_domain) do
        table.insert(cookieHeader, T("%1=%2", cookie.name, cookie.value))
    end

    if custom_cookies then
        for key, value in pairs(custom_cookies) do
            table.insert(cookieHeader, T("%1=%2", key, value))
        end
    end

    return table.concat(cookieHeader, "; ");
end

function HTTPQueryHandler:setCookies(response_headers, request_url)
    local request_domain = request_url:match("^(https?://[^/]+)")
    if response_headers["set-cookie"] then
        local set_cookie_value = response_headers["set-cookie"]
        local parsed_cookies = parseSetCookie(set_cookie_value)

        for _, current_cookie in ipairs(parsed_cookies) do
            if not self.cookies[request_domain] then
                self.cookies[request_domain] = {}
            end
            self.cookies[request_domain][current_cookie.name] = current_cookie
        end

        self:saveCookiesToConfig()
    end
end

function HTTPQueryHandler.get_default_headers()
    return {
        ["User-Agent"] = "Mozilla/5.0 (platform; rv:gecko-version) Gecko/gecko-trail Firefox/firefox-version",
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "en-US,en;q=0.5",
        ["Sec-GPC"] = 1,
        ["Connection"] = "keep-alive",
        ["DNT"] = "1", -- Do Not Track
    }
end

function HTTPQueryHandler:performHTTPRequest(request, retries)
    return require("ao3lib.ao3.http").request(request, self, retries)
end

local page_parsers = {
    parseWorkSearchResults = "#main", parseUserBookmarks = "#main",
    parseUserSeriesPage = "#main", parseUserCollectionsPage = "#main",
    parseAccountHistory = "#main", parseTagSearchResults = "#main",
    parseWorkPage = "#workskin .title", parseUserPage = "div.primary > h2.heading",
    parseUserPseuds = "#main", parseAccountPseudID = "#main", parseUserSearchResults = "#main",
}
for name, selector in pairs(page_parsers) do
    local parse = AO3WebParser[name]
    AO3WebParser[name] = function(self, root)
        if not root or not root:select(selector)[1] then error("Unexpected AO3 page layout") end
        return parse(self, root)
    end
end

local payloads = {
    getUserData = "user_data", getWorkMetadata = "work_metadata", searchByParameters = "works",
    searchByTag = "result_works", searchForTags = "result_tags", getWorksFromSeries = "works",
    getWorksFromCollection = "works", getWorksFromUserPage = "works", getWorksFromAccountHistory = "works",
    getUserSeries = "series", getUserCollections = "collections", getUserPseuds = "pseuds",
    searchForUsers = "result_users", searchForCollections = "collections", getUsersWorkBookmark = "bookmark_data",
}

-- Every public operation has the same failure contract, including malformed
-- HTML/JSON, changed selectors, and network-library exceptions. Never let an
-- unexpected server response unwind KOReader's event loop.
for name, operation in pairs(AO3LibClient) do
    AO3LibClient[name] = function(...)
        local Background = require("ao3lib.ao3.background")
        if not HTTPQueryHandler.in_worker and Background.available() then
            assert(coroutine.running(), "AO3 request requires a network continuation")
            local args={n=select("#",...),...}
            local staged
            if name=="downloadEpub" then
                local token=os.tmpname();os.remove(token)
                staged=args[3]..".ao3-"..token:match("([^/]+)$")..".part"
            end
            local cookies=Config:readSetting("cookies",{})
            local packet,err=Background.await(function()
                HTTPQueryHandler.in_worker=true
                HTTPQueryHandler.cookies=cookies
                local result
                if staged then result=operation(args[1],args[2],args[3],args[4],nil,staged)
                else result=operation(unpack(args,1,args.n)) end
                return {result=result,cookies=HTTPQueryHandler.cookies_dirty and HTTPQueryHandler.cookies or nil}
            end,{
                text=(name:match("^get") or name:match("^search") or name=="GetSessionStatus" or staged)
                    and "Loading from AO3…\n\nTap or press Back to cancel."
                    or "Contacting AO3…\n\nTap or press Back to stop waiting. An account action may already have completed; check before trying again.",
                cleanup=staged and function() os.remove(staged) end or nil,
            })
            if not packet then return {success=false,unexpected_response=true,error=err or "AO3 request failed."} end
            if packet.cookies and not Background.isDetached() then
                HTTPQueryHandler.cookies=packet.cookies
                Config:saveSetting("cookies",packet.cookies)
            end
            local result=packet.result
            if staged and result and result.success then
                local allowed,reason=true
                if args[4]==false then
                    local lfs=require("libs/libkoreader-lfs")
                    allowed=not (lfs.symlinkattributes or lfs.attributes)(args[3],"mode")
                    reason="The destination became occupied during download."
                end
                if allowed and args[5] then
                    local checked,ok,why=pcall(args[5])
                    allowed=checked and ok;reason=checked and why or tostring(ok)
                end
                if not allowed then os.remove(staged);return {success=false,error=reason or "The book changed during download."} end
                local renamed,why=os.rename(staged,args[3])
                if not renamed then return {success=false,error="Could not save EPUB: "..tostring(why)} end
                result={success=true,filepath=args[3]}
            end
            if type(result)~="table" then return {success=false,error="AO3 returned an unexpected response."} end
            local payload=payloads[name]
            if result.success and payload and type(result[payload])~="table" then
                return {success=false,unexpected_response=true,error="AO3 returned incomplete data."}
            end
            return result
        end
        local ok, result = pcall(operation, ...)
        local payload = payloads[name]
        if not ok or type(result) ~= "table"
                or (result.success and payload and type(result[payload]) ~= "table") then
            logger.warn("AO3Lib: operation failed", name, ok and "invalid result" or tostring(result))
            return { success = false, unexpected_response = true, error = "AO3 returned an unexpected response. The site may be unavailable or its page format may have changed. Please try again later." }
        end
        if not result.success and type(result.error) ~= "string" then result.error = "AO3 request failed. Please try again later." end
        return result
    end
end

return AO3LibClient
