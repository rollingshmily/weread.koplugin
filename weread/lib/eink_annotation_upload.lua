-- Upload local KOReader highlights/thoughts through the eink APIs.
-- Web gateway is not used. Missing login, chapter, or unique range skips upload.

local Annotations = require("weread.lib.annotations")
local Chapters = require("weread.lib.annotation_chapters")
local Eink = require("weread.lib.eink")
local logger = require("weread.lib.logger")

local unpack = unpack

local Upload = {}
Upload._html_cache = {}

local function annotation_item(...)
    for index = 1, select("#", ...) do
        local value = select(index, ...)
        if type(value) == "table" and (value.pos0 or value.text or value.datetime or value.note) then
            return value
        end
    end
end

local function mark_text(item)
    if type(item) ~= "table" then return nil end
    local text = item.text or item.selected_text or item.underline_text
    if type(text) == "string" and text ~= "" then
        return text
    end
    return nil
end

local function thought_text(item)
    if type(item) ~= "table" then return nil end
    local note = item.note or item.comments
    if type(note) == "string" and note:match("%S") then
        return note
    end
    return nil
end

local function bookmark_id_from_response(data)
    if type(data) ~= "table" then return nil end
    local id = data.bookmarkId or data.bookMarkId
    if (not id or tostring(id) == "") and type(data.bookmark) == "table" then
        id = data.bookmark.bookmarkId or data.bookmark.bookMarkId
    end
    if id and tostring(id) ~= "" then
        return tostring(id)
    end
    return nil
end

local function review_id_from_response(data)
    if type(data) ~= "table" then return nil end
    local id = data.reviewId
    if (not id or tostring(id) == "") and type(data.review) == "table" then
        id = data.review.reviewId
    end
    if id and tostring(id) ~= "" then
        return tostring(id)
    end
    return nil
end

function Upload.lookup_bookmark_id(client, book_id, chapter_uid, range)
    if not client or not client.eink_bookmarklist then return nil end
    client._eink_bookmark_cache = nil
    local ok, data = pcall(client.eink_bookmarklist, client, book_id)
    if not ok or type(data) ~= "table" then
        return nil
    end
    for _, item in ipairs(Eink.collect_bookmark_items(data)) do
        if tostring(item.chapterUid) == tostring(chapter_uid)
            and tostring(item.range) == tostring(range)
            and item.bookmarkId and tostring(item.bookmarkId) ~= "" then
            return tostring(item.bookmarkId)
        end
    end
    return nil
end

function Upload.chapter_for_item(plugin, book, item)
    if not plugin or not book then return nil end
    local file_path = plugin.ui and plugin.ui.document and plugin.ui.document.file
    if type(plugin.getChapterInfoFromFile) == "function" then
        local _, chapter, is_full_book = plugin:getChapterInfoFromFile(book, file_path)
        if chapter and not is_full_book then
            return chapter
        end
    end
    local document = plugin.ui and plugin.ui.document
    local point = item and (item.pos0 or item.xpointer)
    if document and point then
        local context = plugin._annotation_context
        if context and context.chapters and context.ranges then
            local located = Chapters.at_xpointer(
                document, context.chapters, context.ranges, point)
            if located then return located end
        end
    end
    if type(plugin.getCurrentMappedChapter) == "function" then
        return plugin:getCurrentMappedChapter()
    end
    return nil
end

function Upload.original_chapter_html(client, book, chapter)
    if not client or not book or not chapter then return nil end
    local book_id = tostring(book.book_id or book.bookId or "")
    local uid = tostring(chapter.chapterUid or "")
    if book_id == "" or uid == "" then return nil end
    local cache_key = book_id .. ":" .. uid
    if Upload._html_cache[cache_key] then
        return Upload._html_cache[cache_key]
    end
    local param = Eink.build_chapters_param({ chapter.chapterUid })
    if param == "" then return nil end
    local ok, files = pcall(client.eink_download_zip, client, book_id, param)
    if not ok or type(files) ~= "table" then
        logger.warn("eink upload chapter zip failed:", tostring(files))
        return nil
    end
    local bodies = Eink.files_to_chapter_bodies(files, { chapter })
    local html = bodies and bodies[uid]
    if type(html) ~= "string" or html == "" then
        return nil
    end
    Upload._html_cache[cache_key] = html
    return html
