local plugin_dir = (... and ... ~= "") and ... or "podcast.koplugin"
package.path = plugin_dir .. "/?.lua;" .. package.path

package.preload["gettext"] = function()
    return function(text) return text end
end

local mib = 1024 * 1024
local captured_release
local captured_reconcile
package.preload["free90mib_api"] = function()
    return {
        MIB = mib,
        release_space = function(bytes, on_progress, on_done)
            captured_release = { bytes = bytes, on_progress = on_progress, on_done = on_done }
            return { cancel = function() end }
        end,
        reconcile = function(on_progress, on_done)
            captured_reconcile = { on_progress = on_progress, on_done = on_done }
            return { cancel = function() end }
        end,
    }
end

local Storage = require("podcast_storage")
local release_result
local handle, err = Storage.releaseForEpisode({ length = 75 * mib + 1 }, function(success, result)
    release_result = { success = success, result = result }
end)
assert(handle, err)
assert(captured_release.bytes == 75 * mib + 1 + 40 * mib,
    "release request should include episode length plus 40 MiB")
assert(captured_release.on_progress == nil, "integration should not require a progress callback")
captured_release.on_done(true, { final_free_bytes = 180 * mib })
assert(release_result and release_result.success, "release completion should pass through")

local invalid_handle, invalid_err = Storage.releaseForEpisode({ length = 0 }, function() end)
assert(not invalid_handle and invalid_err:find("valid episode size", 1, true),
    "feeds without a usable enclosure size must not start a download")

local normalized
handle, err = Storage.normalize(function(success, result)
    normalized = { success = success, result = result }
end)
assert(handle, err)
assert(captured_reconcile.on_progress == nil)
captured_reconcile.on_done(true, { final_free_bytes = 90 * mib })
assert(normalized and normalized.success, "normalization completion should pass through")

print("podcast_storage: OK")
