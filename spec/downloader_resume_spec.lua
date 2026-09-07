package.path = "./?.lua;" .. package.path

local scheduled = {}
local source_calls = {}
local finalized = {}
local encoded_state
local root = os.tmpname()
os.remove(root)
os.execute("mkdir -p " .. string.format("%q", root))

package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["device"] = function()
    return {
        isKindle = function() return false end,
        isCervantes = function() return false end,
        isKobo = function() return false end,
    }
end
package.preload["pluginshare"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback) scheduled[#scheduled + 1] = callback end,
        preventStandby = function() end,
        allowStandby = function() end,
        show = function() end,
    }
end
package.preload["ui/time"] = function() return { now = function() return 1000 end } end
package.preload["ffi/util"] = function()
    return {
        template = function(text, ...) return text end,
        purgeDir = function() return true end,
    }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.i18n"] = function() return { tr = function(text) return text end } end
package.preload["weread.lib.protocol"] = function()
    return {
        normalize_cover_url = function() return nil end,
        reader_url = function(book_id) return "https://reader/" .. tostring(book_id) end,
    }
end
package.preload["weread.lib.footnotes"] = function()
    return {
        scan_chapter = function() error("no footnotes in fixture") end,
        build_book_index = function() return {} end,
        transform_chapter = function(html) return html, {} end,
        validate = function() return true end,
        has_converted = function() return false end,
        FOOTNOTES_CSS = "",
    }
end
package.preload["weread.lib.thoughts"] = function() return {} end
package.preload["weread.ui.download_dialog"] = function()
    return {
        new = function(_self, options)
            options.show = function() end
            options.close = function() end
            options.setTitle = function() end
            options.reportProgress = function() end
            return options
        end,
    }
end
package.preload["weread.lib.content"] = function()
    return {
        ensure_reader_state = function() end,
        create_download_workspace = function(_settings, _book)
            local path = root .. "/workspace"
            os.execute("mkdir -p " .. string.format("%q", path))
            return {
                path = path,
                incoming_dir = path .. "/incoming",
                asset_dir = path .. "/images",
            }
        end,
        fetch_single_chapter_source = function(_client, _settings, _book, chapter)
            source_calls[#source_calls + 1] = chapter.chapterUid
            return "<p>new chapter " .. tostring(chapter.chapterUid) .. "</p>"
        end,
        finalize_single_chapter_content = function(_client, _settings, _book, chapter, xhtml)
            finalized[#finalized + 1] = chapter.chapterUid
            return xhtml, {}
        end,
        save_book_epub_from_files = function(_settings, _book, chapters, body_files)
            assert(#chapters == 2, "resumed chapter was not included in final EPUB")
            assert(body_files["1"] and body_files["2"], "body files were not complete")
            return root .. "/full.epub"
        end,
        cleanup_download_workspace = function() end,
    }
end

local Checkpoint = require("weread.lib.download_checkpoint")
local workspace = root .. "/workspace"
os.execute("mkdir -p " .. string.format("%q", workspace .. "/chapters"))
local saved_body = workspace .. "/chapters/1.xhtml"
local body_file = assert(io.open(saved_body, "wb"))
body_file:write("<p>already downloaded</p>")
body_file:close()
local fake_client = {
    json_encode = function(_self, value) encoded_state = value return "payload" end,
    json_decode = function() return encoded_state end,
}
local settings = {
    meta_dir = root .. "/meta",
    cache_dir = root,
    get = function(_self, key, default)
        if key == "cache" then return { download_book_images = false } end
        if key == "books" then return {} end
        return default
    end,
    set = function() end,
    flush = function() end,
}
local checkpoint_path = Checkpoint.path(settings, { book_id = "book" })
assert(Checkpoint.save(fake_client, checkpoint_path, {
    version = 1,
    book_id = "book",
    suffix = "full",
    workspace = workspace,
    completed = {
        ["1"] = {
            uid = "1",
            source_path = saved_body,
            assets = {},
        },
    },
    css = "body{}",
}))

local Downloader = require("weread.lib.downloader")
local downloader = Downloader:new{
    client = fake_client,
    settings = settings,
    require_login = function() return true end,
    run_online_task = function(_label, callback) callback() return true end,
    show_info = function() end,
    show_transient = function() end,
    refresh_ui = function() end,
    refresh_shelf = function() end,
    open_file = function() end,
    safe_callback = function(_label, callback) return callback end,
}
local book = { book_id = "book", title = "Resumable" }
local chapters = {
    { chapterUid = 1, title = "One" },
    { chapterUid = 2, title = "Two" },
}
assert(downloader:start(book, chapters, "full", { offer_read = false }),
    "resumable full download did not start")
while #scheduled > 0 do
    local callback = table.remove(scheduled, 1)
    callback()
end
assert(#source_calls == 1 and source_calls[1] == 2,
    "completed chapter was downloaded again")
assert(#finalized == 1 and finalized[1] == 2,
    "only missing chapter should be finalized")
assert(downloader._active_job == nil, "resumable download did not finish")

os.execute("rm -rf " .. string.format("%q", root))
print("downloader_resume_spec: passed")
