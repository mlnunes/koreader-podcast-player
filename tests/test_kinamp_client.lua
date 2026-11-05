local plugin_dir = (... and ... ~= "") and ... or "podcast.koplugin"
package.path = plugin_dir .. "/?.lua;" .. package.path

-- Minimal KOReader stand-ins. The watchdog only needs scheduling, gettext and
-- a logger; the backend is a scriptable fake below.
local scheduled = {}

package.preload["gettext"] = function()
    return function(text) return text end
end

package.preload["logger"] = function()
    return {
        dbg = function() end,
        info = function() end,
        warn = function() end,
        err = function() end,
    }
end

package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_, delay, callback)
            scheduled[#scheduled + 1] = { delay = delay, callback = callback }
        end,
    }
end

local backend_state
local calls

package.preload["kinamp_backend"] = function()
    return {
        play_from_index = function(index, items)
            calls.play = { index = index, items = items }
            return true
        end,
        get_status = function()
            return backend_state.status
        end,
        seek = function(seconds)
            calls.seek[#calls.seek + 1] = seconds
            return true
        end,
        stop = function()
            calls.stop = calls.stop + 1
            return true
        end,
        is_running = function() return true end,
    }
end

local KinAMP = require("kinamp_client")

local function reset()
    scheduled = {}
    calls = { seek = {}, stop = 0, play = nil }
    backend_state = {
        status = nil,
        path = "/podcasts/episode.mp3",
    }
end

-- Runs the next queued poll and returns how many remain plus the delay of the
-- poll that was just scheduled.
local function step()
    local item = table.remove(scheduled, 1)
    assert(item, "no poll was scheduled")
    item.callback()
    local next_item = scheduled[1]
    return #scheduled, next_item and next_item.delay
end

local function status(overrides)
    local value = {
        path = backend_state.path,
        state = "playing",
        pos = 0,
        dur = 180,
    }
    for key, new_value in pairs(overrides or {}) do value[key] = new_value end
    value.is_playing = value.state == "playing"
    value.is_paused = value.state == "paused"
    value.is_stopped = value.state == "stopped" or value.state == nil
    return value
end

-- 1. A healthy episode seeks only after the duration is known, then saves the
-- position the player reports after the seek.
reset()
local saved = {}
assert(KinAMP.play({ backend_state.path }, 1, 42, function(s)
    saved[#saved + 1] = s.pos
end) == true)

backend_state.status = status{ pos = 0 }
local _, delay = step()
assert(#calls.seek == 1 and calls.seek[1] == 42, "seek should be sent once duration is known")
assert(delay == 2, "a short poll should follow the seek")
assert(#saved == 0, "stale pre-seek position must not be saved")

backend_state.status = status{ pos = 42 }
step()
assert(saved[1] == 42, "post-seek position should be saved")

backend_state.status = status{ pos = 57 }
step()
assert(saved[2] == 57, "position should keep being sampled")

-- 2. No duration for 10 s: the player is stopped and the user is told.
reset()
local errors = {}
assert(KinAMP.play({ backend_state.path }, 1, 0, nil, function(message)
    errors[#errors + 1] = message
end))
backend_state.status = status{ dur = 0 }
for _ = 1, 20 do step() end
assert(#errors == 1, "a stalled decoder should be reported")
assert(calls.stop == 1, "a stalled decoder should be stopped")
assert(#scheduled == 0, "watchdog should end after failing")

-- 3. Cold start: no status yet is fine for a while, then playback appears.
reset()
errors = {}
assert(KinAMP.play({ backend_state.path }, 1, 0, nil, function(message)
    errors[#errors + 1] = message
end))
for _ = 1, 5 do step() end
assert(#errors == 0)
backend_state.status = status{ pos = 10 }
step()
assert(#errors == 0)
backend_state.status = status{ pos = 25 }
step()
assert(#errors == 0, "cold start should not be treated as a failure")

-- 4. No player at all for 30 s: report, but do not stop someone else's music.
reset()
errors = {}
assert(KinAMP.play({ backend_state.path }, 1, 0, nil, function(message)
    errors[#errors + 1] = message
end))
for _ = 1, 60 do step() end
assert(#errors == 1)
assert(calls.stop == 0, "stop is only safe when our own file is loaded")

-- 5. "Playing" with a frozen position: the daemon may be wedged.
reset()
errors = {}
assert(KinAMP.play({ backend_state.path }, 1, 0, nil, function(message)
    errors[#errors + 1] = message
end))
backend_state.status = status{ pos = 100 }
step()
step() -- same position
step() -- same position again
assert(#errors == 1, "a frozen position should be reported")
assert(calls.stop == 1)

-- 6. A newer play invalidates the previous watchdog.
reset()
errors = {}
assert(KinAMP.play({ backend_state.path }, 1, 0, nil, function(message)
    errors[#errors + 1] = message
end))
backend_state.path = "/podcasts/next.mp3"
assert(KinAMP.play({ backend_state.path }, 1, 0, nil, function(message)
    errors[#errors + 1] = message
end))
step() -- stale poll from the first call: must do nothing
assert(#scheduled == 1, "stale poll should not reschedule itself")
backend_state.status = status{ pos = 5 }
step()
assert(#errors == 0)

-- 7. Playback ending persists the final position and stops the poll loop.
reset()
saved = {}
assert(KinAMP.play({ backend_state.path }, 1, 0, function(s)
    saved[#saved + 1] = s.pos
end))
backend_state.status = status{ pos = 179, state = "stopped" }
local remaining = step()
assert(remaining == 0, "a stopped player should not be polled forever")
assert(#saved == 1 and saved[1] == 179, "final position should be saved")

-- 8. Paused at the same position: keep watching, but don't rewrite the library.
reset()
saved = {}
assert(KinAMP.play({ backend_state.path }, 1, 0, function(s)
    saved[#saved + 1] = s.pos
end))
backend_state.status = status{ pos = 50, state = "paused" }
step()
step()
assert(#saved == 1, "an unchanged paused position should only be saved once")

-- 9. The decoder failed and the daemon cleared its path: report that the
-- episode did not start instead of waiting out the full cold-start timeout.
reset()
errors = {}
assert(KinAMP.play({ backend_state.path }, 1, 0, nil, function(message)
    errors[#errors + 1] = message
end))
backend_state.status = status{ path = "", state = "stopped" }
for _ = 1, 19 do step() end
assert(#errors == 0, "a path-less status should get a short grace period")
step()
assert(#errors == 1, "a path-less stopped player should be reported")
assert(calls.stop == 1, "a path-less player should be sent a stop")
assert(#scheduled == 0, "watchdog should end after failing")

-- 10. An empty path while a slow file is being opened must not abort playback:
-- the grace period restarts once our file appears.
reset()
errors = {}
assert(KinAMP.play({ backend_state.path }, 1, 0, nil, function(message)
    errors[#errors + 1] = message
end))
backend_state.status = status{ path = "", state = "stopped" }
for _ = 1, 19 do step() end
assert(#errors == 0)
backend_state.status = status{ pos = 0 }
step()
assert(#errors == 0, "playback that finally starts should not be reported as failed")
backend_state.status = status{ pos = 15 }
step()
assert(#errors == 0)
assert(calls.stop == 0, "a file that opened should not be stopped")

print("kinamp_client: OK")
