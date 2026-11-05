local plugin_dir = (... and ... ~= "") and ... or "podcast.koplugin"
package.path = plugin_dir .. "/?.lua;" .. package.path

local Parser = require("feed_parser")

local rss = [=[<?xml version="1.0"?>
<rss version="2.0"><channel>
  <title>Ciência &amp; Café</title>
  <image><url>/images/ciencia.jpg</url></image>
  <item><title><![CDATA[Um episódio & especial]]></title>
    <guid>episode-1</guid><pubDate>Tue, 03 Nov 2026 10:00:00 GMT</pubDate>
    <enclosure url="https://audio.example/ep1.mp3" type="audio/mpeg" length="12345" />
  </item>
  <item><title>Sem áudio</title><guid>episode-2</guid></item>
</channel></rss>]=]

local parsed, err = Parser.parse(rss, "https://example.com/feed.xml")
assert(parsed, err)
assert(parsed.title == "Ciência & Café")
assert(parsed.artwork_url == "https://example.com/images/ciencia.jpg")
assert(#parsed.episodes == 1)
assert(parsed.episodes[1].title == "Um episódio & especial")
assert(parsed.episodes[1].guid == "episode-1")
assert(parsed.episodes[1].enclosure_url == "https://audio.example/ep1.mp3")
assert(parsed.episodes[1].length == 12345)

local itunes = [=[<rss><channel><title>iTunes Cast</title>
  <itunes:image href="//cdn.example.com/cover.jpg" />
</channel></rss>]=]
parsed, err = Parser.parse(itunes, "https://example.com/feed.xml")
assert(parsed, err)
assert(parsed.artwork_url == "https://cdn.example.com/cover.jpg")

local atom = [=[<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Atom Cast</title>
  <logo>https://example.com/atom-cover.png</logo>
  <entry><title>Episode A</title><id>tag:example,2026:a</id>
    <updated>2026-11-04T12:00:00Z</updated>
    <link rel="enclosure" type="audio/mpeg" length="2048" href="https://audio.example/a.m4a" />
  </entry>
</feed>]=]

parsed, err = Parser.parse(atom)
assert(parsed, err)
assert(parsed.title == "Atom Cast")
assert(parsed.artwork_url == "https://example.com/atom-cover.png")
assert(#parsed.episodes == 1)
assert(parsed.episodes[1].title == "Episode A")
assert(parsed.episodes[1].enclosure_url == "https://audio.example/a.m4a")
assert(parsed.episodes[1].length == 2048)

local invalid, invalid_err = Parser.parse("<rss><channel></rss>")
assert(not invalid and invalid_err)

print("feed_parser: OK")
