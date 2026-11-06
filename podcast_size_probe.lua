local Probe = {}

local MAX_REDIRECTS = 5
local USER_AGENT = "KOReader-Podcasts/0.3.16"

local function safe_http_url(url)
    return type(url) == "string" and url:match("^https?://") ~= nil
        and not url:find("[\r\n]")
end

local function header(headers, name)
    if not headers then return nil end
    local value = headers[name]
    if value then return value end
    local lowered = name:lower()
    for key, candidate in pairs(headers) do
        if type(key) == "string" and key:lower() == lowered then
            return candidate
        end
    end
end

local function positive_size(value)
    local size = tonumber(value)
    if not size or size ~= size or size <= 0 or size == math.huge then
        return nil
    end
    return math.ceil(size)
end

local function size_from_content_range(headers)
    local content_range = header(headers, "content-range")
    local total = content_range and content_range:match("/%s*(%d+)%s*$")
    return positive_size(total)
end

local function request_size(url, method, redirects)
    redirects = redirects or 0
    if redirects > MAX_REDIRECTS then return nil, "Too many size-probe redirects" end
    if not safe_http_url(url) then return nil, "Unsupported episode URL" end

    local socketutil = require("socketutil")
    local url_module = require("socket.url")
    local requester = url:match("^https://")
        and require("ssl.https") or require("socket.http")
    local headers = {
        ["User-Agent"] = USER_AGENT,
        ["Accept-Encoding"] = "identity",
    }
    if method == "GET" then headers.Range = "bytes=0-0" end

    -- We only need response headers. If a server ignores HEAD/Range and starts
    -- sending a body, abort on its first chunk instead of downloading audio.
    local sink = function(chunk)
        if not chunk then return 1 end
        return nil, "episode-size probe stopped after response headers"
    end

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local call_ok, request_result, code, response_headers, status = pcall(requester.request, {
        url = url,
        method = method,
        headers = headers,
        sink = sink,
    })
    socketutil:reset_timeout()
    if not call_ok then return nil, tostring(request_result) end

    local numeric_code = tonumber(code)
    if numeric_code and numeric_code >= 300 and numeric_code < 400
            and response_headers and response_headers.location then
        local next_url = url_module.absolute(url, response_headers.location)
        return request_size(next_url, method, redirects + 1)
    end

    if method == "HEAD" and numeric_code and numeric_code >= 200 and numeric_code < 300 then
        local size = positive_size(header(response_headers, "content-length"))
        if size then return size end
    elseif method == "GET" then
        if numeric_code == 206 or numeric_code == 416 then
            local size = size_from_content_range(response_headers)
            if size then return size end
        elseif numeric_code == 200 then
            -- Some servers ignore Range but still return the full length header.
            local size = positive_size(header(response_headers, "content-length"))
            if size then return size end
        end
    end

    return nil, status or ("HTTP " .. tostring(code or "size unavailable"))
end

function Probe.getEpisodeSize(episode)
    if type(episode) ~= "table" then
        return nil, "Episode data is unavailable"
    end

    local feed_size = positive_size(episode.length)
    if feed_size then return feed_size, "RSS enclosure" end
    if not safe_http_url(episode.enclosure_url) then
        return nil, "Unsupported episode URL"
    end

    local size, head_err = request_size(episode.enclosure_url, "HEAD")
    if size then return size, "HTTP Content-Length" end

    local range_size, range_err = request_size(episode.enclosure_url, "GET")
    if range_size then return range_size, "HTTP Content-Range/Length" end
    return nil, range_err or head_err
end

return Probe
