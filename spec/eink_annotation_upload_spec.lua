package.path = "./?.lua;./?/init.lua;" .. package.path

package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.aes"] = function() return {} end
package.preload["weread.lib.epub_path"] = function() return {} end
package.preload["bit"] = function()
    return {
        band = function() return 0 end,
        bor = function() return 0 end,
        bxor = function() return 0 end,
        lshift = function() return 0 end,
        rshift = function() return 0 end,
    }
end
package.preload["ffi"] = function() return { cdef = function() end } end

local Upload = require("weread.lib.eink_annotation_upload")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

do
    local Source = require("weread.lib.annotation_source")
    local zip_calls = 0
    local plugin = {
        _current_weread_book_id = "465030",
        client = {
            can_eink_download = function() return true end,
            eink_download_zip = function()
                zip_calls = zip_calls + 1
                error("must not download chapter zip")
            end,
            eink_add_bookmark = function(_self, payload)
                return { bookmarkId = "bm-stored", range = payload.range }
            end,
        },
        settings = {
            get = function()
                return {
                    ["465030"] = {
                        book_id = "465030",
                        chapters = { { chapterUid = 1395 } },
                    },
                }
            end,
        },
        ui = { document = { file = "/tmp/book.epub" } },
        getChapterInfoFromFile = function()
            return 1, { chapterUid = 1395 }, false
        end,
        _annotation_context = {
            store = {
                get = function(_self, _book_id, kind, key)
                    expect(kind == "original" and tostring(key) == "1395",
                        "stored original is keyed by chapter")
                    return Source.index("<p>你好世界</p>")
                end,
            },
        },
    }
    local item = { text = "你好世界", pos0 = "xpointer" }
    local _, kind = Upload.upload_added(plugin, item)
    expect(kind == "bookmark", "stored original uploads a bookmark")
    expect(item.weread.range == "3-7", "stored original yields the HTML range")
    expect(zip_calls == 0, "stored original does not download chapter zip")
end

do
    local zip_calls = 0
    local plugin = {
        _current_weread_book_id = "465030",
        client = {
            can_eink_download = function() return true end,
            eink_download_zip = function()
                zip_calls = zip_calls + 1
                error("must not download chapter zip")
            end,
            eink_add_bookmark = function()
                error("must not upload without stored original")
            end,
        },
        settings = {
            get = function()
                return {
                    ["465030"] = {
                        book_id = "465030",
                        chapters = { { chapterUid = 1395 } },
                    },
                }
            end,
        },
        ui = { document = { file = "/tmp/book.epub" } },
        getChapterInfoFromFile = function()
            return 1, { chapterUid = 1395 }, false
        end,
    }
    local _, err = Upload.upload_added(plugin, { text = "你好世界", pos0 = "xpointer" })
    expect(err == "no_range", "missing stored original skips upload")
    expect(zip_calls == 0, "missing stored original does not download chapter zip")
end

do
    local posted = {}
    local plugin = {
        _current_weread_book_id = "465030",
        client = {
            can_eink_download = function() return true end,
            eink_add_bookmark = function(_self, payload)
                posted[#posted + 1] = payload
                return { bookmarkId = "bm-9" }
            end,
            eink_add_review = function()
                error("review must not run for a highlight without a note")
            end,
        },
        settings = {
            get = function()
                return {
                    ["465030"] = {
                        book_id = "465030",
                        chapters = { { chapterUid = 1395 } },
                    },
                }
            end,
        },
        ui = { document = { file = "/tmp/ch.epub" } },
        getChapterInfoFromFile = function()
            return 1, { chapterUid = 1395 }, false
        end,
    }
    Upload.range_for_item = function() return "3-7" end
    local item = { text = "你好世界", pos0 = "xpointer" }
    local _, kind = Upload.upload_added(plugin, item)
    expect(kind == "bookmark", "highlight without note uploads a bookmark")
    expect(posted[1].type == 1 and posted[1].markText == "你好世界",
        "bookmark payload uses APK underline type and markText")
    expect(posted[1].bookVersion == 0 and posted[1].style == 0,
        "bookmark payload sends live-proved bookVersion and style")
    expect(item.weread.bookmarkId == "bm-9", "bookmarkId is stored on the local item")
end

do
    local plugin = {
        _current_weread_book_id = "465030",
        client = {
            can_eink_download = function() return false end,
            eink_add_bookmark = function()
                error("must not upload without eink login")
            end,
        },
    }
    local _, err = Upload.upload_added(plugin, { text = "x" })
    expect(err == "not_logged_in", "no eink session skips upload")
end

do
    local deleted = {}
    local plugin = {
        _current_weread_book_id = "465030",
        client = {
            can_eink_download = function() return true end,
            eink_delete_review = function(_self, review_id)
                deleted[#deleted + 1] = review_id
                return { succ = 1 }
            end,
            eink_remove_bookmark = function()
                error("thought-only delete must not remove a bookmark")
            end,
        },
    }
    local item = {
        text = "你好世界",
        note = "旧想法",
        weread = { reviewId = "rv-9", bookId = "465030" },
    }
    local _, kind = Upload.upload_removed(plugin, item)
    expect(kind == "review", "thought delete uses /review/delete")
    expect(deleted[1] == "rv-9", "reviewId is sent to eink_delete_review")
end

do
    local calls = {}
    local annotation = {
        addItem = function(_self, item)
            calls[#calls + 1] = "native"
            item.saved = true
            return true
        end,
    }
    local plugin = {
        ui = { annotation = annotation },
        _current_weread_book_id = nil,
        client = {
            can_eink_download = function() return false end,
        },
    }
    expect(Upload.install(plugin), "hook installs when ReaderAnnotation exists")
    local item = { text = "hello", pos0 = "xp" }
    annotation:addItem(item)
    expect(item.saved == true, "native addItem still runs")
    expect(table.concat(calls, ",") == "native", "native addItem is called once")
    Upload.uninstall(plugin)
    expect(annotation.addItem ~= nil, "uninstall restores a function")
end

print(string.format("eink_annotation_upload_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
