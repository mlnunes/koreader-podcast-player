local plugin_dir = (... and ... ~= "") and ... or "podcast.koplugin"
package.path = plugin_dir .. "/?.lua;" .. package.path

local response_body = '{"status":"true","feeds":[]}'
local captured_request
local sha_input

package.preload["ffi/sha2"] = function()
    return {
        sha1 = function(value)
            sha_input = value
            return "test-digest"
        end,
    }
end
package.preload["socket.url"] = function()
    return {
        escape = function(value)
            return (value:gsub("([^%w%-_%.~])", function(char)
                return string.format("%%%02X", char:byte())
            end))
        end,
    }
end
package.preload["socketutil"] = function()
    return {
        LARGE_BLOCK_TIMEOUT = 1,
        LARGE_TOTAL_TIMEOUT = 2,
        set_timeout = function() end,
        reset_timeout = function() end,
    }
end
package.preload["ssl.https"] = function()
    return {
        request = function(request)
            captured_request = request
            assert(request.sink(response_body))
            return 1, 200, {}, "OK"
        end,
    }
end
package.preload["rapidjson"] = function()
    return {
        decode = function(body)
            assert(body == response_body)
            local feeds = {{ url = "javascript:alert(1)", title = "Invalid" }}
            for i = 1, 22 do
                feeds[#feeds + 1] = {
                    url = "https://feeds.example/" .. i .. ".xml",
                    title = "Podcast " .. i,
                    author = "Author " .. i,
                    artwork = "https://images.example/" .. i .. ".jpg",
                }
            end
            return { status = "true", feeds = feeds }
        end,
    }
end

local Client = require("podcast_index_client")
local headers = Client.buildAuthHeaders("api-key", "api-secret", 123456)
assert(sha_input == "api-keyapi-secret123456", "auth digest input should match API requirements")
assert(headers["X-Auth-Key"] == "api-key")
assert(headers["X-Auth-Date"] == "123456")
assert(headers.Authorization == "test-digest")

local feeds, err = Client.search("podcast três", "api-key", "api-secret")
assert(feeds, err)
assert(#feeds == 20, "search results should be limited to 20 valid feed URLs")
assert(feeds[1].title == "Podcast 1" and feeds[1].author == "Author 1")
assert(feeds[1].url == "https://feeds.example/1.xml")
assert(Client.resultText(feeds[1]) == "Podcast 1 · Author 1")
assert(Client.resultText({ title = "", author = "", url = "https://feeds.example/feed.xml" })
    == "https://feeds.example/feed.xml")
assert(captured_request.url:find("q=podcast%20tr%C3%AAs", 1, true),
    "search term should be URL-encoded")
assert(captured_request.url:find("max=20", 1, true))
assert(captured_request.headers["X-Auth-Key"] == "api-key")
assert(captured_request.headers.Authorization == "test-digest")

local empty, empty_err = Client.search("  ", "api-key", "api-secret")
assert(not empty and empty_err == "Informe um termo para a busca")

print("podcast_index_client: OK")
