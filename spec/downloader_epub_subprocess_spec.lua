package.path = "./?.lua;" .. package.path

local scheduled, jobs, payloads = {}, {}, {}
local payload_seq, runs, in_child, build_runs = 0, 0, false, 0
local root = os.tmpname()
os.remove(root)
os.execute("mkdir -p " .. string.format("%q", root))

package.preload["ui/widget/confirmbox"] = function() return { new = function(_self, options) return options end } end
package.preload["device"] = function()
    return { isKindle = function() return false end, isCervantes = function() return false end, isKobo = function() return false end }
end
package.preload["pluginshare"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return { scheduleIn = function(_self, _delay, callback) scheduled[#scheduled + 1] = callback end,
        preventStandby = function() end, allowStandby = function() end, show = function() end }
end
package.preload["ui/time"] = function() return { now = function() return 1000 end } end
package.preload["socket"] = function() return { sleep = function() end } end
package.preload["ffi/util"] = function()
    return {
        template = function(text, arg) return text .. (arg and tostring(arg) or "") end,
        runInSubProcess = function(callback)
            runs = runs + 1
            jobs[runs] = {}
            in_child = true
            callback(runs, runs)
            in_child = false
            return runs, runs
        end,
        writeToFD = function(fd, data) jobs[fd].data = data return true end,
        isSubProcessDone = function() return true end,
        getNonBlockingReadSize = function(fd) return #(jobs[fd].data or "") end,
        readAllFromFD = function(fd) return jobs[fd].data or "" end,
        terminateSubProcess = function() end,
        purgeDir = function() return true end,
    }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.i18n"] = function() return { tr = function(text) return text end } end
package.preload["weread.lib.protocol"] = function()
    return { normalize_cover_url = function() return nil end, reader_url = function() return "https://reader" end }
end
package.preload["weread.lib.footnotes"] = function()
    return { scan_chapter = function() error("no footnotes") end,
        build_book_index = function() return {} end,
        transform_chapter = function(html) return html, {} end,
        validate = function() return true end, has_converted = function() return false end,
        FOOTNOTES_CSS = "" }
end
package.preload["weread.lib.thoughts"] = function() return {} end
package.preload["weread.ui.download_dialog"] = function()
    return { new = function(_self, options)
        options.show = function() end; options.close = function() end
        options.setTitle = function() end; options.reportProgress = function() end
        return options
    end }
end
package.preload["weread.lib.content"] = function()
    return {
        ensure_reader_state = function(_client, book) book.psvts = "token" end,
        create_download_workspace = function()
            local path = root .. "/workspace"
            os.execute("mkdir -p " .. string.format("%q", path))
            return { path = path, incoming_dir = path .. "/incoming", asset_dir = path .. "/images" }
        end,
        fetch_single_chapter_source = function(_client, _settings, _book, chapter)
            return "<p>chapter " .. tostring(chapter.chapterUid) .. "</p>"
        end,
        finalize_single_chapter_content = function(_client, _settings, _book, _chapter, xhtml)
            return xhtml, {}
        end,
        save_book_epub_from_files = function(_settings, _book, chapters, body_files)
            assert(in_child, "EPUB build ran in the parent process")
            assert(#chapters == 1 and body_files["1"])
            build_runs = build_runs + 1
            return root .. "/full.epub"
        end,
        cleanup_download_workspace = function() end,
    }
end

local fake_client = require("spec.helpers.eink_tar_client")(root, {
    json_encode = function(_self, value)
        payload_seq = payload_seq + 1
        local key = "payload-" .. tostring(payload_seq)
        payloads[key] = value
        return key
    end,
    json_decode = function(_self, value) return payloads[value] end,
})
local settings = {
    meta_dir = root .. "/meta", cache_dir = root,
    get = function(_self, key, default)
        if key == "cache" then return { download_book_images = false } end
        if key == "books" then return {} end
        return default
    end,
    set = function() end, flush = function() end,
}
local Downloader = require("weread.lib.downloader")
local downloader = Downloader:new{
    client = fake_client, settings = settings,
    require_login = function() return true end,
    run_online_task = function(_label, callback) callback() return true end,
    show_info = function() end, show_transient = function() end,
    refresh_ui = function() end, refresh_shelf = function() end,
    open_file = function() end, safe_callback = function(_label, callback) return callback end,
}
assert(downloader:start({ book_id = "book", title = "Build" },
    { { chapterUid = 1, title = "1" } }, "full",
    { offer_read = false, chapter_dispatch = false }), "download did not start")
while #scheduled > 0 do table.remove(scheduled, 1)() end
assert(runs == 1, "final EPUB builder was not isolated in one subprocess")
assert(build_runs == 1, "subprocess EPUB builder did not execute")
assert(downloader._active_job == nil, "async EPUB build did not finish")

os.execute("rm -rf " .. string.format("%q", root))
print("downloader_epub_subprocess_spec: passed")
