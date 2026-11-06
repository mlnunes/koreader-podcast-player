-- Small, non-validating XML reader for the RSS 2.0 and Atom fields this plugin
-- needs. External entities and DTDs are ignored; feed data is never executed.
local Parser = {}
local MAX_EPISODES = 500

local rss_episode_fields = {
    title = true,
    guid = true,
    pubdate = true,
    ["dc:date"] = true,
    enclosure = true,
    ["media:content"] = true,
}
local atom_episode_fields = {
    title = true,
    id = true,
    published = true,
    updated = true,
    link = true,
}

local function utf8char(codepoint)
    if codepoint < 0x80 then
        return string.char(codepoint)
    elseif codepoint < 0x800 then
        return string.char(0xC0 + math.floor(codepoint / 0x40), 0x80 + codepoint % 0x40)
    elseif codepoint < 0x10000 then
        return string.char(0xE0 + math.floor(codepoint / 0x1000),
            0x80 + math.floor(codepoint / 0x40) % 0x40, 0x80 + codepoint % 0x40)
    elseif codepoint <= 0x10FFFF then
        return string.char(0xF0 + math.floor(codepoint / 0x40000),
            0x80 + math.floor(codepoint / 0x1000) % 0x40,
            0x80 + math.floor(codepoint / 0x40) % 0x40, 0x80 + codepoint % 0x40)
    end
    return ""
end

local function decode_entities(value)
    value = value:gsub("&#[xX](%x+);", function(hex)
        local cp = tonumber(hex, 16)
        return cp and utf8char(cp) or ""
    end)
    value = value:gsub("&#(%d+);", function(number)
        local cp = tonumber(number)
        return cp and utf8char(cp) or ""
    end)
    value = value:gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&apos;", "'")
    return (value:gsub("&amp;", "&"))
end

local function tag_end(xml, start_at)
    local quote
    for i = start_at, #xml do
        local char = xml:sub(i, i)
        if quote then
            if char == quote then quote = nil end
        elseif char == '"' or char == "'" then
            quote = char
        elseif char == ">" then
            return i
        end
    end
end

local function parse_attributes(rest)
    local attrs = {}
    for key, value in rest:gmatch("([%w_:%.-]+)%s*=%s*\"([^\"]*)\"") do
        attrs[key:lower()] = decode_entities(value)
    end
    for key, value in rest:gmatch("([%w_:%.-]+)%s*=%s*'([^']*)'") do
        attrs[key:lower()] = decode_entities(value)
    end
    return attrs
end

local function append_text(node, text, decode)
    if node.skip then return end
    if decode then text = decode_entities(text) end
    table.insert(node.content, text)
end

