-- Weink: eink refresh, cache, and 401 latch. No web fallback.

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
    }
    expect(client:can_eink_download(), "stored eink creds start usable")
    local ok = client:get_chapter_underlines("book", 1)
    expect(not ok, "expired eink does not pretend underlines succeeded")
    expect(best_calls == 0, "expired eink must not hit bestbookmarks")
    expect(not client:can_eink_download(), "later thought requests skip eink")
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
end

print(string.format(
    "client_eink_refresh_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
