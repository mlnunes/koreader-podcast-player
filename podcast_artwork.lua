local Artwork = {}

local MAX_ARTWORK_BYTES = 4 * 1024 * 1024
local MAX_REDIRECTS = 5

local function valid_url(url)
    return type(url) == "string"
        and url:match("^https?://") ~= nil
        and not url:find("[\r\n]")
end

local function fetch(url, redirects)
    redirects = redirects or 0
    if redirects > MAX_REDIRECTS then return nil, "Too many artwork redirects" end
    if not valid_url(url) then return nil, "Unsupported artwork URL" end

    local socketutil = require("socketutil")
    local url_module = require("socket.url")
    local requester = url:match("^https://")
        and require("ssl.https") or require("socket.http")
    local chunks, received, too_large = {}, 0, false
    local sink = function(chunk)
        if not chunk then return 1 end
        received = received + #chunk
        if received > MAX_ARTWORK_BYTES then
            too_large = true
            return nil, "Artwork is too large"
        end
        chunks[#chunks + 1] = chunk
        return 1
    end

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local call_ok, ok, code, headers, status = pcall(requester.request, {
        url = url,
        sink = sink,
        headers = { ["User-Agent"] = "KOReader-Podcasts/0.3.13" },
    })
    socketutil:reset_timeout()

    if not call_ok then return nil, tostring(ok) end
    if too_large then return nil, "Artwork exceeds the size limit" end

    local numeric_code = tonumber(code)
    if numeric_code and numeric_code >= 300 and numeric_code < 400
            and headers and headers.location then
        return fetch(url_module.absolute(url, headers.location), redirects + 1)
    end
    if not ok or numeric_code ~= 200 then
        return nil, status or ("HTTP " .. tostring(code or "request failed"))
    end

    return table.concat(chunks)
end

local function image_extension(data)
    if data:sub(1, 3) == "\255\216\255" then return "jpg" end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
end

local function artwork_hash(data)
    local value = 7
    for index = 1, #data do
        value = (value * 31 + data:byte(index)) % 2147483647
    end
    return string.format("%08x", value)
end

function Artwork.download(url, destination_base)
    local data, err = fetch(url)
    if not data then return false, err end

    local extension = image_extension(data)
    if not extension then
        return false, "Artwork is not a supported JPEG or PNG image"
    end

    -- Include the image contents in the filename so KOReader's image cache
    -- cannot keep displaying stale pixels when a feed reuses its artwork URL.
    local destination = destination_base .. "." .. artwork_hash(data) .. "." .. extension
    local temporary = destination_base .. ".part"
    local file, open_err = io.open(temporary, "wb")
    if not file then return false, open_err end
    local write_ok, write_err = file:write(data)
    local close_ok, close_err = file:close()
    if not write_ok or close_ok == nil then
        os.remove(temporary)
        return false, write_err or close_err or "Could not write artwork"
    end
    if not os.rename(temporary, destination) then
        os.remove(temporary)
        return false, "Could not move artwork into place"
    end

    return true, destination
end

return Artwork
