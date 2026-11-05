-- Minimal audio container sniffing.
--
-- KinAMP-minimal picks its decoder from the file extension and has no
-- protection against a file that isn't audio at all. Podcast hosts routinely
-- answer an enclosure request with an HTML error page, a login page or a JSON
-- blob, and handing one of those to the player leaves it with a pipeline it
-- never drains. Both the downloader and the play path therefore check the
-- actual bytes: the downloader before a file is stored, the player before the
-- file is handed over.

local AudioProbe = {}

local HEAD_BYTES = 4096

-- Pages, feeds and JSON all start with one of these once whitespace is
-- skipped. Cheap and catches the common "the CDN said no" payloads.
local function looks_like_text(head)
    local trimmed = head:gsub("^[ \t\r\n]+", "")
    local first = trimmed:sub(1, 1)
    return first == "<" or first == "{" or first == "["
end

--- Container format from the first bytes of a file, or nil.
-- Returns one of "mp3", "m4a", "flac", "wav", "ogg" - the extensions
-- KinAMP-minimal has a decoder for.
function AudioProbe.sniff(head)
    if type(head) ~= "string" or #head < 4 then return nil end
    if looks_like_text(head) then return nil end

    if head:sub(1, 3) == "ID3" then return "mp3" end
    if head:sub(1, 4) == "fLaC" then return "flac" end
    if head:sub(1, 4) == "OggS" then
        -- KinAMP decodes Ogg with stb_vorbis, which only handles Vorbis.
        -- An Ogg Opus or Speex file would pass the extension check and then
        -- fail in the decoder, so require the Vorbis identification packet.
        if head:sub(29, 29) == "\1" and head:sub(30, 35) == "vorbis" then
            return "ogg"
        end
        return nil
    end
    if head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WAVE" then return "wav" end
    if head:sub(5, 8) == "ftyp" then return "m4a" end

    local first, second = head:byte(1), head:byte(2)
    if first == 0xFF and second and second >= 0xE0 then
        -- MPEG audio frame sync. The two layer bits tell raw ADTS AAC (layer
        -- 00) apart: KinAMP-minimal only decodes AAC inside an MP4 container,
        -- so a bare ADTS stream is not playable here.
        local layer = math.floor(second / 2) % 4
        if layer ~= 0 then return "mp3" end
    end

    return nil
end

--- Reads just the head of a file and returns its format, or nil and a reason.
function AudioProbe.probe_file(path)
    if type(path) ~= "string" or path == "" then
        return nil, "no file"
    end
    local file = io.open(path, "rb")
    if not file then return nil, "cannot open" end
    local head = file:read(HEAD_BYTES)
    file:close()
    if not head or #head == 0 then return nil, "empty" end
    local format = AudioProbe.sniff(head)
    if not format then return nil, "not audio" end
    return format
end

return AudioProbe
