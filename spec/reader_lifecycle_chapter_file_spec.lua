package.path = "./?.lua;" .. package.path

package.preload["weread.lib.content"] = function()
    return {}
end
package.preload["weread.lib.logger"] = function()
    return { scoped = function() return { warn = function() end } end }
end
package.preload["weread.lib.protocol"] = function()
    return {}
end
package.preload["ui/uimanager"] = function()
    return {}
end
local existing = {
    ["/books/fanren - full.epub"] = true,
}
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
        display_error = tostring,
        file_exists = function(path) return existing[path] == true end,
        log_error = tostring,
    }
end
package.preload["datastorage"] = function()
    return {
        getFullDataDir = function() return "/data" end,
        getSettingsDir = function() return "/settings" end,
    }
end
package.preload["luasettings"] = function()
    return { open = function() return { readSetting = function() return {} end } end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() return nil end, mkdir = function() return true end }
end
package.preload["weread.lib.book_store"] = function()
    return { load = function() return {} end, save = function() return true, {} end }
end

local Lifecycle = require("weread.lib.reader_lifecycle")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local host = {}
for key, value in pairs(Lifecycle) do host[key] = value end

local book = {
    chapters = { { chapterUid = 1287 }, { chapterUid = 1288 } },
    cached_file = "/books/fanren (tv) - full.epub",
    cached_full_book = "/books/fanren (tv) - full.epub",
}
local idx, chapter, is_full = host:getChapterInfoFromFile(
    book, "/books/fanren - full.epub")
expect(idx == nil and chapter == nil and is_full == true,
    "renamed combined EPUB is still a full book for progress sync")

print(string.format(
    "reader_lifecycle_chapter_file_spec: %d checks, %d failure(s)",
    checks, failures))
os.exit(failures == 0 and 0 or 1)
