local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")

local Library = {}
Library.__index = Library

local function hash(value)
    local result = 7
    for i = 1, #value do
        result = (result * 31 + value:byte(i)) % 2147483647
    end
    return string.format("%08x", result)
end

-- Absolute base for our files. DataStorage:getDataDir() is "." on the Kindle,
-- and KinAMP runs from its own directory (/mnt/us/KinAMP), so a relative path
-- handed to it points at a file that does not exist there.
local function full_data_dir()
    local ok, dir = pcall(DataStorage.getFullDataDir, DataStorage)
    if ok and type(dir) == "string" and dir ~= "" then
        dir = dir:gsub("/+$", "")
        return dir ~= "" and dir or "/"
    end
    local data_dir = DataStorage:getDataDir()
    if type(data_dir) == "string" and data_dir:sub(1, 1) == "/" then
        return data_dir:gsub("/+$", "")
    end
    local cwd = lfs.currentdir()
    return (cwd and cwd ~= "") and cwd or (data_dir or ".")
end

-- Older releases stored "./podcasts/<id>.<ext>". Resolve those to the absolute
-- path where they were actually written, so they keep playing after the update.
local function absolute_path(path, data_dir)
    if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/" then
        return path
    end
    local relative = path:gsub("^%./", "")
    if lfs.attributes(relative, "mode") == "file" then
        local cwd = lfs.currentdir()
        if cwd and cwd ~= "" then return cwd .. "/" .. relative end
    end
    return data_dir .. "/" .. relative
end

function Library:new()
    local data_dir = full_data_dir()
    local podcast_dir = data_dir .. "/podcasts"
    if lfs.attributes(podcast_dir, "mode") ~= "directory" then
        lfs.mkdir(podcast_dir)
    end
    local artwork_dir = podcast_dir .. "/artwork"
    if lfs.attributes(artwork_dir, "mode") ~= "directory" then
        lfs.mkdir(artwork_dir)
    end

    local settings = LuaSettings:open(podcast_dir .. "/library.lua")
    local feeds = settings.data.feeds
    if type(feeds) ~= "table" then feeds = {} end

    -- Migrate paths saved by earlier versions, which KinAMP cannot reach from
    -- its working directory.
    local migrated = false
    for _, feed in ipairs(feeds) do
        for _, episode in ipairs(feed.episodes or {}) do
            local path = episode.download_path
            if type(path) == "string" and path ~= "" and path:sub(1, 1) ~= "/" then
                episode.download_path = absolute_path(path, data_dir)
                migrated = true
            end
        end
    end

    local self = setmetatable({
        settings = settings,
        podcast_dir = podcast_dir,
        artwork_dir = artwork_dir,
        feeds = feeds,
    }, Library)
    if migrated then self:flush() end
    return self
end

function Library:flush()
    self.settings:saveSetting("feeds", self.feeds)
    self.settings:flush()
end

function Library:getFeeds()
    return self.feeds
end

function Library:getFeed(feed_id)
    for _, feed in ipairs(self.feeds) do
        if feed.id == feed_id then return feed end
    end
end

function Library:getUnplayedCount(feed_id)
    local feed = self:getFeed(feed_id)
    if not feed then return 0 end
    local count = 0
    for _, episode in ipairs(feed.episodes or {}) do
        if not episode.played then count = count + 1 end
    end
    return count
end

function Library:getEpisode(feed_id, episode_id)
    local feed = self:getFeed(feed_id)
    if not feed then return nil, nil end
    for _, episode in ipairs(feed.episodes or {}) do
        if episode.id == episode_id then return feed, episode end
    end
    return feed, nil
end

function Library:findFeedByURL(url)
    for _, feed in ipairs(self.feeds) do
        if feed.url == url then return feed end
    end
end

function Library:addFeed(url)
    local feed = {
        id = hash(url),
        url = url,
        title = "",
        episodes = {},
    }
    table.insert(self.feeds, feed)
    self:flush()
    return feed
end

function Library:getArtworkBasePath(feed)
    return self.artwork_dir .. "/" .. feed.id
end

function Library:hasArtwork(feed)
    return feed.artwork_path ~= nil
        and lfs.attributes(feed.artwork_path, "mode") == "file"
end

function Library:setFeedArtwork(feed_id, url, path)
    local feed = self:getFeed(feed_id)
    if not feed then return false end
    local previous_path = feed.artwork_path
    feed.artwork_url = url
    feed.artwork_path = path
    if previous_path and previous_path ~= path then os.remove(previous_path) end
    self:flush()
    return true
end