end

function Upload.range_for_item(client, book, chapter, item)
    local text = mark_text(item)
    if not text then return nil end
    local html = Upload.original_chapter_html(client, book, chapter)
    if not html then return nil end
    return Annotations.rangeFromMarkText(html, text)
end

function Upload.can_upload(plugin)
    local client = plugin and plugin.client
    if not client or not client.can_eink_download or not client:can_eink_download() then
        return false
    end
    return plugin._current_weread_book_id ~= nil
end

local function persist_weread(item, fields)
    if type(item) ~= "table" then return end
    item.weread = item.weread or {}
    for key, value in pairs(fields) do
        item.weread[key] = value
    end
end

local function locate(plugin, item)
    local text = mark_text(item)
    if not text then return nil, "no_text" end
    local book_id = tostring(plugin._current_weread_book_id or "")
    local books = plugin.settings and plugin.settings.get and plugin.settings:get("books", {}) or {}
    local book = books[book_id] or books[plugin._current_weread_book_id]
    local chapter = Upload.chapter_for_item(plugin, book, item)
    if not chapter or chapter.chapterUid == nil then
        return nil, "no_chapter"
    end
    local range = item.weread and item.weread.range
    if not range or range == "" then
        range = Upload.range_for_item(plugin.client, book, chapter, item)
    end
    if not range then
        logger.warn("eink upload skipped: unique range not found")
        return nil, "no_range"
    end
    persist_weread(item, {
        chapterUid = chapter.chapterUid,
        range = range,
        bookId = book_id,
    })
    return {
        book_id = book_id,
        chapter = chapter,
        range = range,
        text = text,
    }
end

function Upload.upload_added(plugin, item)
    if not Upload.can_upload(plugin) then return nil, "not_logged_in" end
    local located, err = locate(plugin, item)
    if not located then return nil, err end
    local note = thought_text(item)
    if note then
        local data = plugin.client:eink_add_review({
            bookId = located.book_id,
            chapterUid = located.chapter.chapterUid,
            type = 1,
            range = located.range,
            content = note,
            abstract = located.text,
            bookVersion = 0,
            isPrivate = 0,
            friendship = 0,
            htmlContent = "",
            title = "",
            notVisibleToFriends = 0,
        })
        local review_id = review_id_from_response(data)
        if review_id then persist_weread(item, { reviewId = review_id }) end
        logger.info("eink review uploaded", "book=", located.book_id,
            "chapter=", tostring(located.chapter.chapterUid))
        return data, "review"
    end
    local data = plugin.client:eink_add_bookmark({
        bookId = located.book_id,
        chapterUid = located.chapter.chapterUid,
        type = 1,
        range = located.range,
        markText = located.text,
        bookVersion = 0,
        style = 0,
    })
    local bookmark_id = bookmark_id_from_response(data)
        or Upload.lookup_bookmark_id(
            plugin.client, located.book_id, located.chapter.chapterUid, located.range)
    if bookmark_id then persist_weread(item, { bookmarkId = bookmark_id }) end
    logger.info("eink bookmark uploaded", "book=", located.book_id,
        "chapter=", tostring(located.chapter.chapterUid))
    return data, "bookmark"
end

