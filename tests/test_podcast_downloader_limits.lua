local plugin_dir = (... and ... ~= "") and ... or "podcast.koplugin"
package.path = plugin_dir .. "/?.lua;" .. package.path

package.preload["gettext"] = function()
    return function(text) return text end
end
package.preload["audio_probe"] = function()
    return { probe_file = function() return "mp3" end }
end
package.preload["podcast_size_probe"] = function()
    return { getEpisodeSize = function() return nil, "unknown" end }
end
package.preload["logger"] = function()
    return { info = function() end, warn = function() end }
end

local Downloader = require("podcast_downloader")
local max_bytes = 200 * 1024 * 1024
assert(Downloader.MAX_EPISODE_BYTES == max_bytes)
assert(Downloader.isWithinSizeLimit(nil), "unknown sizes use the configured fallback")
assert(Downloader.isWithinSizeLimit(max_bytes), "the exact limit should be allowed")
assert(not Downloader.isWithinSizeLimit(max_bytes + 1), "known oversized episodes should be rejected")
assert(not Downloader.isWithinSizeLimit(math.huge), "infinite sizes should be rejected")
assert(not Downloader.exceedsLimit(max_bytes - 1, 1), "a transfer reaching the exact limit is allowed")
assert(Downloader.exceedsLimit(max_bytes, 1), "a chunk beyond the limit should be refused")

print("podcast_downloader_limits: OK")
