package.path = "./?.lua;" .. package.path

package.preload["weread.lib.crypto"] = function() return {} end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return {
        reader_url = function(book_id, chapter_uid)
            return "https://reader/" .. tostring(book_id) .. "/" .. tostring(chapter_uid or "")
        end,
        make_content_params = function() return {} end,
    }
end
package.preload["weread.lib.thoughts"] = function() return {} end
package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["bit"] = function() return { rshift = function(value, bits) return math.floor(value / 2 ^ bits) end } end
package.preload["socket"] = function() return { sleep = function() end } end
local process_jobs = {}
local process_runs = 0
package.preload["ffi/util"] = function()
    return {
        runInSubProcess = function(callback)
            process_runs = process_runs + 1
            local pid = process_runs
            local job = {}
            process_jobs[pid] = job
            callback(pid, pid)
            return pid, pid
        end,
        writeToFD = function(fd, data) process_jobs[fd].data = data return true end,
        isSubProcessDone = function() return true end,
        getNonBlockingReadSize = function(fd) return #(process_jobs[fd].data or "") end,
        readAllFromFD = function(fd) return process_jobs[fd].data end,
        terminateSubProcess = function() end,
    }
end

local Content = require("weread.lib.content")
local ensure_calls = 0
Content.ensure_reader_state = function(_client, book)
    ensure_calls = ensure_calls + 1
    book.psvts = "reused-session-token"
end
Content.fetch_chapter_shard = function(_client, _settings, _book, _chapter, endpoint)
    return endpoint == "/web/book/chapter/e_2" and "css" or "shard"
end
Content.decode_content_shards = function() return "<p>body</p>" end
Content.decode_content_shard = function() return "body{}" end

local client = {
    json_encode = function(_self, value)
        return value.ok and "ok" or "error"
    end,
    json_decode = function(_self, value)
        return { ok = value == "ok" }
    end,
}
local settings = {
    meta_dir = "/tmp/weread-reader-state-spec-meta",
    get = function() return { download_book_images = false } end,
}
local book = { book_id = "book" }
local state = { parallel_shards = true }
assert(Content.fetch_single_chapter_source(client, settings, book,
    { chapterUid = 1 }, state) == "<p>body</p>", "first chapter failed")
assert(Content.fetch_single_chapter_source(client, settings, book,
    { chapterUid = 2 }, state) == "<p>body</p>", "second chapter failed")
assert(ensure_calls == 1,
    "reader state was refreshed once per chapter instead of reused")
assert(process_runs == 6,
    "parallel shard mode did not dispatch three shards per chapter")

print("content_reader_state_reuse_spec: passed")