local function parse_xml(xml)
    xml = xml:gsub("^\239\187\191", "")
    local root = { name = "#document", attrs = {}, children = {}, content = {} }
    local stack = { root }
    local pos = 1
    local episode_count = 0

    while pos <= #xml do
        local lt = xml:find("<", pos, true)
        if not lt then
            if not stack[#stack].skip then
                append_text(stack[#stack], xml:sub(pos), true)
            end
            break
        end
        if lt > pos and not stack[#stack].skip then
            append_text(stack[#stack], xml:sub(pos, lt - 1), true)
        end

        if xml:sub(lt, lt + 8) == "<![CDATA[" then
            local close = xml:find("]]>", lt + 9, true)
            if not close then return nil, "Unclosed CDATA section" end
            if not stack[#stack].skip then
                append_text(stack[#stack], xml:sub(lt + 9, close - 1), false)
            end
            pos = close + 3
        elseif xml:sub(lt, lt + 3) == "<!--" then
            local close = xml:find("-->", lt + 4, true)
            if not close then return nil, "Unclosed XML comment" end
            pos = close + 3
        elseif xml:sub(lt, lt + 1) == "<?" then
            local close = xml:find("?>", lt + 2, true)
            if not close then return nil, "Unclosed XML instruction" end
            pos = close + 2
        elseif xml:sub(lt, lt + 1) == "<!" then
            -- Do not resolve DTDs or external entities.
            local close = tag_end(xml, lt + 2)
            if not close then return nil, "Unclosed XML declaration" end
            pos = close + 1
        else
            local close = tag_end(xml, lt + 1)
            if not close then return nil, "Unclosed XML tag" end
            local raw = xml:sub(lt + 1, close - 1)
            local closing = raw:match("^%s*/") ~= nil
            local self_closing = raw:match("/%s*$") ~= nil
            local name, rest
            if closing then
                name = raw:match("^%s*/%s*([%w_:%.-]+)")
                if not name or #stack <= 1 or stack[#stack].name ~= name:lower() then
                    return nil, "Mismatched XML closing tag"
                end
                table.remove(stack)
            else
                name, rest = raw:match("^%s*([%w_:%.-]+)(.*)$")
                if not name then return nil, "Invalid XML tag" end
                name = name:lower()
                local parent = stack[#stack]
                local skip = parent.skip
                if name == "item" or name == "entry" then
                    episode_count = episode_count + 1
                    if episode_count > MAX_EPISODES then skip = true end
                elseif not skip and parent.name == "item"
                        and not rss_episode_fields[name] then
                    skip = true
                elseif not skip and parent.name == "entry"
                        and not atom_episode_fields[name] then
                    skip = true
                end
                local node = {
                    name = name,
                    attrs = parse_attributes(rest or ""),
                    children = {},
                    content = {},
                    skip = skip,
                }
                if not skip then
                    table.insert(parent.children, node)
                    table.insert(parent.content, node)
                end
                if not self_closing then table.insert(stack, node) end
            end
            pos = close + 1
        end
    end

    if #stack ~= 1 then return nil, "Incomplete XML document" end
    return root
end

local function child(node, name)
    if not node then return nil end
    name = name:lower()
    for _, item in ipairs(node.children) do
        if item.name == name then return item end
    end
end

local function children(node, name)
    local result = {}
    if not node then return result end
    name = name:lower()
    for _, item in ipairs(node.children) do
        if item.name == name then table.insert(result, item) end
    end
    return result
end

local function node_text(node)
    if not node then return "" end
    local pieces = {}
    for _, part in ipairs(node.content) do
        if type(part) == "string" then
            table.insert(pieces, part)
        else
            table.insert(pieces, node_text(part))
        end
    end
    return table.concat(pieces):match("^%s*(.-)%s*$") or ""
end

local function first_text(node, names)
    for _, name in ipairs(names) do
        local found = child(node, name)
        if found then
            local value = node_text(found)
            if value ~= "" then return value end
        end
    end
    return ""
end

local function valid_audio_url(url)
    return type(url) == "string" and url:match("^https?://") ~= nil
        and not url:find("[\r\n]")
end

local function looks_like_audio(url, mime_type)
    if mime_type and mime_type:lower():match("^audio/") then return true end
    local path = tostring(url or ""):match("^https?://[^/]+([^?#]*)") or ""
    local ext = path:match("%.([%w]+)$")
    ext = ext and ext:lower()
    return ext == "aac" or ext == "flac" or ext == "m4a" or ext == "m4b"
        or ext == "mp3" or ext == "mp4" or ext == "ogg" or ext == "wav"
end

local function rss_enclosure(item)
    for _, enclosure in ipairs(children(item, "enclosure")) do
        if valid_audio_url(enclosure.attrs.url)
                and looks_like_audio(enclosure.attrs.url, enclosure.attrs.type) then
            return enclosure.attrs.url, enclosure.attrs.type, tonumber(enclosure.attrs.length)
        end
    end
    -- media:content is commonly used by podcast hosts.
    for _, media in ipairs(children(item, "media:content")) do
        if valid_audio_url(media.attrs.url) and (media.attrs.medium == "audio"
                or (media.attrs.type or ""):match("^audio/")) then
            return media.attrs.url, media.attrs.type, tonumber(media.attrs.fileSize)
        end
    end
end

local function atom_enclosure(item)
    for _, link in ipairs(children(item, "link")) do
        if (link.attrs.rel or ""):lower() == "enclosure" and valid_audio_url(link.attrs.href)
                and looks_like_audio(link.attrs.href, link.attrs.type) then
            return link.attrs.href, link.attrs.type, tonumber(link.attrs.length)
        end
    end
end

local function normalize_image_url(value, base_url)
    value = type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
    if value == "" or value:find("[\r\n]") then return nil end
    if not value:match("^https?://") and value:match("^%a[%w+%.%-]*:") then
        return nil
    end
    if not value:match("^https?://") then
        if not base_url or not base_url:match("^https?://") then return nil end
        local scheme, authority = base_url:match("^(https?)://([^/]+)")
        if not scheme or not authority then return nil end
        local base_path = base_url:match("^[^/]+://[^/]+(/[^?#]*)")
        if value:sub(1, 2) == "//" then
            value = scheme .. ":" .. value
        else
            local reference_path, suffix = value:match("^([^?#]*)(.*)$")
            if reference_path == "" then
                reference_path = base_path or "/"
            elseif reference_path:sub(1, 1) ~= "/" then
                local base_dir = (base_path or "/"):match("^(.*)/") or ""
                reference_path = base_dir .. "/" .. reference_path
            end
            local segments = {}
            for segment in reference_path:gmatch("[^/]+") do
                if segment == ".." then
                    table.remove(segments)
                elseif segment ~= "." then
                    table.insert(segments, segment)
                end
            end
            value = scheme .. "://" .. authority .. "/" .. table.concat(segments, "/") .. suffix
        end
    end
    if not value:match("^https?://") or value:find("[\r\n]") then return nil end
    return value
end

local function feed_image_url(container, is_atom, base_url)
    if is_atom then
        for _, name in ipairs({ "logo", "icon" }) do
            local image_url = normalize_image_url(first_text(container, { name }), base_url)
            if image_url then return image_url end
        end
        for _, link in ipairs(children(container, "link")) do
            local rel = (link.attrs.rel or ""):lower()
            if rel == "icon" or rel == "logo" then
                local image_url = normalize_image_url(link.attrs.href, base_url)
                if image_url then return image_url end
            end
        end
        return nil
    end

    local itunes_image = child(container, "itunes:image")
    local image_url = normalize_image_url(itunes_image and itunes_image.attrs.href, base_url)
    if image_url then return image_url end

    local podcast_images = child(container, "podcast:images")
    local podcast_image = child(podcast_images, "podcast:image")
    image_url = normalize_image_url(podcast_image and podcast_image.attrs.href, base_url)
    if image_url then return image_url end

    local image = child(container, "image")
    return normalize_image_url(first_text(image, { "url" }), base_url)
end

function Parser.parse(xml, base_url)
    if type(xml) ~= "string" then return nil, "Feed response is not text" end
    local root, err = parse_xml(xml)
    if not root then return nil, err end

    local rss = child(root, "rss")
    local channel = child(rss, "channel")
    local atom = child(root, "feed")
    local is_atom = channel == nil and atom ~= nil
    if not channel and not atom then return nil, "Unrecognised RSS or Atom feed" end

    local container = channel or atom
    local feed = {
        title = first_text(container, { "title" }),
        artwork_url = feed_image_url(container, is_atom, base_url),
        episodes = {},
    }
    local raw_items = children(container, is_atom and "entry" or "item")
    for _, item in ipairs(raw_items) do
        local enclosure_url, mime_type, length
        if is_atom then
            enclosure_url, mime_type, length = atom_enclosure(item)
        else
            enclosure_url, mime_type, length = rss_enclosure(item)
        end
        if enclosure_url then
            table.insert(feed.episodes, {
                title = first_text(item, { "title" }),
                guid = first_text(item, is_atom and { "id" } or { "guid" }),
                date = first_text(item, is_atom
                    and { "published", "updated" } or { "pubdate", "dc:date" }),
                enclosure_url = enclosure_url,
                mime_type = mime_type or "",
                length = length,
            })
        end
    end
    return feed
end

return Parser
