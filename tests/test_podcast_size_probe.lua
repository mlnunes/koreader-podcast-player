local plugin_dir = (... and ... ~= "") and ... or "podcast.koplugin"
package.path = plugin_dir .. "/?.lua;" .. package.path

local responses = {}
local requests = {}
local function fake_request(request)
    table.insert(requests, request)
    local response = assert(table.remove(responses, 1), "unexpected HTTP request")
    if request.sink then
        if response.body then
            local sink_ok = request.sink(response.body)
            if not sink_ok then
                return nil, response.code, response.headers, response.status
            end
        else
            request.sink(nil)
        end
    end
    return 1, response.code, response.headers, response.status
end

package.preload["socket.url"] = function()
    return {
        absolute = function(base, location)
            if location:match("^https?://") then return location end
            local authority = base:match("^(https?://[^/]+)")
            return authority .. location
        end,
    }
end
package.preload["socketutil"] = function()
    return {
        LARGE_BLOCK_TIMEOUT = 1,
        LARGE_TOTAL_TIMEOUT = 2,
        set_timeout = function() end,
        reset_timeout = function() end,
    }
end
package.preload["ssl.https"] = function() return { request = fake_request } end
package.preload["socket.http"] = function() return { request = fake_request } end

local Probe = require("podcast_size_probe")
local size, source = Probe.getEpisodeSize({
    length = 1234,
    enclosure_url = "https://audio.example/episode.mp3",
})
assert(size == 1234 and source == "RSS enclosure")
assert(#requests == 0, "RSS enclosure length should avoid a network probe")

responses = {
    { code = 302, headers = { location = "/redirected.mp3" }, status = "Found" },
    { code = 200, headers = { ["Content-Length"] = "12345" }, status = "OK" },
}
size, source = Probe.getEpisodeSize({ enclosure_url = "https://audio.example/episode.mp3" })
assert(size == 12345 and source == "HTTP Content-Length", "HEAD should discover the size")
assert(#requests == 2 and requests[1].method == "HEAD" and requests[2].url
    == "https://audio.example/redirected.mp3", "HEAD redirects should be followed")

requests = {}
responses = {
    { code = 405, headers = {}, status = "Method Not Allowed" },
    {
        code = 206,
        headers = { ["Content-Range"] = "bytes 0-0/98765", ["Content-Length"] = "1" },
        body = "x",
        status = "Partial Content",
    },
}
size, source = Probe.getEpisodeSize({ enclosure_url = "https://audio.example/range.mp3" })
assert(size == 98765 and source == "HTTP Content-Range/Length",
    "a byte-range response should provide the complete resource size")
assert(requests[2].method == "GET" and requests[2].headers.Range == "bytes=0-0")

requests = {}
responses = {
    { code = 200, headers = {}, status = "OK" },
    {
        code = 200,
        headers = { ["Content-Length"] = "87654" },
        body = string.rep("x", 100),
        status = "OK",
    },
}
size = Probe.getEpisodeSize({ enclosure_url = "https://audio.example/no-range.mp3" })
assert(size == 87654, "a server that ignores Range may still provide Content-Length")

requests = {}
responses = {
    { code = 200, headers = {}, status = "OK" },
    { code = 200, headers = {}, body = "x", status = "OK" },
}
size = Probe.getEpisodeSize({ enclosure_url = "https://audio.example/unknown.mp3" })
assert(size == nil, "missing RSS and HTTP size metadata should use the caller's fallback")

print("podcast_size_probe: OK")