function Library:removeFeed(feed_id)
    for index, feed in ipairs(self.feeds) do
        if feed.id == feed_id then
            if feed.artwork_path then os.remove(feed.artwork_path) end
            table.remove(self.feeds, index)
            self:flush()
            return true
        end
    end
    return false
end

local function episode_key(episode)
    if episode.guid and episode.guid ~= "" then return "guid:" .. episode.guid end
    return "url:" .. (episode.enclosure_url or "")
end

function Library:updateFeed(feed_id, parsed)
    local feed = self:getFeed(feed_id)
    if not feed then return false end

    local old_by_key = {}
    for _, episode in ipairs(feed.episodes or {}) do
        old_by_key[episode_key(episode)] = episode
    end

    local updated = {}
    for _, source in ipairs(parsed.episodes or {}) do
        local old = old_by_key[episode_key(source)]
        local episode = {
            id = (old and old.id) or hash(feed.id .. "|" .. episode_key(source)),
            title = source.title or "",
            guid = source.guid or "",
            date = source.date or "",
            enclosure_url = source.enclosure_url,
            mime_type = source.mime_type or "",
            length = source.length,
            played = old and old.played or false,
            position = old and old.position or 0,
            duration = old and old.duration,
            download_path = old and old.download_path or nil,
        }
        if episode.download_path
                and lfs.attributes(episode.download_path, "mode") ~= "file" then
            episode.download_path = nil
            episode.position = 0
        end
        table.insert(updated, episode)
    end

    feed.title = parsed.title ~= "" and parsed.title or feed.title
    if parsed.artwork_url ~= feed.artwork_url then
        local previous_artwork = feed.artwork_path
        feed.artwork_url = parsed.artwork_url
        feed.artwork_path = nil
        if previous_artwork then os.remove(previous_artwork) end
    end
    feed.episodes = updated
    self:flush()
    return true
end

function Library:isDownloaded(episode)
    return episode.download_path ~= nil
        and lfs.attributes(episode.download_path, "mode") == "file"
end

function Library:setDownload(feed_id, episode_id, path)
    local _, episode = self:getEpisode(feed_id, episode_id)
    if not episode then return false end
    episode.download_path = path
    episode.position = 0
    self:flush()
    return true
end

-- Same, but keeps the saved position. Used when a file is only renamed.
function Library:setDownloadPath(feed_id, episode_id, path)
    local _, episode = self:getEpisode(feed_id, episode_id)
    if not episode then return false end
    episode.download_path = path
    self:flush()
    return true
end

function Library:deleteDownload(feed_id, episode_id)
    local _, episode = self:getEpisode(feed_id, episode_id)
    if not episode then return false end
    if episode.download_path then os.remove(episode.download_path) end
    episode.download_path = nil
    episode.position = 0
    self:flush()
    return true
end

function Library:setPlayed(feed_id, episode_id, played)
    local _, episode = self:getEpisode(feed_id, episode_id)
    if not episode then return false end
    episode.played = played and true or false
    if not episode.played then episode.position = 0 end
    self:flush()
    return true
end

function Library:setFeedEpisodesPlayed(feed_id, played)
    local feed = self:getFeed(feed_id)
    if not feed then return false, 0 end

    local count = 0
    played = played and true or false
    for _, episode in ipairs(feed.episodes or {}) do
        episode.played = played
        if not played then episode.position = 0 end
        count = count + 1
    end
    self:flush()
    return true, count
end

function Library:getDownloadedQueue(feed_id, episode_id)
    local queue, selected_index = {}, nil
    for _, feed in ipairs(self.feeds) do
        for _, episode in ipairs(feed.episodes or {}) do
            if self:isDownloaded(episode) then
                table.insert(queue, episode.download_path)
                if feed.id == feed_id and episode.id == episode_id then
                    selected_index = #queue
                end
            end
        end
    end
    return queue, selected_index
end

function Library:updatePositionByPath(path, position, duration)
    if not path then return false end
    for _, feed in ipairs(self.feeds) do
        for _, episode in ipairs(feed.episodes or {}) do
            if episode.download_path == path then
                episode.position = math.max(0, tonumber(position) or 0)
                episode.duration = tonumber(duration) or episode.duration
                if episode.duration and episode.duration > 0
                        and episode.position >= episode.duration - 3 then
                    episode.played = true
                    episode.position = 0
                end
                self:flush()
                return true
            end
        end
    end
    return false
end

function Library:getDownloadBasePath(episode)
    -- No extension: the downloader picks one from the file's actual contents.
    return self.podcast_dir .. "/" .. episode.id
end

return Library
