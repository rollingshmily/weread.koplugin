-- Eink-first underlines/thoughts, web fallback, whole-book list cached.

package.path = "./?.lua;./?/init.lua;" .. package.path

package.preload["ltn12"] = function() return {} end
package.preload["socketutil"] = function() return {} end
package.preload["socket.http"] = function() return {} end
package.preload["json"] = function()
    return { encode = function() return "{}" end, decode = function() return {} end }
end
package.preload["weread.lib.cookie"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return { urlencode = function(value) return tostring(value) end }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end

local Client = require("weread.lib.client")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local function make_client(overrides)
    local client = setmetatable({}, { __index = Client })
    for key, value in pairs(overrides or {}) do
        client[key] = value
    end
    return client
end

do
    local calls = {}
    local client = make_client {
        can_eink_download = function() return true end,
        eink_bookmarklist = function()
            calls[#calls + 1] = "own"
            return { updated = {
                { chapterUid = 1, range = "1-2", markText = "own" },
            } }
        end,
        eink_bestbookmarks = function()
            calls[#calls + 1] = "best"
            return { updated = {
                { chapterUid = 1, range = "3-4", markText = "best" },
                { chapterUid = 9, range = "9-10", markText = "other-chapter" },
            } }
        end,
        gateway = function()
            calls[#calls + 1] = "web"
            error("web must not run when eink bestbookmarks works")
        end,
    }
    local ok, data = client:get_chapter_underlines("book", 1)
    expect(ok and data and #data.underlines == 2, "eink merges own + popular underlines")
    expect(data.underlines[1].range == "3-4" and data.underlines[2].range == "1-2",
        "popular ranges stay first and own ranges are appended")
    expect(table.concat(calls, ",") == "own,best", "successful eink path skips web")
end

do
    local calls = {}
    local client = make_client {
        can_eink_download = function() return true end,
        eink_bookmarklist = function()
            calls[#calls + 1] = "own"
            return { updated = {} }
        end,
        eink_bestbookmarks = function()
            calls[#calls + 1] = "best"
            error("bestbookmarks down")
        end,
        gateway = function(_self, api)
            calls[#calls + 1] = api
            return { underlines = { { range = "5-6", markText = "web" } } }
        end,
    }
    local ok, data = client:get_chapter_underlines("book", 1)
    expect(ok and data.underlines[1].range == "5-6",
        "bestbookmarks failure falls back to web underlines")
    expect(table.concat(calls, ",") == "own,best,/book/underlines",
        "web underlines run only after eink popular list fails")
end

do
    local calls = {}
    local client = make_client {
        can_eink_download = function() return false end,
        gateway = function(_self, api)
            calls[#calls + 1] = api
            return { underlines = { { range = "7-8" } } }
        end,
    }
    local ok, data = client:get_chapter_underlines("book", 1)
    expect(ok and data.underlines[1].range == "7-8", "no eink credentials uses web")
    expect(calls[1] == "/book/underlines", "web underlines without eink login")
end

do
    local calls = {}
    local client = make_client {
        can_eink_download = function() return true end,
        eink_post_json = function(_self, path)
            calls[#calls + 1] = path
            return { reviews = { { range = "1-2", content = "eink" } } }
        end,
        gateway = function()
            calls[#calls + 1] = "web"
            error("web must not run when eink readreviews works")
        end,
    }
    local ok, data = client:get_chapter_reviews_batch("book", 1, {
        { range = "1-2", maxIdx = 0, count = 30, synckey = 0 },
    })
    expect(ok and data.reviews[1].content == "eink", "thoughts prefer eink POST")
    expect(table.concat(calls, ",") == "/book/readreviews", "eink thoughts skip web")
end

do
    local calls = {}
    local client = make_client {
        can_eink_download = function() return true end,
        eink_post_json = function()
            calls[#calls + 1] = "eink"
            error("eink readreviews down")
        end,
        gateway = function(_self, api)
            calls[#calls + 1] = api
            return { reviews = { { range = "1-2", content = "web" } } }
        end,
    }
    local ok, data = client:get_chapter_reviews_batch("book", 1, {
        { range = "1-2", maxIdx = 0, count = 30, synckey = 0 },
    })
    expect(ok and data.reviews[1].content == "web",
        "eink thought failure falls back to web")
    expect(table.concat(calls, ",") == "eink,/book/readreviews",
        "web thoughts run after eink POST fails")
end

do
    local fetches = 0
    local client = make_client {
        eink_json = function()
            fetches = fetches + 1
            return { updated = { { chapterUid = 1, range = "1-2" } } }
        end,
    }
    client:eink_bestbookmarks("book")
    client:eink_bestbookmarks("book")
    expect(fetches == 1, "bestbookmarks is cached per book, not per chapter")
end

do
    local eink = { vid = "1", access_token = "t" }
    local best_calls = 0
    local client = make_client {
        settings = {
            get = function(_self, key)
                if key == "eink" then return eink end
            end,
            set = function(_self, key, value)
                if key == "eink" then eink = value end
            end,
            flush = function() end,
        },
        eink_bookmarklist = function(self)
            self:mark_eink_auth_failed()
            error("HTTP 401")
        end,
        eink_bestbookmarks = function()
            best_calls = best_calls + 1
            return { updated = {} }
        end,
        gateway = function()
            return { underlines = { { range = "8-9" } } }
        end,
    }
    expect(client:can_eink_download(), "stored eink creds start usable")
    local ok, data = client:get_chapter_underlines("book", 1)
    expect(ok and data.underlines[1].range == "8-9", "401 falls back to web")
    expect(best_calls == 0, "expired eink must not hit bestbookmarks")
    expect(not client:can_eink_download(), "later thought requests skip eink")
    expect(eink.auth_failed == true, "eink expiry is remembered")
end

do
    local eink = {
        vid = "1", access_token = "old",
        refresh_token = "rt", device_id = "dev",
    }
    local client = make_client {
        settings = {
            get = function(_self, key)
                if key == "eink" then return eink end
            end,
            set = function(_self, key, value)
                if key == "eink" then eink = value end
            end,
            flush = function() end,
        },
        json_encode = function(_self, data) return data end,
        decode_http_json = function(_self, body)
            return type(body) == "table" and body or { accessToken = "new" }
        end,
        request = function()
            return { accessToken = "new", refreshToken = "rt2" }, 200, {}
        end,
    }
    expect(client:eink_refresh_session(), "refreshToken renews the eink session")
    expect(eink.access_token == "new", "accessToken is replaced after refresh")
    expect(eink.refresh_token == "rt2", "refreshToken is rotated when returned")
    expect(eink.auth_failed == nil, "refresh clears the expiry flag")
end

print(string.format(
    "client_eink_thoughts_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
