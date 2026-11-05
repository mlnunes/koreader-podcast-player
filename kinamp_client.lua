local KinAMPClient = {}
local _ = require("gettext")
local logger = require("logger")

-- Which play request is current. A new play invalidates the previous poll
-- loop, so a stale watchdog can't stop a player the user has since started.
local generation = 0

local function get_backend()
    local ok, backend = pcall(require, "kinamp_backend")
    if not ok or type(backend.play_from_index) ~= "function"
            or type(backend.get_status) ~= "function" then
        return nil, tostring(backend)
    end
    return backend
end

function KinAMPClient.getStatus()
    local backend, err = get_backend()
    if not backend then
        return nil, _("KinAMP is not installed or its plugin is disabled") .. " (" .. tostring(err) .. ")"
    end
    local ok, status = pcall(backend.get_status)
    if not ok then return nil, tostring(status) end
    if not status then return nil, _("KinAMP is not currently running") end
    return status
end

function KinAMPClient.control(command)
    local backend = get_backend()
    if not backend then
        return false, _("KinAMP is not installed or its plugin is disabled")
    end
    local commands = {
        pause = backend.pause,
        previous = backend.previous_track,
        next = backend.next_track,
        stop = backend.stop,
    }
    local fn = commands[command]
    if not fn then return false, _("Unknown player command") end
    local ok, result = pcall(fn)
    if not ok then return false, tostring(result) end
    return result ~= false
end

local function is_queued(queue, path)
    if not path then return false end
    for _, queued_path in ipairs(queue) do
        if queued_path == path then return true end
    end
    return false
end

