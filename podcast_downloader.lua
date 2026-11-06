local MAX_EPISODE_BYTES = 200 * 1024 * 1024
local Downloader = {
    MAX_EPISODE_BYTES = MAX_EPISODE_BYTES,
}
local _ = require("gettext")
local AudioProbe = require("audio_probe")
local SizeProbe = require("podcast_size_probe")
local logger = require("logger")

function Downloader.exceedsLimit(received_bytes, incoming_bytes)
    return received_bytes + incoming_bytes > MAX_EPISODE_BYTES
end

function Downloader.isWithinSizeLimit(size_bytes)
    local size = tonumber(size_bytes)
    return size == nil or (size == size and size >= 0 and size <= MAX_EPISODE_BYTES)
end

local function shell_safe_url(url)
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

-- Writes the body to temp_path. Returns true plus a small info table, or
-- false plus a message. Redirects are followed here so the caller only ever
-- sees the final response.
local function perform_request(url, temp_path, expected_size, dialog, redirects)
    redirects = redirects or 0
    if redirects > 5 then return false, "Too many redirects" end
    if not shell_safe_url(url) then return false, "Unsupported episode URL" end

    local file, open_err = io.open(temp_path, "wb")
    if not file then return false, open_err or "Cannot create episode file" end

    local received = 0
    local write_failed
    local too_large = false
    local sink = function(chunk)
        if chunk then
            if Downloader.exceedsLimit(received, #chunk) then
                too_large = true
                return nil, "episode exceeds the 200 MiB download limit"
            end
            local wrote, write_err = file:write(chunk)
            if not wrote then
                write_failed = write_err or "write failed"
                return nil, write_failed
            end
            received = received + #chunk
            if expected_size and expected_size > 0 then
                pcall(dialog.reportProgress, dialog, received)
            end
        end
        return 1
    end

    local socketutil = require("socketutil")
    local url_module = require("socket.url")
    local requester = url:match("^https://")
        and require("ssl.https") or require("socket.http")

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local request_ok, ok, code, headers, status = pcall(requester.request, {
        url = url,
        sink = sink,
        headers = {
            ["User-Agent"] = "KOReader-Podcasts/0.3.16",
            ["Accept-Encoding"] = "identity",
        },
    })
    socketutil:reset_timeout()
    file:close()
    if not request_ok then return false, tostring(ok) end
    if write_failed then return false, write_failed end
    if too_large then return false, _("Episode exceeds the 200 MiB download limit") end

    local numeric_code = tonumber(code)
    if numeric_code and numeric_code >= 300 and numeric_code < 400
            and headers and headers.location then
        os.remove(temp_path)
        local next_url = url_module.absolute(url, headers.location)
        return perform_request(next_url, temp_path, expected_size, dialog, redirects + 1)
    end
    if not ok then
        return false, status or tostring(code or "request failed")
    end
    if numeric_code and numeric_code ~= 200 and numeric_code ~= 206 then
        return false, status or ("HTTP " .. tostring(numeric_code))
    end

    return true, {
        bytes = received,
        content_type = header(headers, "content-type"),
        content_length = tonumber(header(headers, "content-length")),
        content_encoding = header(headers, "content-encoding"),
        url = url,
    }
end

-- Validates what actually landed on disk. Returns the sniffed format or nil
-- plus a message that can be shown to the user.
local function validate_download(path, info)
    if info.content_encoding and info.content_encoding ~= ""
            and info.content_encoding:lower() ~= "identity" then
        return nil, _("Server sent a compressed file instead of audio")
    end

    if info.content_length and info.content_length > 0
            and info.bytes ~= info.content_length then
        return nil, string.format(_("Download incomplete: %d of %d bytes"),
            info.bytes, info.content_length)
    end

    if info.bytes < 1024 then
        return nil, _("Downloaded file is too small to be an episode")
    end

    local format, reason = AudioProbe.probe_file(path)
    if not format then
        local content_type = (info.content_type and info.content_type ~= "")
            and info.content_type or _("unknown content type")
        logger.warn("Podcasts: rejected download", path, info.bytes, "bytes,",
            "content-type:", content_type, "reason:", tostring(reason))
        if content_type:lower():match("^audio/") then
            return nil, string.format(
                _("This episode uses an audio format KinAMP cannot play (%s)"),
                content_type)
        end
        return nil, string.format(
            _("Server returned something that is not audio (%s)"), content_type)
    end

    if info.content_type and info.content_type:lower():match("^text/") then
        -- Bytes won the argument, but log the contradiction for support.
        logger.warn("Podcasts: audio bytes came with content-type", info.content_type)
    end

    return format
end

--- Downloads an episode.
-- `base_path` is the destination without extension: the extension is chosen
-- from the file's actual contents, because KinAMP-minimal selects its decoder
-- by extension and a misleading one makes it silent.
function Downloader.download(episode, base_path, callback, before_download)
    local NetworkMgr = require("ui/network/manager")
    local UIManager = require("ui/uimanager")
    local ProgressbarDialog = require("ui/widget/progressbardialog")
    local util = require("util")

    if not shell_safe_url(episode.enclosure_url) then
        callback(false, _("Unsupported episode URL"))
        return
    end

    local parent = base_path:match("^(.+)/[^/]+$")
    if parent and not util.makePath(parent) then
        callback(false, _("Cannot create podcast storage directory"))
        return
    end

    local function download_when_online()
        UIManager:nextTick(function()
            local function start_download(expected)
                local dialog = ProgressbarDialog:new{
                    title = _("Downloading podcast episode"),
                    subtitle = episode.title or "",
                    progress_max = expected and expected > 0 and expected or nil,
                    dismissable = false,
                    refresh_time_seconds = 1,
                }
                dialog:show()

                local temporary = base_path .. ".part"
                logger.info("Podcasts: downloading", episode.enclosure_url, "->", temporary)

                local request_ok, ok, info = pcall(perform_request,
                    episode.enclosure_url, temporary, expected, dialog)
                dialog:close()

                if not request_ok then
                    local request_err = ok
                    ok = false
                    info = tostring(request_err)
                end

                if not ok then
                    os.remove(temporary)
                    logger.warn("Podcasts: download failed:", tostring(info))
                    callback(false, tostring(info))
                    return
                end

                local format, invalid = validate_download(temporary, info)
                if not format then
                    os.remove(temporary)
                    callback(false, invalid)
                    return
                end

                local destination = base_path .. "." .. format
                os.remove(destination)
                local renamed, rename_err = os.rename(temporary, destination)
                if not renamed then
                    os.remove(temporary)
                    callback(false, rename_err or _("Cannot finalize downloaded file"))
                    return
                end

                logger.info("Podcasts: downloaded", destination, info.bytes, "bytes",
                    "content-type:", info.content_type or "none")
                callback(true, destination)
            end

            if not before_download then
                start_download(tonumber(episode.length))
                return
            end

            local probe_ok, size_bytes, size_source = pcall(SizeProbe.getEpisodeSize, episode)
            if not probe_ok then
                size_source = tostring(size_bytes)
                size_bytes = nil
            end
            if size_bytes then
                logger.info("Podcasts: episode size", size_bytes, "bytes from", size_source)
            else
                logger.warn("Podcasts: episode size unavailable; using 230 MiB reservation:",
                    tostring(size_source))
            end
            if not Downloader.isWithinSizeLimit(size_bytes) then
                callback(false, _("Episode exceeds the 200 MiB download limit"))
                return
            end

            local completed = false
            local function on_space_ready(ok, err)
                if completed then return end
                completed = true
                if not ok then
                    callback(false, tostring(err or _("Could not prepare storage for download")))
                    return
                end
                start_download(size_bytes)
            end
            local call_ok, err = pcall(before_download, episode, size_bytes, on_space_ready)
            if not call_ok then on_space_ready(false, tostring(err)) end
        end)
    end

    if NetworkMgr:isConnected() then
        download_when_online()
    else
        NetworkMgr:runWhenOnline(download_when_online)
    end
end

return Downloader
