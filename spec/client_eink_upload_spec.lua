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

local function make_client()
    local posted = {}
    local client = setmetatable({}, { __index = Client })
    client.eink_post_json = function(_self, path, payload)
        posted[#posted + 1] = { path = path, payload = payload }
        return { bookmarkId = "bm-1", reviewId = "rv-1" }
    end
    return client, posted
end

do
    local client, posted = make_client()
    client:eink_add_bookmark({
        bookId = "465030",
        chapterUid = "1395",
        range = "3-7",
        markText = "你好世界",
        extra = "drop-me",
        atUserVids = {},
    })
    expect(posted[1].path == "/book/addBookmark", "add underline posts /book/addBookmark")
    expect(posted[1].payload.bookId == "465030", "bookId is copied")
    expect(posted[1].payload.chapterUid == 1395, "chapterUid is numeric")
    expect(posted[1].payload.type == 1, "underline type is 1 from APK SQL")
    expect(posted[1].payload.bookVersion == 0, "bookVersion defaults to 0")
    expect(posted[1].payload.style == 0, "style defaults to 0")
    expect(posted[1].payload.range == "3-7", "range is copied")
    expect(posted[1].payload.markText == "你好世界", "markText is copied")
    expect(posted[1].payload.extra == nil, "unknown keys are not sent")
    expect(posted[1].payload.colorStyle == nil, "colorStyle is not sent")
    expect(posted[1].payload.atUserVids == nil, "empty tables are not sent")
end

do
    local client, posted = make_client()
    client:eink_remove_bookmark("bm-1")
    expect(posted[1].path == "/book/removeBookmark", "remove posts /book/removeBookmark")
    expect(posted[1].payload.bookmarkId == "bm-1", "remove sends bookmarkId")
end

do
    local client, posted = make_client()
    client:eink_update_bookmark("bm-1", 2)
    expect(posted[1].path == "/book/updateBookmark", "update posts /book/updateBookmark")
    expect(posted[1].payload.bookmarkId == "bm-1" and posted[1].payload.style == 2,
        "update sends bookmarkId and style")
end

do
    local client, posted = make_client()
    client:eink_add_review({
        bookId = "465030",
        chapterUid = 1395,
        range = "3-7",
        content = "这条想法",
        abstract = "你好世界",
        isPrivate = 0,
        atUserVids = {},
    })
    expect(posted[1].path == "/review/add", "thought posts /review/add")
    expect(posted[1].payload.content == "这条想法", "review content is copied")
    expect(posted[1].payload.abstract == "你好世界", "review abstract is the quote")
    expect(posted[1].payload.atUserVids == nil, "review does not send empty atUserVids")
    expect(posted[1].payload.type == 1, "review type defaults to 1")
    expect(posted[1].payload.bookVersion == 0, "review bookVersion defaults to 0")
    expect(posted[1].payload.htmlContent == "", "review htmlContent defaults to empty string")
end

do
    local client, posted = make_client()
    client:eink_useredit_review({
        reviewId = "rv-1",
        content = "改过的想法",
        extra = "drop",
    })
    expect(posted[1].path == "/review/useredit", "edit posts /review/useredit")
    expect(posted[1].payload.reviewId == "rv-1", "useredit sends reviewId")
    expect(posted[1].payload.content == "改过的想法", "useredit sends content")
    expect(posted[1].payload.extra == nil, "useredit drops unknown keys")
end

do
    local client, posted = make_client()
    client:eink_delete_review("rv-1")
    expect(posted[1].path == "/review/delete", "delete posts /review/delete")
    expect(posted[1].payload.reviewId == "rv-1", "delete sends reviewId")
end

do
    local client = make_client()
    local ok = pcall(client.eink_add_bookmark, client, { bookId = "1" })
    expect(not ok, "addBookmark without range/markText errors")
    ok = pcall(client.eink_remove_bookmark, client, "")
    expect(not ok, "removeBookmark without id errors")
    ok = pcall(client.eink_delete_review, client, "")
    expect(not ok, "deleteReview without id errors")
end

print(string.format("client_eink_upload_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
