local plugin_dir = (... and ... ~= "") and ... or "podcast.koplugin"
package.path = plugin_dir .. "/?.lua;" .. package.path

local AudioProbe = require("audio_probe")

assert(AudioProbe.sniff("ID3\4\0\0\0\0\0\0") == "mp3")
assert(AudioProbe.sniff("fLaC\0\0\0\34") == "flac")
assert(AudioProbe.sniff("OggS\0\2\0\0") == nil)
assert(AudioProbe.sniff("OggS" .. string.rep("\0", 24)
    .. "\1vorbis" .. string.rep("\0", 16)) == "ogg")
assert(AudioProbe.sniff("OggS" .. string.rep("\0", 24)
    .. "OpusHead" .. string.rep("\0", 16)) == nil)
assert(AudioProbe.sniff("RIFF\0\0\0\0WAVEfmt ") == "wav")
assert(AudioProbe.sniff("\0\0\0 \102typM4A ") == "m4a")
assert(AudioProbe.sniff(string.char(0xFF, 0xFB, 0x90, 0x64)) == "mp3")
assert(AudioProbe.sniff(string.char(0xFF, 0xF1, 0x50, 0x80)) == nil)

assert(AudioProbe.sniff("<!DOCTYPE html><html></html>") == nil)
assert(AudioProbe.sniff("  \n<html><body>403</body></html>") == nil)
assert(AudioProbe.sniff('{"error":"forbidden"}') == nil)
assert(AudioProbe.sniff("<?xml version=\"1.0\"?><error/>") == nil)
assert(AudioProbe.sniff("") == nil)
assert(AudioProbe.sniff(nil) == nil)

print("audio_probe: OK")