function Upload.upload_updated(plugin, item)
    if not Upload.can_upload(plugin) then return nil, "not_logged_in" end
    local note = thought_text(item)
    local weread = item and item.weread or {}
    if note and weread.reviewId and tostring(weread.reviewId) ~= "" then
        local data = plugin.client:eink_useredit_review({
            reviewId = weread.reviewId,
            content = note,
            isPrivate = 0,
            friendship = 0,
            notVisibleToFriends = 0,
            type = 1,
            bookId = weread.bookId or plugin._current_weread_book_id,
            chapterUid = weread.chapterUid,
            range = weread.range,
            abstract = mark_text(item),
        })
        logger.info("eink review edited", "reviewId=", weread.reviewId)
        return data, "review_edit"
    end
    if note and (not weread.reviewId or weread.reviewId == "") then
        return Upload.upload_added(plugin, item)
    end
    if (not note) and weread.reviewId and tostring(weread.reviewId) ~= "" then
        local data = plugin.client:eink_delete_review(weread.reviewId)
        if item.weread then item.weread.reviewId = nil end
        logger.info("eink review deleted", "reviewId=", weread.reviewId)
        return data, "review_delete"
    end
    return nil, "no_review_change"
end

function Upload.upload_removed(plugin, item)
    if not Upload.can_upload(plugin) then return nil, "not_logged_in" end
    local weread = item and item.weread or {}
    local last
    if weread.reviewId and tostring(weread.reviewId) ~= "" then
        last = plugin.client:eink_delete_review(weread.reviewId)
        logger.info("eink review deleted", "reviewId=", weread.reviewId)
    end
    local bookmark_id = weread.bookmarkId
    if (not bookmark_id or bookmark_id == "") and weread.bookId
        and weread.chapterUid and weread.range then
        bookmark_id = Upload.lookup_bookmark_id(
            plugin.client, weread.bookId, weread.chapterUid, weread.range)
    end
    if bookmark_id and bookmark_id ~= "" then
        last = plugin.client:eink_remove_bookmark(bookmark_id)
        logger.info("eink bookmark removed", "bookmarkId=", bookmark_id)
        return last, "bookmark"
    end
    if last then return last, "review" end
    logger.warn("eink upload skip remove: no bookmarkId/reviewId")
    return nil, "no_bookmark_id"
end

function Upload.handle(plugin, method, ...)
    local item = annotation_item(...)
    if not item then return end
    local ok, err = pcall(function()
        if method == "addItem" then
            Upload.upload_added(plugin, item)
        elseif method == "removeItem" then
            Upload.upload_removed(plugin, item)
        elseif method == "updateItem" then
            Upload.upload_updated(plugin, item)
        end
    end)
    if not ok then
        logger.warn("eink annotation upload failed:", tostring(err))
    end
end

local function wrap_method(plugin, annotation, name)
    local original = annotation[name]
    if type(original) ~= "function" then return end
    plugin._eink_upload_originals[name] = original
    if name == "removeItemByIndex" then
        annotation[name] = function(annotation_self, index, ...)
            local item = annotation_self.annotations and annotation_self.annotations[index]
            local results = { original(annotation_self, index, ...) }
            if item then Upload.handle(plugin, "removeItem", item) end
            return unpack(results)
        end
        return
    end
    local mapped = name == "updateItem" and "updateItem" or name
    annotation[name] = function(annotation_self, ...)
        local results = { original(annotation_self, ...) }
        Upload.handle(plugin, mapped, ...)
        return unpack(results)
    end
end

function Upload.install(plugin)
    local annotation = plugin and plugin.ui and plugin.ui.annotation
    if not annotation then return false end
    if plugin._eink_upload_target == annotation then return true end
    Upload.uninstall(plugin)
    plugin._eink_upload_target = annotation
    plugin._eink_upload_originals = {}
    for _, name in ipairs({ "addItem", "removeItem", "removeItemByIndex", "updateItem" }) do
        wrap_method(plugin, annotation, name)
    end
    return true
end

function Upload.uninstall(plugin)
    local annotation = plugin and plugin._eink_upload_target
    local originals = plugin and plugin._eink_upload_originals
    if annotation and type(originals) == "table" then
        for name, original in pairs(originals) do
            if annotation[name] ~= original then
                annotation[name] = original
            end
        end
    end
    if plugin then
        plugin._eink_upload_target = nil
        plugin._eink_upload_originals = nil
    end
    Upload._html_cache = {}
end

return Upload
