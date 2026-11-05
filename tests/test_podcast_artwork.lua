local response_body

package.preload["socketutil"] = function()
    return {
        LARGE_BLOCK_TIMEOUT = 1,
        LARGE_TOTAL_TIMEOUT = 2,
        set_timeout = function() end,
        reset_timeout = function() end,
    }
end

package.preload["socket.url"] = function()
    return { absolute = function(_, url) return url end }
end

package.preload["socket.http"] = function()
    return {
        request = function(request)
            local sink_ok, sink_err = request.sink(response_body)
            request.sink(nil)
            if not sink_ok then return nil, 200, {}, sink_err end
            return 1, 200, {}, "OK"
        end,
    }
end

local plugin_dir = (... and ... ~= "") and ... or "podcast.koplugin"
package.path = plugin_dir .. "/?.lua;" .. package.path
local Artwork = require("podcast_artwork")

local base = os.tmpname()
os.remove(base)

response_body = "\255\216\255test jpeg bytes"
local ok, path = Artwork.download("http://images.example/cover", base)
assert(ok and path:match("%.jpg$"), "JPEG artwork should be saved with a real extension")
local file = assert(io.open(path, "rb"))
assert(file:read("*a") == response_body)
file:close()
os.remove(path)

response_body = "<html>not an image</html>"
ok = Artwork.download("http://images.example/not-an-image", base)
assert(not ok, "non-image responses should be rejected")

response_body = string.rep("x", 4 * 1024 * 1024 + 1)
ok = Artwork.download("http://images.example/too-large", base)
assert(not ok, "artwork larger than the cap should be rejected")
os.remove(base .. ".part")

print("podcast_artwork: OK")
