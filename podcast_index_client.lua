local Client = {}

local API_URL = "https://api.podcastindex.org/api/1.0/search/byterm"
local MAX_RESPONSE_BYTES = 1024 * 1024
local MAX_RESULTS = 20

function Client.buildAuthHeaders(api_key, api_secret, timestamp)
    local date = tostring(timestamp or os.time())
    local sha = require("ffi/sha2")
    return {
        ["User-Agent"] = "KOReader-Podcasts/0.3.16",
        ["X-Auth-Key"] = api_key,
        ["X-Auth-Date"] = date,
        Authorization = sha.sha1(api_key .. api_secret .. date),
    }
end

function Client.resultText(feed)
    local title = type(feed.title) == "string" and feed.title or ""
    local author = type(feed.author) == "string" and feed.author or ""
    if title == "" then title = feed.url or "" end
    if author ~= "" then return title .. " · " .. author end
    return title
end

local function valid_feed_url(url)
    return type(url) == "string" and url:match("^https?://") ~= nil
        and not url:find("[\r\n]")
end

function Client.search(query, api_key, api_secret)
    query = type(query) == "string" and query:match("^%s*(.-)%s*$") or ""
    if query == "" then return nil, "Enter a search term" end
    if type(api_key) ~= "string" or api_key == ""
            or type(api_secret) ~= "string" or api_secret == "" then
        return nil, "Configure the Podcast Index API key and secret"
    end
    if api_key:find("[\r\n]") or api_secret:find("[\r\n]") then
        return nil, "Podcast Index credentials contain invalid line breaks"
    end

    local url = require("socket.url")
    local socketutil = require("socketutil")
    local requester = require("ssl.https")
    local request_url = API_URL .. "?q=" .. url.escape(query) .. "&max=" .. MAX_RESULTS
    local headers = Client.buildAuthHeaders(api_key, api_secret)
    local chunks, received, too_large = {}, 0, false
    local sink = function(chunk)
        if not chunk then return 1 end
        received = received + #chunk
        if received > MAX_RESPONSE_BYTES then
            too_large = true
            return nil, "Podcast Index response exceeds the allowed size"
        end
        chunks[#chunks + 1] = chunk
        return 1
    end

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local call_ok, ok, code, _, status = pcall(requester.request, {
        url = request_url,
        sink = sink,
        headers = headers,
    })
    socketutil:reset_timeout()
    if not call_ok then return nil, tostring(ok) end
    if too_large then return nil, "Podcast Index response exceeds the allowed size" end
    if not ok or tonumber(code) ~= 200 then
        if tonumber(code) == 401 then
            return nil, "Podcast Index rejected the credentials or Kindle clock (HTTP 401)"
        end
        return nil, status or ("HTTP " .. tostring(code or "request failed"))
    end

    local decode_ok, response = pcall(require("rapidjson").decode, table.concat(chunks))
    if not decode_ok or type(response) ~= "table" then
        return nil, "Could not decode the Podcast Index response"
    end
    if response.status == false or response.status == "false" then
        return nil, response.description or response.message or "Podcast Index search failed"
    end
    if type(response.feeds) ~= "table" then
        return nil, "Podcast Index response does not contain a feed list"
    end

    local feeds = {}
    for _, feed in ipairs(response.feeds) do
        if type(feed) == "table" and valid_feed_url(feed.url) then
            table.insert(feeds, {
                title = type(feed.title) == "string" and feed.title or "",
                author = type(feed.author) == "string" and feed.author or "",
                url = feed.url,
                artwork = type(feed.artwork) == "string" and feed.artwork or nil,
            })
            if #feeds >= MAX_RESULTS then break end
        end
    end
    return feeds
end

return Client
