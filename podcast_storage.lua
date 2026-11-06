local _ = require("gettext")

local Storage = {}
local SAFETY_MARGIN_MIB = 40

local function load_api()
    local ok, api = pcall(require, "free90mib_api")
    if not ok or type(api) ~= "table" then
        return nil, _("Free 90 MiB is unavailable. Install and enable that plugin first.")
    end
    return api
end

local function start_api_operation(api, method, ...)
    if type(api[method]) ~= "function" then
        return nil, _("Free 90 MiB does not provide the required operation.")
    end
    local ok, handle, err = pcall(api[method], ...)
    if not ok then return nil, tostring(handle) end
    if not handle then
        return nil, tostring(err or _("Operation could not be started."))
    end
    return handle
end

function Storage.releaseForEpisode(episode, on_done)
    local size = type(episode) == "table" and tonumber(episode.length) or nil
    if not size or size ~= size or size <= 0 or size == math.huge then
        return nil, _("The feed does not provide a valid episode size. Update the feed before downloading.")
    end

    local api, err = load_api()
    if not api then return nil, err end
    if type(api.MIB) ~= "number" or api.MIB <= 0 then
        return nil, _("Free 90 MiB returned an invalid size unit.")
    end

    local requested_bytes = math.ceil(size) + SAFETY_MARGIN_MIB * api.MIB
    return start_api_operation(api, "release_space", requested_bytes, nil, on_done)
end

function Storage.normalize(on_done)
    local api, err = load_api()
    if not api then return nil, err end
    return start_api_operation(api, "reconcile", nil, on_done)
end

return Storage
