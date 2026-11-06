local _ = require("gettext")

local Storage = {}
local SAFETY_MARGIN_MIB = 40
local UNKNOWN_SIZE_RESERVATION_MIB = 230

local function positive_size(value)
    local size = tonumber(value)
    if not size or size ~= size or size <= 0 or size == math.huge then
        return nil
    end
    return math.ceil(size)
end

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

function Storage.releaseForEpisode(episode, discovered_size, on_done)
    local size = positive_size(discovered_size)
        or (type(episode) == "table" and positive_size(episode.length))

    local api, err = load_api()
    if not api then return nil, err end
    if type(api.MIB) ~= "number" or api.MIB <= 0 then
        return nil, _("Free 90 MiB returned an invalid size unit.")
    end

    local requested_bytes
    if size then
        requested_bytes = size + SAFETY_MARGIN_MIB * api.MIB
    else
        requested_bytes = UNKNOWN_SIZE_RESERVATION_MIB * api.MIB
    end
    return start_api_operation(api, "release_space", requested_bytes, nil, on_done)
end

function Storage.normalize(on_done)
    local api, err = load_api()
    if not api then return nil, err end
    return start_api_operation(api, "reconcile", nil, on_done)
end

return Storage
