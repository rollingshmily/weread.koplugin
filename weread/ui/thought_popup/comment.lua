-- Thought-popup comment / reply helpers. Upload is eink-only.

local UIManager = require("ui/uimanager")
local PluginUtil = require("weread.lib.plugin_util")
local logger = require("weread.lib.logger")
local _ = PluginUtil.tr
local T = PluginUtil.T

local Comment = {}
Comment._ctx = nil

function Comment.setContext(ctx)
    Comment._ctx = ctx
end

function Comment.resolve(popup)
    local ctx = {}
    local function take(src)
        if type(src) ~= "table" then return end
        for _, key in ipairs({
            "plugin", "book_id", "chapter_uid", "range", "abstract",
        }) do
            if ctx[key] == nil and src[key] ~= nil and src[key] ~= "" then
                ctx[key] = src[key]
            end
        end
        if ctx.chapter_uid == nil and src.chapterUid ~= nil then
            ctx.chapter_uid = src.chapterUid
        end
        if ctx.book_id == nil and src.bookId ~= nil then
            ctx.book_id = src.bookId
        end
    end
    take(popup and popup.comment_ctx)
    take(Comment._ctx)
    take(popup and popup.items and popup.items[1])
    take(popup)
    if ctx.plugin and (ctx.book_id == nil or ctx.book_id == "") then
        ctx.book_id = ctx.plugin._current_weread_book_id
    end
    return ctx
end

function Comment.findPieceAtY(renderer, items, y)
    local pieces = renderer and renderer.layout and renderer.layout.pieces
    if not pieces or y == nil then
        return nil, nil
    end
    local item_idx = 0
    for _, piece in ipairs(pieces) do
        if piece.variant == "meta" then
            item_idx = item_idx + 1
        end
        if piece.y and piece.piece_h and piece.y <= y and y < piece.y + piece.piece_h then
            if piece.variant == "quote" then
                return piece, items and items[1]
            end
            if item_idx >= 1 and items and item_idx <= #items then
                return piece, items[item_idx]
            end
            return piece, nil
        end
    end
    return nil, nil
end

local function notify(plugin, text, sticky)
    logger.info("thought comment:", text)
    if plugin and plugin.showInfo and sticky then
        plugin:showInfo(text)
        return
    end
    if plugin and plugin.showTransientInfo then
        plugin:showTransientInfo(text, 2)
        return
    end
    if plugin and plugin.showInfo then
        plugin:showInfo(text)
        return
    end
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = text })
end

local function can_upload(plugin)
    local client = plugin and plugin.client
    return client
        and client.can_eink_download
        and client:can_eink_download()
        and type(client.eink_add_review) == "function"
end

function Comment.prompt(title, on_submit)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = title or _("Comment"),
        input = "",
        allow_newline = true,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Send"),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog:getInputText()
                        UIManager:close(dialog)
                        if type(text) == "string" and text:match("%S") then
                            on_submit(text)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    if dialog.onShowKeyboard then
        pcall(function() dialog:onShowKeyboard() end)
    end
end

function Comment.commentOnHighlight(popup)
    local ctx = Comment.resolve(popup)
    local plugin = ctx and ctx.plugin
    logger.info("thought comment tap",
        "book=", tostring(ctx and ctx.book_id),
        "chapter=", tostring(ctx and ctx.chapter_uid),
        "range=", tostring(ctx and ctx.range),
        "plugin=", tostring(plugin ~= nil))
    if not plugin then
        notify(nil, _("Could not determine the current chapter."), true)
        return
    end
    if not can_upload(plugin) then
        notify(plugin, _("Sign in to eink to comment."), true)
        return
    end
    if not ctx.book_id or not ctx.chapter_uid or not ctx.range then
        notify(plugin, _("Could not determine the current chapter."), true)
        return
    end
    Comment.prompt(_("Comment"), function(content)
        local run = plugin.runOnlineTask and function(label, fn)
            return plugin:runOnlineTask(label, fn)
        end or function(_label, fn) fn() end
        run(_("Comment"), function()
            plugin.client:eink_add_review({
                bookId = ctx.book_id,
                chapterUid = ctx.chapter_uid,
                type = 1,
                range = ctx.range,
                content = content,
                abstract = ctx.abstract,
                bookVersion = 0,
                isPrivate = 0,
                friendship = 0,
                htmlContent = "",
                title = "",
                notVisibleToFriends = 0,
            })
            notify(plugin, _("Comment posted."))
        end)
    end)
end

function Comment.replyToItem(popup, item)
    local ctx = Comment.resolve(popup)
    local plugin = ctx and ctx.plugin
    if not plugin then
        notify(nil, _("Could not determine the current chapter."), true)
        return
    end
    if not can_upload(plugin) then
        notify(plugin, _("Sign in to eink to comment."), true)
        return
    end
    local review_id = item and (item.reviewId or item.review_id)
    if not review_id or tostring(review_id) == "" then
        notify(plugin, _("Download this chapter's thoughts again to reply."), true)
        return
    end
    local author = tostring(item.author or "")
    local title = author ~= "" and T(_("Reply to %1"), author) or _("Reply")
    Comment.prompt(title, function(content)
        local run = plugin.runOnlineTask and function(label, fn)
            return plugin:runOnlineTask(label, fn)
        end or function(_label, fn) fn() end
        run(_("Reply"), function()
            plugin.client:eink_comment_review({
                reviewId = review_id,
                content = content,
                isPrivate = 0,
                friendship = 0,
                htmlContent = "",
                atUserVid = item.authorVid or item.author_vid,
            })
            notify(plugin, _("Reply posted."))
        end)
    end)
end

function Comment.actionButtons(popup, item, extra)
    extra = extra or {}
    local rows = {}
    if extra.include_highlight then
        rows[#rows + 1] = {
            {
                text = _("Comment"),
                callback = extra.close_then(function()
                    Comment.commentOnHighlight(popup)
                end),
            },
        }
    end
    rows[#rows + 1] = {
        {
            text = _("Reply"),
            callback = extra.close_then(function()
                Comment.replyToItem(popup, item)
            end),
        },
        {
            text = _("Copy"),
            callback = extra.close_then(function()
                popup:_copyThoughtContent(item)
            end),
        },
        {
            text = _("Generate QR code"),
            callback = extra.close_then(function()
                popup:_generateQRCode(item)
            end),
        },
    }
    return rows
end

function Comment.showActionMenu(popup, item, extra)
    local action_dialog
    extra = extra or {}
    extra.close_then = extra.close_then or function(fn)
        return function()
            UIManager:close(action_dialog)
            fn()
        end
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    action_dialog = ButtonDialog:new{
        buttons = Comment.actionButtons(popup, item, extra),
    }
    UIManager:show(action_dialog)
end

return Comment