--- Plays `queue[index]` with KinAMP.
--
-- KinAMP's queue is a single m3u, so this replaces whatever list it held -
-- the same thing its own playlist screen does when a track is tapped.
--
-- on_status receives the daemon status each time the position is sampled.
-- on_error is called when the daemon never starts this file, or starts it but
-- reports no duration (which is what happens when the decoder gives up on a
-- file). In that case playback is stopped here, so the player is left usable
-- instead of sitting on a pipeline that never drains.
function KinAMPClient.play(queue, index, resume_position, on_status, on_error)
    local backend, backend_err = get_backend()
    if not backend then
        return false, _("KinAMP is not installed or its plugin is disabled")
            .. " (" .. tostring(backend_err) .. ")"
    end
    if not queue or not queue[index] then
        return false, _("The selected episode is not in the downloaded queue")
    end

    local expected_path = queue[index]
    logger.info("Podcasts: play request:", index, "/", #queue, expected_path)

    local ok, err = pcall(backend.play_from_index, index, queue)
    if not ok then return false, tostring(err) end

    generation = generation + 1
    local token = generation
    local UIManager = require("ui/uimanager")

    -- 0.5 s ticks while waiting for the daemon; once it reports our file,
    -- position is sampled much less often - e-ink and vfat both prefer it.
    local WAIT_TICKS = 60          -- 30 s for a cold start, launcher included
    local STALL_TICKS = 20         -- 10 s with no duration before giving up
    local SAMPLE_SECONDS = 15

    local attempts = 0
    local stalled = 0
    local seek_sent = false
    local healthy = false
    local last_pos = nil
    local frozen_samples = 0
    local STUCK_SAMPLES = 2      -- ~30 s of "playing" with no position change
    local missing_path_samples = 0
    local MISSING_PATH_SAMPLES = 20 -- 10 s stopped without a current file

    local function finish(message, stop_player)
        -- Leave the daemon stopped rather than wedged on a bad file. It stays
        -- resident, so KinAMP can still start something else afterwards. Only
        -- when the player really is sitting on our file, though: if the user
        -- has started music in the meantime, that is theirs to keep.
        if stop_player and backend.stop then pcall(backend.stop) end
        logger.warn("Podcasts: playback did not start:", tostring(message))
        if on_error then pcall(on_error, message) end
    end

    local poll
    poll = function()
        if token ~= generation then return end
        attempts = attempts + 1

        local status_ok, status = pcall(backend.get_status)
        if not status_ok then
            logger.warn("Podcasts: status read failed:", tostring(status))
            status = nil
        end

        if status and status.path == expected_path then
            missing_path_samples = 0
            if status.dur and status.dur > 0 then
                -- Only seek once the player knows the duration: before that
                -- the command would be queued against a pipeline that is
                -- still opening the file.
                if not seek_sent then
                    seek_sent = true
                    if resume_position and resume_position > 0 then
                        local seek_ok, seek_result = pcall(backend.seek, resume_position)
                        logger.info("Podcasts: resume seek", resume_position,
                            "ok:", seek_ok and seek_result ~= false)
                        if seek_ok and seek_result ~= false then
                            -- Give the player a moment to apply the seek, then
                            -- save the position it reports, not the stale one.
                            healthy = true
                            stalled = 0
                            UIManager:scheduleIn(2, poll)
                            return
                        end
                    end
                end

                healthy = true
                stalled = 0

                -- A wedged helper thread still leaves the FIFO readable, so
                -- "is_running" cannot see it. The position is the tell: while
                -- the player claims to be playing it must keep moving.
                local position_changed = last_pos == nil or status.pos ~= last_pos
                if status.is_playing then
                    if not position_changed then
                        frozen_samples = frozen_samples + 1
                    else
                        frozen_samples = 0
                    end
                    if frozen_samples >= STUCK_SAMPLES then
                        logger.warn("Podcasts: position frozen at", tostring(status.pos),
                            "state:", tostring(status.state))
                        finish(_("KinAMP stopped responding while playing this episode"), true)
                        return
                    end
                else
                    frozen_samples = 0
                end
                last_pos = status.pos

                -- Don't rewrite the library while paused and unchanged.
                if on_status and (position_changed or not status.is_paused) then
                    pcall(on_status, status)
                end

                if status.is_stopped then
                    logger.info("Podcasts: playback ended; stopping position polls")
                    return
                end
            elseif not healthy then
                stalled = stalled + 1
                if stalled >= STALL_TICKS then
                    logger.warn("Podcasts: no duration reported; state:",
                        tostring(status.state), "path:", tostring(status.path))
                    finish(status.state == "stopped"
                        and _("KinAMP did not start this episode")
                        or _("KinAMP could not decode this episode's audio file"), true)
                    return
                end
            end

            UIManager:scheduleIn(healthy and SAMPLE_SECONDS or 0.5, poll)
            return
        end

        -- A decoder that fails before producing any audio leaves the daemon
        -- stopped with its current path cleared, so `status.path` never equals
        -- ours. Without this the watchdog waited out its full timeout and then
        -- reported "player is on " with nothing else.
        if status and (status.path == nil or status.path == "") then
            missing_path_samples = missing_path_samples + 1
            if missing_path_samples >= MISSING_PATH_SAMPLES then
                logger.warn("Podcasts: player stopped without loading the file; state:",
                    tostring(status.state))
                -- No current file means nothing of the user's is playing, so a
                -- stop here can only help a daemon left mid-open.
                finish(_("KinAMP did not start this episode"), true)
                return
            end
        else
            missing_path_samples = 0
        end

        if status and seek_sent and is_queued(queue, status.path) then
            -- The player moved on to another episode of ours (next/prev).
            healthy = true
            stalled = 0
            frozen_samples = 0
            last_pos = status.pos
            if on_status then pcall(on_status, status) end
            if status.is_stopped then
                logger.info("Podcasts: playback ended; stopping position polls")
                return
            end
            UIManager:scheduleIn(SAMPLE_SECONDS, poll)
            return
        end

        if attempts < WAIT_TICKS then
            UIManager:scheduleIn(0.5, poll)
        elseif not status then
            finish(_("KinAMP did not start this episode"), false)
        elseif is_queued(queue, status.path) then
            -- On another of our files but not the one asked for. Worth saying
            -- so, but nothing to stop.
            finish(_("KinAMP started a different episode"), false)
        else
            -- The user moved on to their own music; leave the player alone.
            logger.info("Podcasts: gave up waiting; player is on", tostring(status.path))
        end
    end

    UIManager:scheduleIn(0.5, poll)
    return true
end

--- One-line summary of the player state, for the diagnostics dialog.
function KinAMPClient.diagnostics()
    local lines = {}
    local backend, require_err = get_backend()
    if not backend then
        lines[#lines + 1] = _("KinAMP backend: not available")
        lines[#lines + 1] = tostring(require_err)
        return table.concat(lines, "\n")
    end
    lines[#lines + 1] = _("KinAMP backend: available")

    local ok, running = pcall(backend.is_running)
    lines[#lines + 1] = _("Player running: ") .. tostring(ok and running or "unknown")

    local status = KinAMPClient.getStatus()
    if not status then
        lines[#lines + 1] = _("Status: not available")
        return table.concat(lines, "\n")
    end
    lines[#lines + 1] = string.format("%s: %s", _("State"), tostring(status.state))
    lines[#lines + 1] = string.format("%s: %s", _("Position"),
        tostring(status.pos) .. " / " .. tostring(status.dur))
    lines[#lines + 1] = string.format("%s: %s", _("Queue index"),
        tostring(status.index) .. " / " .. tostring(status.count))
    lines[#lines + 1] = string.format("%s: %s", _("Path"), tostring(status.path))
    return table.concat(lines, "\n")
end

return KinAMPClient
