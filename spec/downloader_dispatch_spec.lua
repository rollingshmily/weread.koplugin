package.path = "./?.lua;" .. package.path

local scheduled = {}
local jobs = {}
local payloads = {}
local payload_seq = 0
local suppress_output = false
local runs = 0
local root = os.tmpname()
os.remove(root)
os.execute("mkdir -p " .. string.format("%q", root))

package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["device"] = function()
    return { isKindle = function() return false end, isCervantes = function() return false end, isKobo = function() return false end }
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
package.preload["socket"] = function() return { sleep = function() end } end
package.preload["ffi/util"] = function()
    return {
        template = function(text, arg) return text .. (arg and tostring(arg) or "") end,
        runInSubProcess = function(callback)
            runs = runs + 1
            jobs[runs] = {}
            callback(runs, runs)
            return runs, runs
        end,
        writeToFD = function(fd, data)
            if suppress_output then return true end
            jobs[fd].data = data
            return true
        end,
        isSubProcessDone = function() return true end,
        getNonBlockingReadSize = function(fd) return #(jobs[fd].data or "") end,
        readAllFromFD = function(fd) return jobs[fd].data end,
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
    return {
        scan_chapter = function() error("no footnotes") end,
        build_book_index = function() return {} end,
        transform_chapter = function(html) return html, {} end,
        validate = function() return true end,
        has_converted = function() return false end,
        FOOTNOTES_CSS = "",
    }
end
package.preload["weread.lib.thoughts"] = function() return {} end
package.preload["weread.ui.download_dialog"] = function()
    return { new = function(_dialog, options)
        options.show = function() end; options.close = function() end
        options.setTitle = function() end; options.reportProgress = function() end
        options.setButtonText = function(_button_dialog, id, text)
            options.button_texts = options.button_texts or {}
            options.button_texts[id] = text
        end
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
        fetch_single_chapter_source = function(_client, _settings, _book, chapter, state)
            assert(state.reader_state_ready ~= true,
                "chapter worker reused stale Reader state")
            state.css = "body{}"
            return "<p>chapter " .. tostring(chapter.chapterUid) .. "</p>"
        end,
        finalize_single_chapter_content = function(_client, _settings, _book, _chapter, xhtml)
            return xhtml, {}
        end,
        save_book_epub_from_files = function(_settings, _book, chapters, body_files)
            assert(#chapters == 3 and body_files["1"] and body_files["2"] and body_files["3"])
            return root .. "/full.epub"
        end,
        cleanup_download_workspace = function() end,
    }
end

local fake_client = {
    json_encode = function(_self, value)
        payload_seq = payload_seq + 1
        local key = "payload-" .. tostring(payload_seq)
        payloads[key] = value
        return key
    end,
    json_decode = function(_self, value) return payloads[value] end,
}
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
assert(downloader:start({ book_id = "book", title = "Dispatch" }, {
    { chapterUid = 1, title = "1" },
    { chapterUid = 2, title = "2" },
    { chapterUid = 3, title = "3" },
}, "full", { offer_read = false }), "dispatch download did not start")
while #scheduled > 0 do
    local callback = table.remove(scheduled, 1)
    callback()
end
assert(runs == 4, "three chapter workers plus EPUB worker were not dispatched, runs=" .. tostring(runs))
assert(downloader._active_job == nil, "chapter dispatch did not finish")

-- A worker that exhausts its retries must stop the whole full-book job
-- immediately, instead of walking every remaining chapter.
suppress_output = true
scheduled = {}
jobs = {}
payloads = {}
payload_seq = 0
local info_messages = {}
local stalled = Downloader:new{
    client = fake_client, settings = settings,
    require_login = function() return true end,
    run_online_task = function(_label, callback) callback() return true end,
    show_info = function(text) info_messages[#info_messages + 1] = text end,
    show_transient = function() end,
    refresh_ui = function() end, refresh_shelf = function() end,
    open_file = function() end, safe_callback = function(_label, callback) return callback end,
}
assert(stalled:start({ book_id = "book-2", title = "No result" }, {
    { chapterUid = 1, title = "1" },
    { chapterUid = 2, title = "2" },
}, "full", { offer_read = false, chapter_concurrency = 1 }), "no-result download did not start")
local initialize = table.remove(scheduled, 1)
initialize()
local dispatch = table.remove(scheduled, 1)
local runs_before_failure = runs
stalled._active_job.dispatch_attempts[1] = 2
dispatch()
assert(stalled._active_job == nil,
    "terminal chapter failure did not stop the full-book job")
assert(runs == runs_before_failure,
    "remaining chapters were launched after terminal failure")
assert(#info_messages == 1 and tostring(info_messages[1]):find("stopped", 1, true),
    "terminal chapter failure did not show an immediate stop message")

-- Pausing stops active workers without cancelling the checkpoint; continuing
-- reuses the same job and schedules the next dispatch poll.
suppress_output = false
scheduled = {}
jobs = {}
payloads = {}
payload_seq = 0
local pausable = Downloader:new{
    client = fake_client, settings = settings,
    require_login = function() return true end,
    run_online_task = function(_label, callback) callback() return true end,
    show_info = function() end, show_transient = function() end,
    refresh_ui = function() end, refresh_shelf = function() end,
    open_file = function() end, safe_callback = function(_label, callback) return callback end,
}
assert(pausable:start({ book_id = "book-3", title = "Pausable" }, {
    { chapterUid = 1, title = "1" },
    { chapterUid = 2, title = "2" },
}, "full", { offer_read = false, chapter_concurrency = 1 }),
    "pausable download did not start")
local launch = table.remove(scheduled, 1)
launch()
local pause_dialog = pausable._active_job.progress_dialog
local pause_button = pause_dialog.buttons[1][1]
pause_button.callback()
assert(pausable._active_job.paused == true,
    "pause button did not pause the download")
assert(next(pausable._active_job.dispatch_active) == nil,
    "pause button left a chapter worker active")
assert(pause_dialog.button_texts.pause_download == "Continue download",
    "pause button did not change to continue")
pause_button.callback()
assert(pausable._active_job.paused == false,
    "continue button did not resume the download")
assert(pause_dialog.button_texts.pause_download == "Pause download",
    "continue button did not change back to pause")
assert(#scheduled > 0, "continue button did not schedule download work")

os.execute("rm -rf " .. string.format("%q", root))
print("downloader_dispatch_spec: passed")
