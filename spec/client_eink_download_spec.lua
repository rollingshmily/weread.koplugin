-- chapterdownload-to-file must refresh eink on 401 before giving up.

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
    local tokens = {}
    local refreshed = false
    local client = make_client {
        eink_credentials = function()
            if refreshed then return "1", "new" end
            return "1", "old"
        end,
        eink_refresh_session = function()
            refreshed = true
            return true
        end,
        mark_eink_auth_failed = function()
            error("must not mark failed after a successful refresh retry")
        end,
        download_to_file = function(_self, _url, path, opts)
            tokens[#tokens + 1] = opts.headers.accessToken
            if opts.headers.accessToken == "old" then
                error("HTTP 401, content_type=application/json;charset=utf-8, body_bytes=0")
            end
            return path, 12, { encryptKey = "k" }
        end,
    }
    local saved, bytes = client:eink_download_to_file("20734492", "1-3", "/tmp/eink.bin")
    expect(refreshed, "401 refreshes eink before retrying chapterdownload")
    expect(tokens[1] == "old" and tokens[2] == "new", "retry uses the renewed accessToken")
    expect(saved == "/tmp/eink.bin" and bytes == 12, "refresh retry returns the ZIP path")
end

do
    local marked = false
    local client = make_client {
        eink_credentials = function() return "1", "old" end,
        eink_refresh_session = function() return false end,
        mark_eink_auth_failed = function() marked = true end,
        download_to_file = function()
            error("HTTP 401, content_type=application/json;charset=utf-8, body_bytes=0")
        end,
    }
    local ok = pcall(function()
        client:eink_download_to_file("20734492", "1-3", "/tmp/eink.bin")
    end)
    expect(not ok, "failed refresh still errors")
    expect(marked, "failed refresh marks eink auth expired")
end

print(string.format(
    "client_eink_download_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
