local plugin_dir = (... and ... ~= "") and ... or "podcast.koplugin"
package.path = plugin_dir .. "/?.lua;" .. package.path

-- The Kindle runs KOReader with a relative data dir ("."), while KinAMP runs
-- from /mnt/us/KinAMP. Paths saved for the player must therefore be absolute.
local fake_cwd = "/mnt/us/koreader"
local files = {
    ["podcasts/old.mp3"] = true,
    ["/mnt/us/koreader/podcasts/old.mp3"] = true,
    ["/mnt/us/koreader/podcasts/abs.m4a"] = true,
    ["/mnt/us/koreader/podcasts/artwork/feed.jpg"] = true,
}
local flushed = false

package.preload["datastorage"] = function()
    return {
        getDataDir = function() return "." end,
        getFullDataDir = function() return fake_cwd end,
    }
end

package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, what)
            if what ~= "mode" then return nil end
            if path == "/mnt/us/koreader/podcasts" then return "directory" end
            if files[path] then return "file" end
            return nil
        end,
        mkdir = function() return true end,
        currentdir = function() return fake_cwd end,
    }
end

package.preload["luasettings"] = function()
    return {
        open = function()
            return {
                data = {
                    feeds = {{
                        id = "feed",
                        episodes = {
                            { id = "old", download_path = "./podcasts/old.mp3" },
                            { id = "abs", download_path = "/mnt/us/koreader/podcasts/abs.m4a" },
                        },
                    }},
                },
                saveSetting = function() end,
                flush = function() flushed = true end,
            }
        end,
    }
end

local Library = require("podcast_library")
local library = Library:new{}

assert(library.podcast_dir == "/mnt/us/koreader/podcasts",
    "the podcast folder must be absolute: " .. tostring(library.podcast_dir))
assert(library:getDownloadBasePath({ id = "new" })
    == "/mnt/us/koreader/podcasts/new", "new downloads need an absolute base path")

local old = library:getFeed("feed").episodes[1]
local absolute = library:getFeed("feed").episodes[2]
assert(old.download_path == "/mnt/us/koreader/podcasts/old.mp3",
    "a relative path should be migrated: " .. tostring(old.download_path))
assert(absolute.download_path == "/mnt/us/koreader/podcasts/abs.m4a",
    "an absolute path should be left alone")
assert(flushed, "migrated paths should be saved to library.lua")

local feed = library:getFeed("feed")
assert(library:getArtworkBasePath(feed) == "/mnt/us/koreader/podcasts/artwork/feed",
    "feed artwork should be stored in its own local directory")
assert(library:setFeedArtwork("feed", "https://example.com/art.jpg",
    "/mnt/us/koreader/podcasts/artwork/feed.jpg"))
assert(library:hasArtwork(feed), "a saved artwork image should be detected")

local old_episode = feed.episodes[1]
local abs_episode = feed.episodes[2]
old_episode.position = 12
abs_episode.position = 5
local marked_ok, marked_count = library:setFeedEpisodesPlayed("feed", true)
assert(marked_ok and marked_count == 2, "all episodes should be marked in one operation")
assert(old_episode.played and abs_episode.played, "bulk mark should update every episode")
assert(old_episode.position == 12 and abs_episode.position == 5,
    "marking as played should preserve saved positions")

library:setFeedEpisodesPlayed("feed", false)
assert(not old_episode.played and not abs_episode.played, "bulk unmark should clear played flags")
assert(old_episode.position == 0 and abs_episode.position == 0,
    "bulk unmark should reset playback positions")

local queue = library:getDownloadedQueue("feed", "old")
assert(#queue == 2, "both downloaded episodes should be queued")
assert(queue[1] == "/mnt/us/koreader/podcasts/old.mp3", "the queue must hold absolute paths")

print("podcast_library: OK")
