-- Thought-popup comment / reply helpers. Upload is eink-only.

local UIManager = require("ui/uimanager")
local PluginUtil = require("weread.lib.plugin_util")
local _ = PluginUtil.tr
local T = PluginUtil.T

local Comment = {}

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

local function notify(plugin, text)
    if plugin and plugin.showTransientInfo then
        plugin:showTransientInfo(text, 2)
        return
    end
    if plugin and plugin.showInfo then
        plugin:showInfo(text)
    end
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

function Comment.commentOnHighlight(ctx)
    local plugin = ctx and ctx.plugin
    if not can_upload(plugin) then
        notify(plugin, _("Sign in to eink to comment."))
        return
    end
    if not ctx.book_id or not ctx.chapter_uid or not ctx.range then
        notify(plugin, _("Could not determine the current chapter."))
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

function Comment.replyToItem(ctx, item)
    local plugin = ctx and ctx.plugin
    if not can_upload(plugin) then
        notify(plugin, _("Sign in to eink to comment."))
        return
    end
    local review_id = item and (item.reviewId or item.review_id)
    if not review_id or tostring(review_id) == "" then
        notify(plugin, _("Download this chapter's thoughts again to reply."))
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
                    Comment.commentOnHighlight(popup.comment_ctx)
                end),
            },
        }
    end
    rows[#rows + 1] = {
        {
            text = _("Reply"),
            callback = extra.close_then(function()
                Comment.replyToItem(popup.comment_ctx, item)
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
