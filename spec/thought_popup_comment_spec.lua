package.path = "./?.lua;./?/init.lua;" .. package.path

package.preload["ui/uimanager"] = function()
    return { show = function() end, close = function() end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
    }
end

local Comment = require("weread.ui.thought_popup.comment")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local items = {
    { author = "海客", content = "不是跑", reviewId = "r1" },
    { author = "少平", content = "听你说", reviewId = "r2" },
}
local renderer = {
    layout = {
        pieces = {
            { variant = "quote", y = 0, piece_h = 40 },
            { variant = "meta", y = 40, piece_h = 20 },
            { variant = "content", y = 60, piece_h = 40 },
            { variant = "meta", y = 100, piece_h = 20 },
            { variant = "content", y = 120, piece_h = 50 },
        },
    },
}

local piece, item = Comment.findPieceAtY(renderer, items, 45)
expect(piece and piece.variant == "meta" and item.author == "海客",
    "tap on nickname hits the author meta line")

piece, item = Comment.findPieceAtY(renderer, items, 80)
expect(piece and piece.variant == "content" and item.author == "海客",
    "tap on comment body is content, not treated as nickname")

piece, item = Comment.findPieceAtY(renderer, items, 105)
expect(piece and piece.variant == "meta" and item.author == "少平",
    "second nickname maps to the second thought")

piece = Comment.findPieceAtY(renderer, items, 10)
expect(piece and piece.variant == "quote", "quote line is not a nickname")

expect(Comment.findPieceAtY(renderer, items, 999) == nil, "missed y returns nil")

Comment.setContext({
    plugin = { _current_weread_book_id = "465030" },
    book_id = "465030",
    chapter_uid = 1898,
    range = "10-20",
})
local ctx = Comment.resolve({ items = { { abstract = "银" } } })
expect(ctx.book_id == "465030" and ctx.chapter_uid == 1898 and ctx.range == "10-20",
    "module context fills book/chapter/range when widget ctx is missing")
expect(ctx.abstract == "银", "item abstract is used when ctx has none")
Comment.clearContext()

local stamped = Comment.attachLocation({ { author = "海客", content = "不是跑" } }, {
    book_id = "465030",
    chapter_uid = 1898,
    range = "10-20",
    abstract = "银",
})
Comment.bind({ _current_weread_book_id = "465030", client = {} })
ctx = Comment.resolve({ items = stamped })
expect(ctx.plugin ~= nil and ctx.book_id == "465030"
        and ctx.chapter_uid == 1898 and ctx.range == "10-20",
    "downloaded thought ids plus bound plugin resolve without href parsing")
Comment.setContext(nil)
ctx = Comment.resolve({ items = stamped })
expect(ctx.chapter_uid == 1898 and ctx.range == "10-20",
    "nil setContext does not wipe thought ids")
Comment.unbind()

do
    local rows = Comment.actionButtons({}, { content = "hi" })
    expect(#rows == 3 and #rows[1] == 1 and rows[1][1].text == "Reply"
            and rows[2][1].text == "Copy" and rows[3][1].text == "Generate QR code",
        "hold menu stacks reply/copy/QR as one button per row")
    rows = Comment.actionButtons({}, { content = "hi" }, { include_highlight = true })
    expect(#rows == 4 and rows[1][1].text == "Comment",
        "bottom popup hold menu keeps Comment on its own row")
end

print(string.format("thought_popup_comment_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
