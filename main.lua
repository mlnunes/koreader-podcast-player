local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local Dispatcher = require("dispatcher")
local logger = require("logger")
local _ = require("gettext")
local gettext = _

local Library = require("podcast_library")
local KinAMP = require("kinamp_client")
local AudioProbe = require("audio_probe")

local MAX_FEED_BYTES = 2 * 1024 * 1024

local function fetch_feed(url, redirects)
    redirects = redirects or 0
    if redirects > 5 then return false, "Too many redirects" end
    if type(url) ~= "string" or not url:match("^https?://") or url:find("[\r\n]") then
        return false, "Unsupported feed URL"
    end

    local socketutil = require("socketutil")
    local url_module = require("socket.url")
    local requester = url:match("^https://")
        and require("ssl.https") or require("socket.http")
    local chunks, received, too_large = {}, 0, false
    local sink = function(chunk)
        if not chunk then return 1 end
        received = received + #chunk
        if received > MAX_FEED_BYTES then
            too_large = true
            return nil, "Feed response is too large"
        end
        chunks[#chunks + 1] = chunk
        return 1
    end

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local call_ok, ok, code, headers, status = pcall(requester.request, {
        url = url,
        sink = sink,
        headers = { ["User-Agent"] = "KOReader-Podcasts/0.3.5" },
    })
    socketutil:reset_timeout()
    if not call_ok then return false, tostring(ok) end
    if too_large then return false, "Feed is too large to process" end

    local numeric_code = tonumber(code)
    if numeric_code and numeric_code >= 300 and numeric_code < 400
            and headers and headers.location then
        local next_url = url_module.absolute(url, headers.location)
        return fetch_feed(next_url, redirects + 1)
    end
    if not ok or numeric_code ~= 200 then
        return false, status or ("HTTP " .. tostring(code or "request failed"))
    end
    return true, table.concat(chunks)
end

local Podcasts = WidgetContainer:extend{
    name = "podcasts",
}

function Podcasts:onDispatcherRegisterActions()
    Dispatcher:registerAction("podcasts_open_library", {
        category = "none",
        event = "OpenPodcastsLibrary",
        title = _("Podcasts: open library"),
        general = true,
    })
end

function Podcasts:init()
    self.library = Library:new{}
    self:onDispatcherRegisterActions()
    if self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    if self.ui.reader_menu then
        self.ui.reader_menu:registerToMainMenu(self)
    end
    logger.info("Podcasts: plugin loaded")
end

function Podcasts:onOpenPodcastsLibrary()
    self:openLibrary()
    return true
end

function Podcasts:addToMainMenu(menu_items)
    menu_items.podcasts = {
        text = _("Podcasts"),
        sorting_hint = "tools",
        callback = function() self:openLibrary() end,
    }
end

function Podcasts:showMessage(text, timeout)
    UIManager:show(require("ui/widget/infomessage"):new{
        text = text,
        timeout = timeout or 3,
    })
end

function Podcasts:guardCallback(label, callback)
    return function(...)
        local args = { ... }
        local ok, err = xpcall(function()
            return callback(unpack(args))
        end, function(error_value)
            return debug.traceback(tostring(error_value), 2)
        end)
        if not ok then
            logger.err("Podcasts:", label, "failed:\n" .. tostring(err))
            self:showMessage(_("Podcast action failed; see KOReader's crash.log"), 5)
        end
    end
end

function Podcasts:openLibrary()
    local Menu = require("podcast_grid_menu")
    local Taskbar = require("podcast_taskbar")
    local Screen = require("device").screen
    local feeds = self.library:getFeeds()
    local items = {}

    self:closeLibraryTaskbar()
    if self.library_menu and UIManager:isWidgetShown(self.library_menu) then
        UIManager:close(self.library_menu)
    end
    self.library_menu = nil

    for feed_index = 1, #feeds do
        local feed = feeds[feed_index]
        local feed_id = feed.id
        local count = #(feed.episodes or {})
        table.insert(items, {
            feed_id = feed_id,
            text = feed.title ~= "" and feed.title or feed.url,
            mandatory = tostring(count),
            artwork_path = self.library:hasArtwork(feed) and feed.artwork_path or nil,
            unplayed_count = self.library:getUnplayedCount(feed_id),
            callback = self:guardCallback("open feed", function()
                self:openFeed(feed_id)
            end),
        })
    end

    local callbacks = {
        self:guardCallback("add feed", function() self:showAddFeedDialog() end),
        self:guardCallback("refresh feeds", function() self:refreshAllFeeds() end),
        self:guardCallback("playback controls", function() self:showPlaybackControls() end),
        self:guardCallback("player diagnostics", function() self:showDiagnostics() end),
    }
    local taskbar = Taskbar:new{ callbacks = callbacks }
    local taskbar_height = taskbar:getSize().h
    local menu_height = Screen:getHeight() - taskbar_height

    local library_menu
    library_menu = Menu:new{
        title = _("Podcasts"),
        item_table = items,
        height = menu_height,
        close_callback = function()
            -- Menu invokes close_callback after both a real close and an item
            -- selection. Keep the taskbar while a child dialog/menu is shown.
            if not UIManager:isWidgetShown(library_menu) then
                self:closeLibraryTaskbar()
                self.library_menu = nil
            end
        end,
    }
    self.library_menu = library_menu
    self.library_taskbar = taskbar
    -- The taskbar is the top window, so explicitly forward taps outside its
    -- touch strip (including the Menu titlebar's close button) to the menu.
    taskbar.active_widgets = { library_menu }
    UIManager:show(library_menu, nil, nil, 0, 0)
    UIManager:show(taskbar, nil, nil, 0, menu_height)
end

function Podcasts:closeLibraryTaskbar()
    if self.library_taskbar and UIManager:isWidgetShown(self.library_taskbar) then
        UIManager:close(self.library_taskbar)
    end
    self.library_taskbar = nil
end

function Podcasts:refreshLibraryFeedItem(feed_id)
    local menu = self.library_menu
    local feed = self.library:getFeed(feed_id)
    if not menu or not feed or not UIManager:isWidgetShown(menu) then return end

    for index = 1, #menu.item_table do
        local item = menu.item_table[index]
        if item.feed_id == feed_id then
            item.text = feed.title ~= "" and feed.title or feed.url
            item.mandatory = tostring(#(feed.episodes or {}))
            item.artwork_path = self.library:hasArtwork(feed) and feed.artwork_path or nil
            item.unplayed_count = self.library:getUnplayedCount(feed_id)
            menu:updateItems(nil, true)
            return
        end
    end
end

function Podcasts:openFeed(feed_id)
    local Menu = require("ui/widget/menu")
    local feed = self.library:getFeed(feed_id)
    if not feed then
        self:showMessage(gettext("Podcast feed not found"))
        return
    end

    local items = {}
    for episode_index, episode in ipairs(feed.episodes or {}) do
        local episode_id = episode.id
        local status = episode.download_path and gettext("Downloaded")
            or (episode.played and gettext("Played") or gettext("Not downloaded"))
        local date = episode.date and episode.date ~= "" and (" · " .. episode.date) or ""
        table.insert(items, {
            text = (episode.title or gettext("Untitled episode")) .. date,
            mandatory = status,
            callback = function() self:showEpisodeActions(feed_id, episode_id) end,
        })
    end
    if #(feed.episodes or {}) > 0 then
        table.insert(items, {
            text = _("Mark all episodes as played"),
            callback = self:guardCallback("mark all feed episodes as played", function()
                local ok = self.library:setFeedEpisodesPlayed(feed_id, true)
                if not ok then
                    self:showMessage(_("Podcast feed not found"))
                    return
                end
                self:refreshLibraryFeedItem(feed_id)
                self:refreshVisibleFeed(feed_id)
                self:showMessage(_("All episodes marked as played"))
            end),
        })
    end
    table.insert(items, {
        text = gettext("Refresh this feed"),
        callback = function() self:refreshFeed(feed_id) end,
    })
    table.insert(items, {
        text = gettext("Remove this feed"),
        callback = function() self:confirmRemoveFeed(feed_id) end,
    })

    self.feed_menu = Menu:new{
        title = feed.title ~= "" and feed.title or feed.url,
        item_table = items,
    }
    UIManager:show(self.feed_menu)
end

function Podcasts:showPlaybackControls()
    local ButtonDialog = require("ui/widget/buttondialog")
    local status, err = KinAMP.getStatus()
    if not status then
        self:showMessage(err or _("KinAMP is not playing"))
        return
    end

    local dialog
    local function action(method)
        return function()
            UIManager:close(dialog)
            local ok, action_err = KinAMP.control(method)
            if not ok then self:showMessage(action_err or _("Player command failed")) end
        end
    end
    local buttons = {
        {
            {
                text = status.is_playing and _("Pause") or _("Resume"),
                callback = action("pause"),
            },
            { text = _("Previous episode"), callback = action("previous") },
            { text = _("Next episode"), callback = action("next") },
        },
        {
            { text = _("Stop playback"), callback = action("stop") },
        },
    }
    dialog = ButtonDialog:new{
        title = status.title or _("KinAMP playback"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function Podcasts:refreshVisibleLibrary()
    self:openLibrary()
end

function Podcasts:refreshVisibleFeed(feed_id)
    if self.feed_menu and UIManager:isWidgetShown(self.feed_menu) then
        UIManager:close(self.feed_menu)
    end
    self.feed_menu = nil
    self:openFeed(feed_id)
end

function Podcasts:cacheFeedArtwork(feed_id, artwork_url)
    local feed = self.library:getFeed(feed_id)
    if not feed or not artwork_url or self.library:hasArtwork(feed) then return end

    local ok, downloaded, path_or_err = pcall(function()
        return require("podcast_artwork").download(
            artwork_url, self.library:getArtworkBasePath(feed))
    end)
    if ok and downloaded then
        self.library:setFeedArtwork(feed_id, artwork_url, path_or_err)
    else
        logger.warn("Podcasts: artwork download failed:", tostring(ok and path_or_err or downloaded))
    end
end

function Podcasts:showEpisodeActions(feed_id, episode_id)
    local ButtonDialog = require("ui/widget/buttondialog")
    local feed, episode = self.library:getEpisode(feed_id, episode_id)
    if not episode then
        self:showMessage(_("Episode not found"))
        return
    end

    local dialog
    local function close_then(callback)
        return function()
            UIManager:close(dialog)
            callback()
        end
    end

    local is_downloaded = self.library:isDownloaded(episode)
    local buttons = {
        {
            {
                text = is_downloaded and _("Play episode") or _("Download episode"),
                callback = close_then(function()
                    if is_downloaded then
                        self:playEpisode(feed_id, episode_id)
                    else
                        self:downloadEpisode(feed_id, episode_id)
                    end
                end),
            },
        },
    }
    if is_downloaded then
        table.insert(buttons, {
            {
                text = _("Delete downloaded file"),
                callback = close_then(function()
                self.library:deleteDownload(feed_id, episode_id)
                self:refreshVisibleFeed(feed_id)
                self:showMessage(_("Downloaded episode deleted"))
                end),
            },
        })
    end
    table.insert(buttons, {
        {
            text = episode.played and _("Mark as unplayed") or _("Mark as played"),
            callback = close_then(function()
                self.library:setPlayed(feed_id, episode_id, not episode.played)
                self:refreshLibraryFeedItem(feed_id)
                self:refreshVisibleFeed(feed_id)
                self:showMessage(_("Episode status updated"))
            end),
        },
    })

    dialog = ButtonDialog:new{
        title = episode.title or _("Episode"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function Podcasts:showAddFeedDialog()
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Add podcast feed URL"),
        input = "https://",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Add"),
                is_enter_default = true,
                callback = function()
                    local url = dialog:getInputText():match("^%s*(.-)%s*$")
                    if url == "" then return end
                    UIManager:close(dialog)
                    self:addFeed(url)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Podcasts:addFeed(url)
    if not url:match("^https?://") or url:find("[\r\n]") then
        self:showMessage(_("Feed URL must start with http:// or https://"))
        return
    end
    local existing = self.library:findFeedByURL(url)
    if existing then
        self:showMessage(_("This feed is already in your library"))
        return
    end

    local feed = self.library:addFeed(url)
    self:fetchFeed(feed, true)
end

function Podcasts:refreshFeed(feed_id)
    local feed = self.library:getFeed(feed_id)
    if feed then self:fetchFeed(feed, false) end
end

function Podcasts:refreshAllFeeds()
    local feeds = self.library:getFeeds()
    if #feeds == 0 then
        self:showMessage(_("Add a podcast feed first"))
        return
    end
    local index = 1
    local function refresh_next()
        local feed = feeds[index]
        if not feed then
            self:refreshVisibleLibrary()
            self:showMessage(_("Podcast feeds refreshed"))
            return
        end
        index = index + 1
        self:fetchFeed(feed, false, refresh_next)
    end
    refresh_next()
end

function Podcasts:fetchFeed(feed, is_new, on_done)
    local NetworkMgr = require("ui/network/manager")
    local InfoMessage = require("ui/widget/infomessage")

    local busy = InfoMessage:new{ text = _("Fetching podcast feed and artwork…") }
    UIManager:show(busy)
    local function fetch_when_online()
        local ok, body_or_err = fetch_feed(feed.url)
        UIManager:nextTick(function()
            if not ok then
                UIManager:close(busy)
                if is_new then self.library:removeFeed(feed.id) end
                if not on_done then
                    if is_new then self:refreshVisibleLibrary() end
                    self:showMessage(_("Could not fetch feed") .. ": " .. tostring(body_or_err))
                end
                if on_done then on_done() end
                return
            end
            local parsed, parse_err = require("feed_parser").parse(body_or_err, feed.url)
            if not parsed then
                UIManager:close(busy)
                if is_new then self.library:removeFeed(feed.id) end
                if not on_done then
                    if is_new then self:refreshVisibleLibrary() end
                    self:showMessage(_("Could not parse feed") .. ": " .. tostring(parse_err))
                end
            else
                self.library:updateFeed(feed.id, parsed)
                self:cacheFeedArtwork(feed.id, parsed.artwork_url)
                self:refreshLibraryFeedItem(feed.id)
                UIManager:close(busy)
                if not on_done then
                    if is_new then
                        self:refreshVisibleLibrary()
                    else
                        self:refreshVisibleFeed(feed.id)
                    end
                    self:showMessage(_("Feed updated") .. ": " .. (parsed.title or feed.url))
                end
            end
            if on_done then on_done() end
        end)
    end
    if NetworkMgr:isConnected() then
        UIManager:nextTick(fetch_when_online)
    else
        NetworkMgr:runWhenOnline(function() UIManager:nextTick(fetch_when_online) end)
    end
end

function Podcasts:confirmRemoveFeed(feed_id)
    local ConfirmBox = require("ui/widget/confirmbox")
    local feed = self.library:getFeed(feed_id)
    if not feed then return end
    UIManager:show(ConfirmBox:new{
        text = _("Remove this feed? Downloaded audio files will be kept."),
        ok_text = _("Remove"),
        ok_callback = function()
            self.library:removeFeed(feed_id)
            if self.feed_menu and UIManager:isWidgetShown(self.feed_menu) then
                UIManager:close(self.feed_menu)
            end
            self.feed_menu = nil
            self:refreshVisibleLibrary()
            self:showMessage(_("Feed removed"))
        end,
    })
end

function Podcasts:downloadEpisode(feed_id, episode_id)
    local Downloader = require("podcast_downloader")
    local feed, episode = self.library:getEpisode(feed_id, episode_id)
    if not episode then return end
    local previous_path = episode.download_path
    Downloader.download(episode, self.library:getDownloadBasePath(episode), function(ok, path_or_err)
        if ok then
            self.library:setDownload(feed_id, episode_id, path_or_err)
            if previous_path and previous_path ~= path_or_err then
                os.remove(previous_path)
            end
            self:refreshVisibleFeed(feed_id)
            self:showMessage(_("Episode downloaded") .. ": " .. (episode.title or ""), 4)
        else
            logger.warn("Podcasts: download failed:", tostring(path_or_err))
            self:showMessage(_("Download failed") .. ": " .. tostring(path_or_err), 6)
        end
    end)
end

function Podcasts:playEpisode(feed_id, episode_id)
    local feed, episode = self.library:getEpisode(feed_id, episode_id)
    if not episode or not self.library:isDownloaded(episode) then
        self:showMessage(_("Download the episode before playing it"))
        return
    end

    -- Never hand KinAMP a file that isn't audio: its decoder trusts the file
    -- blindly, and a bad one can leave the player stuck until it is killed.
    local format, reason = AudioProbe.probe_file(episode.download_path)
    if not format then
        logger.warn("Podcasts: refusing to play", tostring(episode.download_path),
            "reason:", tostring(reason))
        self:showMessage(_("This episode's file is not valid audio.")
            .. " " .. _("Delete the download and fetch it again."), 6)
        return
    end

    -- KinAMP selects its decoder by extension and older downloads took theirs
    -- from the URL, which is not always what the server sent.
    local base = episode.download_path:gsub("%.[%w]+$", "")
    local corrected = base .. "." .. format
    if corrected ~= episode.download_path then
        if os.rename(episode.download_path, corrected) then
            self.library:setDownloadPath(feed_id, episode_id, corrected)
            episode.download_path = corrected
            logger.info("Podcasts: renamed download to", corrected)
        else
            logger.warn("Podcasts: could not rename", episode.download_path, "to", corrected)
        end
    end

    local queue, index = self.library:getDownloadedQueue(feed_id, episode_id)
    if not queue or #queue == 0 then
        self:showMessage(_("No downloaded episodes to play"))
        return
    end

    local ok, err = KinAMP.play(queue, index, episode.position or 0, function(status)
        self.library:updatePositionByPath(status.path, status.pos, status.dur)
    end, function(message)
        self:showMessage(message .. "\n\n"
            .. _("If KinAMP does not respond, restart it (killall KinAMP-minimal).")
            .. "\n" .. _("Details: crash.log and KinAMP's kinamp.log."), 10)
    end)
    if not ok then self:showMessage(err or _("Could not start KinAMP")) end
end

function Podcasts:showDiagnostics()
    local InfoMessage = require("ui/widget/infomessage")
    local text = table.concat({
        KinAMP.diagnostics(),
        "",
        _("Podcast folder") .. ": " .. self.library.podcast_dir,
        _("Feeds") .. ": " .. tostring(#self.library:getFeeds()),
    }, "\n")
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = 20,
        show_icon = false,
    })
    logger.info("Podcasts: diagnostics\n" .. text)
end

function Podcasts:onClose()
    self.library:flush()
end

return Podcasts
