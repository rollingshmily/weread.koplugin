-- Book/chapter download engine.
--
-- Extracted from main.lua as an independent, dependency-injected object so the
-- plugin entry point keeps only thin menu wrappers. The host injects the API
-- client, settings, and a small set of UI/framework callbacks; the engine owns
-- the whole async download state machine and the device standby guard.
--
-- Standby guard: long downloads must not let the device suspend mid-transfer.
-- Every scheduled step runs through _scheduleGuarded, which wraps the step in
-- xpcall and always releases the guard (and closes the dialog + reports the
-- error) if the step throws. This is critical: a bare UIManager:scheduleIn that
-- threw would leak the guard and leave the device unable to sleep until reboot.

local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local logger = require("weread.lib.logger")
local time = require("ui/time")
local T = require("ffi/util").template

local Content = require("weread.lib.content")
local DownloadDialog = require("weread.ui.download_dialog")
local Footnotes = require("weread.lib.footnotes")
local I18n = require("weread.lib.i18n")
local StandbyGuard = require("weread.lib.standby_guard")
local Thoughts = require("weread.lib.thoughts")
local WeRead = require("weread.lib.protocol")
local WorkerSettings = require("weread.lib.worker_settings")
local Checkpoint = require("weread.lib.download_checkpoint")
local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
if not ok_ffiutil then ffiutil = nil end

local function _(text)
    return I18n.tr(text)
end

local function log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

local function display_error(err)
    local text = tostring(err)
    text = text:match("^[^\r\n]+") or text
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

local Downloader = {}
Downloader.__index = Downloader

-- o = {
--   client, settings,                       -- injected dependencies
--   show_info(text), show_transient(text, timeout),
--   refresh_ui(), refresh_shelf(),
--   open_file(path), safe_callback(label, fn),
--   require_login(cookie, api_key), run_online_task(label, fn),  -- host framework
-- }
function Downloader:new(o)
    o = o or {}
    setmetatable(o, self)
    return o
end

function Downloader:_saveCheckpoint(dl)
    if not dl or not dl.resume_enabled or not dl.checkpoint then
        return true
    end
    dl.checkpoint.css = dl.state and dl.state.css or dl.checkpoint.css
    local ok, err = Checkpoint.save(
        self.client, dl.checkpoint_path, dl.checkpoint)
    if not ok then
        logger.warn("download checkpoint save failed:", log_error(err))
    end
    return ok
end

function Downloader:_restoreCheckpointChapter(dl, chapter, entry)
    local uid = tostring(chapter.chapterUid or dl.index)
    local source_path = entry and entry.source_path
    local body = source_path and Checkpoint.read_chapter(source_path)
    if not body then
        logger.warn("download checkpoint chapter missing; redownloading:",
            "chapter_uid=", uid)
        if dl.checkpoint and dl.checkpoint.completed then
            dl.checkpoint.completed[uid] = nil
        end
        return false
    end
    dl.body_files = dl.body_files or {}
    dl.body_files[uid] = source_path
    dl.bodies[uid] = nil
    dl.assets_by_uid[uid] = entry.assets or {}
    dl.state.used_asset_names = dl.state.used_asset_names or {}
    for _i, asset in ipairs(entry.assets or {}) do
        local asset_name = tostring(asset.href or ""):match("([^/]+)$")
        if asset_name and asset_name ~= "" then
            dl.state.used_asset_names[asset_name] = true
        end
        dl.assets[#dl.assets + 1] = asset
        dl.asset_bytes = (dl.asset_bytes or 0) + (tonumber(asset.size) or 0)
    end
    dl.footnote_scans = dl.footnote_scans or {}
    if entry.footnote_scan then
        dl.footnote_scans[uid] = entry.footnote_scan
    end
    dl.selected[#dl.selected + 1] = chapter
    dl.index = dl.index + 1
    if dl.progress_dialog then
        dl.progress_dialog:reportProgress(dl.index - 1)
    end
    logger.info("download checkpoint resumed:",
        "chapter=", tostring(dl.index - 1) .. "/" .. tostring(dl.total),
        "chapter_uid=", uid)
    return true
end

function Downloader:_checkpointChapter(dl, chapter, xhtml, assets)
    if not dl.resume_enabled then return true end
    local uid = tostring(chapter.chapterUid or dl.index)
    local source_path = Checkpoint.chapter_path(dl.workspace.path, uid)
    local ok, err = Checkpoint.write_chapter(source_path, xhtml)
    if not ok then
        error(err or "could not checkpoint chapter")
    end
    dl.body_files = dl.body_files or {}
    dl.body_files[uid] = source_path
    dl.bodies[uid] = nil
    dl.checkpoint.completed[uid] = {
        uid = uid,
        index = dl.index,
        chapter = chapter,
        source_path = source_path,
        assets = assets or {},
        footnote_scan = dl.footnote_scans and dl.footnote_scans[uid] or nil,
    }
    return self:_saveCheckpoint(dl)
end

function Downloader:_dispatchAccept(dl, index, chapter, status)
    local uid = tostring(chapter.chapterUid or index)
    local source_path = status.source_path
        or Checkpoint.chapter_path(dl.workspace.path, uid)
    if not Checkpoint.read_chapter(source_path) then
        error("chapter worker produced no checkpoint: " .. uid)
    end
    local assets = status.assets or {}
    dl.selected[index] = chapter
    dl.body_files[uid] = source_path
    dl.bodies[uid] = nil
    dl.assets_by_uid[uid] = assets
    for _i, asset in ipairs(assets) do
        dl.assets[#dl.assets + 1] = asset
        dl.asset_bytes = (dl.asset_bytes or 0) + (tonumber(asset.size) or 0)
    end
    if status.footnote_scan then
        dl.footnote_scans[uid] = status.footnote_scan
    end
    if status.css and not dl.state.css then
        dl.state.css = status.css
    end
    dl.checkpoint.completed[uid] = {
        uid = uid,
        index = index,
        chapter = chapter,
        source_path = source_path,
        assets = assets,
        footnote_scan = status.footnote_scan,
    }
    self:_saveCheckpoint(dl)
    dl.dispatch_done[index] = true
    dl.dispatch_done_count = dl.dispatch_done_count + 1
end

function Downloader:_dispatchLaunch(dl, index, attempt)
    local chapter = dl.chapters[index]
    local uid = tostring(chapter.chapterUid or index)
    local worker_root = dl.workspace.path .. "/workers/" .. tostring(index)
    local incoming_dir = worker_root .. "/incoming"
    local asset_dir = worker_root .. "/images"
    os.execute("mkdir -p " .. string.format("%q", incoming_dir)
        .. " " .. string.format("%q", asset_dir))
    local source_path = Checkpoint.chapter_path(dl.workspace.path, uid)
    local client = self.client
    local settings = self.settings
    local worker_book = dl.book
    local worker_state = {
        workspace = {
            path = dl.workspace.path,
            incoming_dir = incoming_dir,
            asset_dir = asset_dir,
            asset_prefix = "chapter-" .. tostring(index),
        },
        parallel_shards = false,
        reader_state_ready = true,
    }
    local pid, read_fd = ffiutil.runInSubProcess(function(_pid, write_fd)
        local status
        local ok, result = xpcall(function()
            local xhtml = Content.fetch_single_chapter_source(
                client, settings, worker_book, chapter, worker_state)
            local final_xhtml, assets = Content.finalize_single_chapter_content(
                client, settings, worker_book, chapter, xhtml, worker_state)
            local scan_ok, scan = pcall(Footnotes.scan_chapter, final_xhtml, chapter)
            local write_ok, write_err = Checkpoint.write_chapter(source_path, final_xhtml)
            if not write_ok then error(write_err or "chapter checkpoint write failed") end
            return {
                ok = true,
                source_path = source_path,
                assets = assets or {},
                css = worker_state.css,
                footnote_scan = scan_ok and scan or nil,
            }
        end, debug.traceback)
        if ok then
            status = result
        else
            status = { ok = false, error = tostring(result) }
        end
        local encoded_ok, encoded = pcall(client.json_encode, client, status)
        if encoded_ok and encoded then
            ffiutil.writeToFD(write_fd, encoded)
        end
    end, true)
    if not pid or not read_fd then
        error("could not start chapter worker")
    end
    dl.dispatch_active[index] = {
        pid = pid, read_fd = read_fd, attempt = attempt,
        chapter = chapter, started_at = os.clock(),
    }
end

function Downloader:_dispatchStep(dl)
    if not ffiutil or not ffiutil.runInSubProcess then
        dl.chapter_dispatch_enabled = false
        return self:_step(dl)
    end
    if not dl.dispatch_initialized then
        dl.dispatch_initialized = true
        dl.dispatch_active = {}
        dl.dispatch_done = {}
        dl.dispatch_done_count = 0
        dl.dispatch_attempts = {}
        dl.dispatch_retry_at = {}
        for index, chapter in ipairs(dl.chapters) do
            local uid = tostring(chapter.chapterUid or index)
            local entry = dl.checkpoint.completed[uid]
            if entry and self:_restoreCheckpointForIndex(dl, index, chapter, entry) then
                dl.dispatch_done[index] = true
                dl.dispatch_done_count = dl.dispatch_done_count + 1
            end
        end
    end

    for index, job in pairs(dl.dispatch_active) do
        local done = ffiutil.isSubProcessDone(job.pid)
        if done then
            -- Once the child exited, its write end is closed. Reading now is
            -- safe even when it emitted no payload; treating that case as a
            -- failed attempt prevents a permanently stuck active worker.
            local raw = ffiutil.readAllFromFD(job.read_fd) or ""
            local ok, status = pcall(self.client.json_decode, self.client, raw)
            dl.dispatch_active[index] = nil
            if ok and status and status.ok then
                self:_dispatchAccept(dl, index, job.chapter, status)
            else
                local attempts = (dl.dispatch_attempts[index] or 0) + 1
                dl.dispatch_attempts[index] = attempts
                if attempts < 3 then
                    dl.dispatch_retry_at[index] = os.clock() + attempts
                else
                    dl.failed[#dl.failed + 1] = tostring(job.chapter.chapterUid or index)
                    dl.dispatch_done[index] = true
                    dl.dispatch_done_count = dl.dispatch_done_count + 1
                    logger.warn("chapter worker failed:",
                        tostring(job.chapter.chapterUid or index),
                        ok and status and status.error or raw)
                end
            end
        end
    end

    local active_count = 0
    for _index in pairs(dl.dispatch_active) do active_count = active_count + 1 end
    local display_index = math.min(dl.dispatch_done_count + 1, #dl.chapters)
    local display_chapter = dl.chapters[display_index] or {}
    self:_setStage(dl,
        T(_("Downloading chapter %1/%2: %3"),
            tostring(display_index), tostring(#dl.chapters),
            display_chapter.title or tostring(display_chapter.chapterUid or "")),
        dl.dispatch_done_count)
    for index, chapter in ipairs(dl.chapters) do
        if active_count >= dl.chapter_concurrency then break end
        if not dl.dispatch_done[index] and not dl.dispatch_active[index]
            and (not dl.dispatch_retry_at[index]
                or os.clock() >= dl.dispatch_retry_at[index]) then
            local attempt = (dl.dispatch_attempts[index] or 0) + 1
            dl.dispatch_attempts[index] = attempt
            self:_dispatchLaunch(dl, index, attempt)
            active_count = active_count + 1
        end
    end

    if dl.dispatch_done_count >= #dl.chapters and active_count == 0 then
        dl.chapter_dispatch_enabled = false
        dl.index = #dl.chapters + 1
        return self:_scheduleGuarded(dl, function() self:_step(dl) end, 0)
    end
    self:_scheduleGuarded(dl, function() self:_step(dl) end, 0.1)
end

function Downloader:_restoreCheckpointForIndex(dl, index, chapter, entry)
    local uid = tostring(chapter.chapterUid or index)
    local source_path = entry and entry.source_path
    if not source_path or not Checkpoint.read_chapter(source_path) then
        if dl.checkpoint.completed then dl.checkpoint.completed[uid] = nil end
        return false
    end
    dl.selected[index] = chapter
    dl.body_files[uid] = source_path
    dl.assets_by_uid[uid] = entry.assets or {}
    for _i, asset in ipairs(entry.assets or {}) do
        dl.assets[#dl.assets + 1] = asset
        dl.asset_bytes = (dl.asset_bytes or 0) + (tonumber(asset.size) or 0)
    end
    if entry.footnote_scan then dl.footnote_scans[uid] = entry.footnote_scan end
    if dl.checkpoint.css and not dl.state.css then dl.state.css = dl.checkpoint.css end
    return true
end

function Downloader:_canBuildEpubInSubprocess(dl)
    return dl.resume_enabled and ffiutil
        and type(ffiutil.runInSubProcess) == "function"
        and type(ffiutil.isSubProcessDone) == "function"
        and type(ffiutil.readAllFromFD) == "function"
        and type(ffiutil.writeToFD) == "function"
end

function Downloader:_startEpubBuild(dl)
    local cover_data
    local cover_url = WeRead.normalize_cover_url(dl.book.cover)
    if cover_url and cover_url ~= "" then
        pcall(function() cover_data = self.client:get_binary(cover_url) end)
    end
    local job = {
        started_at = time.now(),
        read_fd = nil,
    }
    local client = self.client
    local settings = self.settings
    local book = dl.book
    local chapters = dl.selected
    local body_files = dl.body_files
    local assets = dl.assets
    local css = dl.state.css
    local pid, read_fd = ffiutil.runInSubProcess(function(_pid, write_fd)
        local status
        local ok, result = xpcall(function()
            local path = Content.save_book_epub_from_files(
                settings, book, chapters, body_files, assets, css, cover_data)
            return { ok = true, path = path }
        end, debug.traceback)
        if ok then
            status = result
        else
            status = { ok = false, error = tostring(result) }
        end
        local encoded_ok, encoded = pcall(client.json_encode, client, status)
        if encoded_ok and encoded then
            ffiutil.writeToFD(write_fd, encoded)
        end
    end, true)
    if not pid or not read_fd then
        error("could not start EPUB build worker")
    end
    job.pid = pid
    job.read_fd = read_fd
    dl.epub_build = job
    self:_scheduleGuarded(dl, function() self:_pollEpubBuild(dl) end, 0.1)
end

function Downloader:_pollEpubBuild(dl)
    local job = dl.epub_build
    if not job then return end
    if not ffiutil.isSubProcessDone(job.pid) then
        return self:_scheduleGuarded(dl,
            function() self:_pollEpubBuild(dl) end, 0.1)
    end
    local raw = ffiutil.readAllFromFD(job.read_fd) or ""
    local ok, status = pcall(self.client.json_decode, self.client, raw)
    dl.epub_build = nil
    dl.epub_build_result = {
        ok = ok and status and status.ok == true,
        path = ok and status and status.path or nil,
        error = ok and status and status.error or raw,
        started_at = job.started_at,
    }
    self:_scheduleGuarded(dl, function() self:_step(dl) end, 0.1)
end

function Downloader:_stopDispatch(dl)
    for _index, job in pairs(dl.dispatch_active or {}) do
        if ffiutil and ffiutil.terminateSubProcess then
            pcall(ffiutil.terminateSubProcess, job.pid)
        end
    end
    if dl.epub_build and ffiutil and ffiutil.terminateSubProcess then
        pcall(ffiutil.terminateSubProcess, dl.epub_build.pid)
    end
    dl.dispatch_active = {}
    dl.epub_build = nil
end

function Downloader:recover()
    -- A SIGKILL/OOM cannot run the normal finally path. A fresh plugin process
    -- owns no active download, so it is safe to clear the persistent Kindle
    -- powerd flag and remove disk artifacts left by the previous process.
    StandbyGuard.recover()
    local ok, removed = pcall(Content.cleanup_stale_downloads, self.settings)
    if not ok then
        logger.warn("stale download recovery failed:", log_error(removed))
        return false
    end
    if tonumber(removed) and removed > 0 then
        logger.info("stale download artifacts removed:", tostring(removed))
    end
    return true
end

function Downloader:_cleanupWorkspace(dl)
    if not dl or not dl.workspace then return end
    local workspace = dl.workspace
    dl.workspace = nil
    if dl.state then dl.state.workspace = nil end
    Content.cleanup_download_workspace(workspace)
end

-- Keep the device awake during long book downloads (reference counted so
-- multiple concurrent jobs share a single guard).
function Downloader:_beginStandby()
    self._standby_ref = (self._standby_ref or 0) + 1
    if self._standby_ref == 1 then
        self._standby_token = StandbyGuard.acquire()
    end
end

function Downloader:_endStandby()
    local ref = self._standby_ref or 0
    if ref <= 0 then
        return
    end
    self._standby_ref = ref - 1
    if self._standby_ref == 0 then
        StandbyGuard.release(self._standby_token)
        self._standby_token = nil
    end
end

function Downloader:_releaseStandby(dl)
    if dl and dl.standby_guard then
        dl.standby_guard = nil
        self:_endStandby()
    end
end

function Downloader:_notifyCompletion(dl, ok, value)
    if not dl or dl.completion_notified then return end
    dl.completion_notified = true
    if type(dl.on_complete) ~= "function" then return end
    local called, err = pcall(dl.on_complete, ok == true, value)
    if not called then
        logger.warn("download completion callback failed:",
            log_error(err))
    end
end

function Downloader:_finishJob(dl)
    if self._active_job == dl then
        self._active_job = nil
    end
    local pending = self._pending_start
    if pending and not self._active_job then
        self._pending_start = nil
        local scheduled = { pending = pending }
        self._scheduled_start = scheduled
        UIManager:scheduleIn(0.1, function()
            if self._scheduled_start ~= scheduled then return end
            self._scheduled_start = nil
            self:start(pending.book, pending.chapters, pending.suffix, pending.options)
        end)
    end
end

function Downloader:_cancelScheduledPrefetch(reason)
    local scheduled = self._scheduled_start
    local pending = scheduled and scheduled.pending
    if not pending or not pending.options or not pending.options.prefetch then
        return false
    end
    self._scheduled_start = nil
    local book = pending.book or {}
    local chapter = pending.chapters and pending.chapters[1] or {}
    logger.info("scheduled prefetch cancelled:",
        "book_id=", tostring(book.book_id or book.bookId or ""),
        "chapter_uid=", tostring(chapter.chapterUid or chapter.chapterId or ""),
        "reason=", tostring(reason or "cancelled"))
    return true
end

function Downloader:getActivePrefetch()
    local job = self._active_job
    if job and job.prefetch and not job.cancelled then
        return job
    end
end

function Downloader:cancelPrefetch(reason)
    local cancelled_scheduled = self:_cancelScheduledPrefetch(reason)
    if self._pending_start and self._pending_start.options
        and self._pending_start.options.prefetch then
        local pending = self._pending_start
        local pending_book = pending.book or {}
        local pending_chapter = pending.chapters and pending.chapters[1] or {}
        logger.info("pending prefetch cancelled:",
            "book_id=", tostring(pending_book.book_id or pending_book.bookId or ""),
            "chapter_uid=", tostring(pending_chapter.chapterUid
                or pending_chapter.chapterId or ""),
            "reason=", tostring(reason or "cancelled"))
        self._pending_start = nil
    end
    local job = self:getActivePrefetch()
    if not job then return cancelled_scheduled end
    job.cancelled = true
    job.cancel_reason = reason or "cancelled"
    if job.worker_handle and self.background_worker then
        self.background_worker:cancel(job.worker_handle, job.cancel_reason)
    end
    local chapter = job.chapters and job.chapters[1] or {}
    logger.info("active prefetch cancelled:",
        "book_id=", tostring(job.book
            and (job.book.book_id or job.book.bookId) or ""),
        "chapter_uid=", tostring(chapter.chapterUid or chapter.chapterId or ""),
        "reason=", tostring(job.cancel_reason))
    if job.progress_dialog then
        job.progress_dialog:close()
        job.progress_dialog = nil
    end
    return true
end

function Downloader:isPrefetching(book, chapter)
    local job = self:getActivePrefetch()
    local target = job and job.chapters and job.chapters[1]
    local job_book_id = job and job.book and (job.book.book_id or job.book.bookId)
    local book_id = book and (book.book_id or book.bookId)
    local target_uid = target and (target.chapterUid or target.chapterId)
    local chapter_uid = chapter and (chapter.chapterUid or chapter.chapterId)
    return job ~= nil
        and tostring(job_book_id or "") == tostring(book_id or "")
        and tostring(target_uid or "") == tostring(chapter_uid or "")
end

function Downloader:promotePrefetch(book, chapter)
    local job = self:getActivePrefetch()
    local target = job and job.chapters and job.chapters[1]
    local job_book_id = job and job.book and (job.book.book_id or job.book.bookId)
    local book_id = book and (book.book_id or book.bookId)
    local target_uid = target and (target.chapterUid or target.chapterId)
    local chapter_uid = chapter and (chapter.chapterUid or chapter.chapterId)
    if tostring(job_book_id or "") ~= tostring(book_id or "")
        or tostring(target_uid or "") ~= tostring(chapter_uid or "") then
        return false
    end
    job.open_on_complete = true
    job.promoted = true
    self:_ensureProgressDialog(job)
    return true
end

function Downloader:isPromotedPrefetch(book, chapter)
    return self:isPrefetching(book, chapter)
        and self._active_job.promoted == true
end

function Downloader:_ensureProgressDialog(dl)
    if dl.progress_dialog then return dl.progress_dialog end
    local progress_dialog = DownloadDialog:new{
        title = dl.stage_title or T(_("Downloading: %1"), dl.book.title or ""),
        progress_max = dl.total,
        buttons = {{
            {
                text = _("Cancel download"),
                callback = function()
                    if dl.prefetch then
                        self:cancelPrefetch("cancelled")
                    else
                        dl.cancelled = true
                        dl.cancel_reason = dl.cancel_reason or "cancelled"
                    end
                    if dl.progress_dialog then
                        dl.progress_dialog:close()
                        dl.progress_dialog = nil
                    end
                end,
            },
        }},
    }
    dl.progress_dialog = progress_dialog
    progress_dialog:show()
    if dl.stage_progress then
        progress_dialog:reportProgress(dl.stage_progress)
    end
    self.refresh_ui()
    return progress_dialog
end

local function file_exists(path)
    if not path then return false end
    local handle = io.open(path, "rb")
    if not handle then return false end
    handle:close()
    return true
end

function Downloader:_prefetchStage(dl, state)
    local stage = state and state.stage
    local title
    if stage == "reader" then
        title = T(_("Preparing chapter %1/%2"), "1", "1")
    elseif stage == "source" then
        local attempt = tonumber(state.attempt) or 1
        if attempt > 1 then
            title = T(_("Retrying chapter %1/%2 · attempt %3"), "1", "1", tostring(attempt - 1))
        else
            local chapter = dl.chapters[1] or {}
            title = T(_("Downloading chapter %1/%2: %3"), "1", "1",
                chapter.title or tostring(chapter.chapterUid or ""))
        end
    elseif stage == "images" then
        title = T(_("Downloading images · chapter %1/%2"), "1", "1")
    elseif stage == "footnotes" then
        title = T(_("Processing footnotes · chapter %1/%2"), "1", "1")
    elseif stage == "epub" then
        title = _("Building EPUB...")
    else
        title = T(_("Processing chapter %1/%2"), "1", "1")
    end
    self:_setStage(dl, title, stage == "epub" and 1 or 0)
end

function Downloader:_applyPrefetchResult(dl, result)
    self:_releaseStandby(dl)
    dl.worker_handle = nil
    if dl.progress_dialog then
        dl.progress_dialog:close()
        dl.progress_dialog = nil
    end
    if self._active_job ~= dl then return end
    if dl.cancelled then
        self:_notifyCompletion(dl, false, dl.cancel_reason or "cancelled")
        self:_finishJob(dl)
        return
    end
    if type(result) ~= "table" or result.ok ~= true
        or type(result.value) ~= "table" or not file_exists(result.value.path) then
        local reason = type(result) == "table" and result.error or "worker_no_result"
        self:_notifyCompletion(dl, false, reason)
        self:_finishJob(dl)
        return
    end
    local value = result.value
    if value.auth and not WorkerSettings.merge(self.settings,
        dl.auth_fingerprint, value.auth) then
        logger.info("skip worker auth write-back: parent auth changed")
    end
    local book_id = tostring(dl.book.book_id or dl.book.bookId or "")
    local chapter = dl.chapters[1] or {}
    local uid = tostring(value.chapter_uid or chapter.chapterUid or chapter.chapterId or "1")
    local books = self.settings:get("books", {})
    local record = books[book_id] or books[tonumber(book_id)] or {}
    local function apply(target)
        target.cached_chapters = target.cached_chapters or {}
        target.cached_chapters[uid] = value.path
        target.cache_dir = value.cache_dir or target.cache_dir
        target.reader_url = target.reader_url or value.reader_url
        if value.annotation_document then
            target.annotation_documents = target.annotation_documents or {}
            target.annotation_documents[value.path] = value.annotation_document
        end
    end
    apply(dl.book)
    if record ~= dl.book then apply(record) end
    record.book_id = record.book_id or dl.book.book_id or dl.book.bookId
    books[book_id] = record
    self.settings:set("books", books)
    self.settings:flush()
    self.refresh_shelf()
    logger.info("prefetch worker completed:", "book_id=", book_id,
        "chapter_uid=", uid, "path=", value.path)
    self:_notifyCompletion(dl, true, value.path)
    self:_finishJob(dl)
    if dl.open_on_complete then self.open_file(value.path) end
end

function Downloader:_startPrefetchWorker(dl)
    local worker = self.background_worker
    if not worker or not worker:available() then
        self:_applyPrefetchResult(dl, { ok = false, error = "worker_unavailable" })
        return false
    end
    local ChapterWorker = require("weread.lib.chapter_prefetch_worker")
    local ok, handle = worker:start {
        queue = true,
        replace_active = true,
        timeout = 180,
        task = function(context)
            return ChapterWorker.run(self.settings, self.client, dl.book,
                dl.chapters[1], context)
        end,
        on_launch = function(pid, available_kb)
            if self._active_job ~= dl then return end
            self:_beginStandby()
            dl.standby_guard = true
            logger.info("prefetch worker started:", "pid=", tostring(pid),
                "available_kb=", tostring(available_kb or "unknown"))
        end,
        on_progress = function(state)
            if self._active_job == dl then self:_prefetchStage(dl, state) end
        end,
        on_done = function(result) self:_applyPrefetchResult(dl, result) end,
    }
    if ok then
        dl.worker_handle = handle
        return true
    end
    return false
end

-- Schedule any download step behind xpcall so an uncaught error always releases
-- the standby guard, closes the progress dialog, and reports the failure.
function Downloader:_scheduleGuarded(dl, step_fn, delay)
    UIManager:scheduleIn(delay or 0.1, function()
        local ok, err = xpcall(step_fn, debug.traceback)
        if not ok and dl.standby_guard then
            self:_releaseStandby(dl)
            self:_cleanupWorkspace(dl)
            if dl.progress_dialog then
                dl.progress_dialog:close()
                dl.progress_dialog = nil
            end
            logger.err("download step failed:", log_error(err))
            self:_notifyCompletion(dl, false, err)
            self:_finishJob(dl)
            if not dl.prefetch then
                self.show_info(T(_("Download failed:\n%1"), display_error(err)))
            end
        end
    end)
end

-- Public entry: start downloading the given chapters as one EPUB.
function Downloader:start(book, chapters, suffix, options)
    options = options or {}
    chapters = type(chapters) == "table" and chapters or {}
    if options.prefetch and self.is_connected and not self.is_connected() then
        if type(options.on_complete) == "function" then
            pcall(options.on_complete, false, "offline")
        end
        return false
    end
    if options.prefetch and self.settings.is_cookie_configured
        and not self.settings:is_cookie_configured() then
        if type(options.on_complete) == "function" then
            pcall(options.on_complete, false, "authentication_required")
        end
        return false
    end
    if not options.prefetch and not self.require_login(true, false) then
        if type(options.on_complete) == "function" then
            pcall(options.on_complete, false, "authentication_required")
        end
        return false
    end

    local scheduled = self._scheduled_start
    if scheduled then
        local scheduled_prefetch = scheduled.pending
            and scheduled.pending.options
            and scheduled.pending.options.prefetch == true
        if scheduled_prefetch then
            self:_cancelScheduledPrefetch(
                options.prefetch and "replaced" or "manual_download")
        else
            if not options.prefetch then
                self.show_transient(_("Another download is already in progress."), 1)
            end
            return false
        end
    end

    local active = self._active_job
    if active then
        if options.prefetch then
            if active.prefetch then
                self:cancelPrefetch("replaced")
                self._pending_start = {
                    book = book,
                    chapters = chapters,
                    suffix = suffix,
                    options = options,
                }
                return true
            end
            return false
        end
        if active.prefetch then
            self:cancelPrefetch("manual_download")
            self._pending_start = {
                book = book,
                chapters = chapters,
                suffix = suffix,
                options = options,
            }
            return true
        end
        self.show_transient(_("Another download is already in progress."), 1)
        return false
    end

    local total = #chapters
    local configured_cache = self.settings.get
        and self.settings:get("cache", {}) or {}
    local dl = {
        book = book,
        chapters = chapters,
        suffix = suffix or "book",
        index = 1,
        cancelled = false,
        selected = {},
        bodies = {},
        body_files = {},
        assets = {},
        assets_by_uid = {},
        state = {
            parallel_shards = Content.fetch_chapter_xhtml_parallel ~= nil,
        },
        total = total,
        failed = {},
        annotation_failed_batches = 0,
        footnote_scans = {},
        footnote_stats = {
            candidates = 0,
            converted = 0,
            image_notes = 0,
            backlinks = 0,
            removed_note_blocks = 0,
            unresolved = 0,
            fallback = 0,
        },
        single_chapter = options.single_chapter == true,
        separate_chapters = options.separate_chapters == true,
        include_annotations = options.include_annotations == true,
        open_on_complete = options.open_on_complete == true,
        offer_read = options.offer_read ~= false,
        silent_completion = options.silent_completion == true,
        prefetch = options.prefetch == true,
        resume_enabled = options.prefetch ~= true
            and options.resume ~= false
            and options.single_chapter ~= true
            and options.separate_chapters ~= true
            and (suffix or "book") == "full",
        chapter_dispatch_enabled = options.prefetch ~= true
            and options.chapter_dispatch ~= false
            and not options.include_annotations
            and options.single_chapter ~= true
            and options.separate_chapters ~= true
            and (suffix or "book") == "full"
            and ffiutil and ffiutil.runInSubProcess ~= nil,
        chapter_concurrency = math.min(4,
            math.max(1, math.floor(tonumber(options.chapter_concurrency)
                or tonumber(configured_cache.chapter_concurrency) or 2))),
        start_delay = tonumber(options.start_delay) or 0,
        on_start = options.on_start,
        on_complete = options.on_complete,
        started_at = time.now(),
        auth_fingerprint = WorkerSettings.fingerprint(self.settings),
    }
    self._active_job = dl

    local task_label = options.single_chapter and _("Download chapter and read") or _("Download full book")
    local task_runner = function(callback)
        return self.run_online_task(task_label, callback)
    end
    local function notifyStart()
        if dl.start_notified or type(dl.on_start) ~= "function" then return end
        dl.start_notified = true
        local called, start_err = pcall(dl.on_start)
        if not called then
            logger.warn("download start callback failed:", log_error(start_err))
        end
    end
    local function initializeDownload()
        if dl.cancelled then
            self:_notifyCompletion(dl, false, dl.cancel_reason or "cancelled")
            self:_finishJob(dl)
            return
        end
        local ok_init, err_init = pcall(function()
            Content.ensure_reader_state(self.client, book)
            dl.state.reader_state_ready = true
            local cache = self.settings.get
                and self.settings:get("cache", {}) or {}

            if dl.resume_enabled then
                dl.checkpoint_path = Checkpoint.path(self.settings, book)
                local restored, restore_err = Checkpoint.load(
                    self.client, dl.checkpoint_path,
                    book.book_id or book.bookId, "full")
                if restored and restored.workspace then
                    local workspace = tostring(restored.workspace)
                    dl.workspace = {
                        path = workspace,
                        incoming_dir = workspace .. "/incoming",
                        asset_dir = workspace .. "/images",
                    }
                    dl.checkpoint = restored
                    dl.checkpoint.completed = dl.checkpoint.completed or {}
                    dl.state.workspace = dl.workspace
                    dl.state.css = restored.css
                    logger.info("resuming full-book download:",
                        "completed=", tostring(#(dl.selected or {})))
                elseif restore_err ~= "missing" then
                    logger.warn("ignore invalid download checkpoint:",
                        log_error(restore_err))
                end
            end

            if not dl.workspace and (cache.download_book_images
                or dl.resume_enabled) and Content.create_download_workspace then
                dl.workspace = Content.create_download_workspace(
                    self.settings, book)
                dl.state.workspace = dl.workspace
            end
            if dl.resume_enabled and not dl.checkpoint then
                dl.checkpoint = {
                    version = 1,
                    book_id = book.book_id or book.bookId,
                    suffix = "full",
                    workspace = dl.workspace and dl.workspace.path,
                    completed = {},
                    css = dl.state.css,
                }
                self:_saveCheckpoint(dl)
            end
        end)
        if not ok_init then
            logger.err("initialize book download failed:", log_error(err_init))
            self:_cleanupWorkspace(dl)
            if dl.progress_dialog then
                dl.progress_dialog:close()
                dl.progress_dialog = nil
            end
            if type(options.on_complete) == "function" then
                pcall(options.on_complete, false, err_init)
            end
            dl.completion_notified = true
            self:_finishJob(dl)
            if not dl.prefetch then
                self.show_info(T(_("Download failed:\n%1"), display_error(err_init)))
            end
            return
        end

        self:_beginStandby()
        dl.standby_guard = true
        notifyStart()

        if not dl.prefetch then self:_ensureProgressDialog(dl) end

        self:_scheduleGuarded(dl, function() self:_step(dl) end)
    end
    if dl.prefetch then
        notifyStart()
        UIManager:scheduleIn(math.max(0.1, dl.start_delay), function()
            if self._active_job ~= dl then return end
            if dl.cancelled then
                self:_notifyCompletion(dl, false, dl.cancel_reason or "cancelled")
                self:_finishJob(dl)
                return
            end
            self:_startPrefetchWorker(dl)
        end)
        return true
    end
    local started = task_runner(initializeDownload)
    if started == false then
        self:_notifyCompletion(dl, false, "offline")
        self:_finishJob(dl)
    end
    return started ~= false
end

function Downloader:_setStage(dl, title, progress)
    dl.stage_title = title
    dl.stage_progress = progress
    if not dl.progress_dialog then return end
    dl.progress_dialog:setTitle(title)
    if progress then
        dl.progress_dialog:reportProgress(progress)
    end
end

function Downloader:_perf(dl, stage, started, ...)
    local elapsed = tonumber(time.now() - started) / 1000
    logger.info("download_perf", "stage=", stage,
        "ms=", string.format("%.1f", elapsed),
        "chapter=", tostring(dl.index) .. "/" .. tostring(dl.total), ...)
end

function Downloader:_failChapter(dl, err)
    local chapter = dl.chapters[dl.index]
    local uid = tostring(chapter and chapter.chapterUid or dl.index)
    table.insert(dl.failed, uid)
    if dl.footnote_scans then
        dl.footnote_scans[uid] = nil
    end
    logger.warn("chapter download failed:",
        "index=", tostring(dl.index) .. "/" .. tostring(dl.total),
        "chapter_uid=", uid, "error=", log_error(err))
    dl.current = nil
    dl.annotation = nil
    dl.index = dl.index + 1
    if dl.progress_dialog then
        dl.progress_dialog:reportProgress(dl.index - 1)
    end
    self:_scheduleGuarded(dl, function() self:_step(dl) end)
end

function Downloader:_retryChapterSource(dl, err)
    local chapter = dl.chapters[dl.index]
    local uid = tostring(chapter and chapter.chapterUid or dl.index)
    dl.chapter_source_retries = dl.chapter_source_retries or {}
    local attempt = (dl.chapter_source_retries[uid] or 0) + 1
    dl.chapter_source_retries[uid] = attempt
    if attempt > 2 then
        dl.chapter_source_retries[uid] = nil
        self:_failChapter(dl, err)
        return false
    end
    logger.warn("chapter source download failed; retrying:",
        "index=", tostring(dl.index) .. "/" .. tostring(dl.total),
        "chapter_uid=", uid, "attempt=", tostring(attempt),
        "error=", log_error(err))
    self:_setStage(dl,
        T(_("Retrying chapter %1/%2 · attempt %3"),
            tostring(dl.index), tostring(dl.total), tostring(attempt)),
        dl.index - 1)
    self:_scheduleGuarded(dl, function() self:_step(dl) end, 0.8 * attempt)
    return true
end

local function add_footnote_stats(total, current)
    for _i, key in ipairs({
        "candidates", "converted", "image_notes", "backlinks",
        "removed_note_blocks", "unresolved",
    }) do
        total[key] = (tonumber(total[key]) or 0) + (tonumber(current and current[key]) or 0)
    end
end

function Downloader:_footnoteStep(dl)
    if dl.cancelled then
        self:_releaseStandby(dl)
        self:_cleanupWorkspace(dl)
        self:_notifyCompletion(dl, false, dl.cancel_reason or "cancelled")
        self:_finishJob(dl)
        if not dl.prefetch then
            self.show_transient(_("Download cancelled"), 2)
        end
        return
    end
    local job = dl.footnote_job
    if not job then
        dl.footnotes_done = true
        self:_scheduleGuarded(dl, function() self:_step(dl) end)
        return
    end
    if job.index > #dl.selected then
        dl.footnotes_done = true
        dl.footnote_job = nil
        if job.css_needed then
            dl.state.css = (dl.state.css or "") .. "\n"
                .. Footnotes.get_css(job.use_popup)
        end
        self:_saveCheckpoint(dl)
        logger.info("book footnotes processed:",
            "candidates=", tostring(dl.footnote_stats.candidates),
            "converted=", tostring(dl.footnote_stats.converted),
            "images=", tostring(dl.footnote_stats.image_notes),
            "backlinks=", tostring(dl.footnote_stats.backlinks),
            "removed_note_blocks=", tostring(dl.footnote_stats.removed_note_blocks),
            "unresolved=", tostring(dl.footnote_stats.unresolved),
            "fallback=", tostring(dl.footnote_stats.fallback))
        self:_scheduleGuarded(dl, function() self:_step(dl) end)
        return
    end

    local chapter = dl.selected[job.index]
    local uid = tostring(chapter.chapterUid or job.index)
    self:_setStage(dl,
        T(_("Processing footnotes · chapter %1/%2"),
            tostring(job.index), tostring(#dl.selected)), dl.total)
    local original = dl.bodies[uid]
    if not original and dl.body_files then
        original = Checkpoint.read_chapter(dl.body_files[uid])
    end
    local started = time.now()
    local ok, transformed, stats = pcall(Footnotes.transform_chapter,
        original, dl.footnote_scans[uid], job.index_data)
    if ok then
        local valid, validation_error = Footnotes.validate(transformed)
        if valid then
            if dl.body_files and dl.body_files[uid] then
                local write_ok, write_err = Checkpoint.write_chapter(
                    dl.body_files[uid], transformed)
                if not write_ok then
                    ok = false
                    transformed = write_err
                end
            end
            if ok then
                if not (dl.body_files and dl.body_files[uid]) then
                    dl.bodies[uid] = transformed
                else
                    dl.bodies[uid] = nil
                end
                add_footnote_stats(dl.footnote_stats, stats)
                if Footnotes.has_converted(stats) then job.css_needed = true end
            end
        else
            dl.footnote_stats.fallback = dl.footnote_stats.fallback + 1
            logger.warn("footnote transform validation failed; keeping original chapter:",
                "chapter_uid=", uid, "error=", log_error(validation_error))
        end
    else
        dl.footnote_stats.fallback = dl.footnote_stats.fallback + 1
        logger.warn("footnote transform failed; keeping original chapter:",
            "chapter_uid=", uid, "error=", log_error(transformed))
    end
    self:_perf(dl, "footnotes", started, "chapter_uid=", uid,
        "ok=", tostring(ok), "fallback=", tostring(not ok))
    job.index = job.index + 1
    self:_scheduleGuarded(dl, function() self:_footnoteStep(dl) end)
end

function Downloader:_startFootnotes(dl)
    dl.footnote_scans = dl.footnote_scans or {}
    dl.footnote_stats = dl.footnote_stats or {
        candidates = 0,
        converted = 0,
        image_notes = 0,
        backlinks = 0,
        removed_note_blocks = 0,
        unresolved = 0,
        fallback = 0,
    }
    local scans = {}
    for chapter_index, chapter in ipairs(dl.selected or {}) do
        local uid = tostring(chapter.chapterUid or chapter_index)
        if dl.footnote_scans[uid] then
            scans[uid] = dl.footnote_scans[uid]
        end
    end
    local cache = self.settings and self.settings:get("cache") or {}
    dl.footnote_job = {
        index = 1,
        index_data = Footnotes.build_book_index(scans, dl.selected),
        css_needed = false,
        use_popup = cache.book_footnotes_in_popup == true,
    }
    self:_scheduleGuarded(dl, function() self:_footnoteStep(dl) end)
end

function Downloader:_finishChapter(dl)
    if dl.cancelled or not dl.current then return end
    local chapter = dl.current.chapter
    local cache = self.settings:get("cache")
    local stage_text
    if cache.download_book_images then
        stage_text = T(_("Downloading images · chapter %1/%2"), tostring(dl.index), tostring(dl.total))
    else
        stage_text = T(_("Processing chapter %1/%2"), tostring(dl.index), tostring(dl.total))
    end
    self:_setStage(dl,
        stage_text, dl.index - 0.1)
    local started = time.now()
    local ok, xhtml, chapter_assets = pcall(function()
        return Content.finalize_single_chapter_content(
            self.client, self.settings, dl.book, chapter, dl.current.xhtml, dl.state
        )
    end)
    self:_perf(dl, "images_and_finalize", started, "ok=", tostring(ok))
    if not ok then
        self:_failChapter(dl, xhtml)
        return
    end
    local uid = tostring(chapter.chapterUid or dl.index)
    dl.bodies[uid] = xhtml
    dl.assets_by_uid = dl.assets_by_uid or {}
    dl.assets_by_uid[uid] = chapter_assets or {}
    table.insert(dl.selected, chapter)
    for _i, asset in ipairs(chapter_assets or {}) do
        table.insert(dl.assets, asset)
        dl.asset_bytes = (dl.asset_bytes or 0) + (tonumber(asset.size) or 0)
    end
    self:_checkpointChapter(dl, chapter, xhtml, chapter_assets)
    logger.info("download assets staged:",
        "chapter=", tostring(dl.index) .. "/" .. tostring(dl.total),
        "chapter_assets=", tostring(#(chapter_assets or {})),
        "total_asset_bytes=", tostring(dl.asset_bytes or 0),
        "lua_kb=", string.format("%.1f", collectgarbage("count")))
    dl.current = nil
    dl.annotation = nil
    dl.index = dl.index + 1
    if dl.progress_dialog then
        dl.progress_dialog:reportProgress(dl.index - 1)
    end
    self:_scheduleGuarded(dl, function() self:_step(dl) end)
end

function Downloader:_applyAnnotations(dl)
    if dl.cancelled or not dl.current or not dl.annotation then return end
    local annotation = dl.annotation
    local chapter = dl.current.chapter
    local book_id = dl.book.book_id or dl.book.bookId
    self:_setStage(dl,
        T(_("Processing underlines and thoughts · chapter %1/%2"), tostring(dl.index), tostring(dl.total)),
        dl.index - 0.15)
    local started = time.now()
    local ok, processed, annotation_css = pcall(function()
        return Thoughts.apply_data(self.settings, book_id, chapter.chapterUid,
            dl.current.xhtml, annotation.underlines, annotation.reviews, dl.book, {
            rebuild_thought_db = not dl.single_chapter and dl.index == 1,
        })
    end)
    self:_perf(dl, "apply_annotations", started, "ok=", tostring(ok),
        "reviews=", tostring(#annotation.reviews))
    if not ok then
        self:_failChapter(dl, processed)
        return
    end
    dl.current.xhtml = processed
    dl.state.annotation_css_seen = dl.state.annotation_css_seen or {}
    if annotation_css ~= "" and not dl.state.annotation_css_seen[annotation_css] then
        dl.state.css = Thoughts.merge_css(dl.state.css, annotation_css)
        dl.state.annotation_css_seen[annotation_css] = true
    end
    self:_finishChapter(dl)
end

function Downloader:_annotationBatch(dl)
    if dl.cancelled then
        self:_releaseStandby(dl)
        self:_cleanupWorkspace(dl)
        self:_notifyCompletion(dl, false, dl.cancel_reason or "cancelled")
        self:_finishJob(dl)
        if not dl.prefetch then
            self.show_transient(_("Download cancelled"), 2)
        end
        return
    end
    local annotation = dl.annotation
    if not annotation then
        self:_finishChapter(dl)
        return
    end
    if annotation.batch_index > #annotation.batches then
        self:_applyAnnotations(dl)
        return
    end

    local batch_index = annotation.batch_index
    local batch_total = #annotation.batches
    local fractional = dl.index - 0.85 + 0.7 * batch_index / math.max(1, batch_total)
    self:_setStage(dl,
        T(_("Downloading thoughts %1/%2 · chapter %3/%4"),
            tostring(batch_index), tostring(batch_total), tostring(dl.index), tostring(dl.total)),
        fractional)

    local started = time.now()
    local ok, result, err = self.client:get_chapter_reviews_batch(
        dl.book.book_id or dl.book.bookId,
        dl.current.chapter.chapterUid,
        annotation.batches[batch_index]
    )
    self:_perf(dl, "thought_batch", started,
        "batch=", tostring(batch_index) .. "/" .. tostring(batch_total),
        "ok=", tostring(ok), "retry=", tostring(annotation.retry))

    if not ok then
        if annotation.retry < 2 then
            annotation.retry = annotation.retry + 1
            self:_setStage(dl,
                T(_("Retrying thoughts %1/%2 · attempt %3"),
                    tostring(batch_index), tostring(batch_total), tostring(annotation.retry)),
                fractional)
            self:_scheduleGuarded(dl, function() self:_annotationBatch(dl) end, 0.6 * annotation.retry)
            return
        end
        dl.annotation_failed_batches = dl.annotation_failed_batches + 1
        logger.warn("thought batch skipped:",
            "batch=", tostring(batch_index) .. "/" .. tostring(batch_total),
            "error=", log_error(err or "unknown"))
    elseif result and type(result.reviews) == "table" then
        for _i, review in ipairs(result.reviews) do
            annotation.reviews[#annotation.reviews + 1] = review
        end
    end

    annotation.batch_index = batch_index + 1
    annotation.retry = 0
    self:_scheduleGuarded(dl, function() self:_annotationBatch(dl) end, 0.3)
end

function Downloader:_startAnnotations(dl)
    local chapter = dl.current.chapter
    local book_id = dl.book.book_id or dl.book.bookId
    self:_setStage(dl,
        T(_("Downloading underlines · chapter %1/%2"), tostring(dl.index), tostring(dl.total)),
        dl.index - 0.85)
    local started = time.now()
    local ok, underlines, ranges, err = Thoughts.fetch_underlines(
        self.client, self.settings, book_id, chapter.chapterUid, true
    )
    self:_perf(dl, "underlines", started, "ok=", tostring(ok),
        "ranges=", tostring(#(ranges or {})))
    if not ok or type(underlines) ~= "table" then
        logger.warn("skip chapter annotations:", log_error(err or "no data"))
        self:_finishChapter(dl)
        return
    end
    dl.annotation = {
        underlines = underlines,
        reviews = {},
        batches = self.client:build_chapter_review_batches(ranges),
        batch_index = 1,
        retry = 0,
    }
    if #dl.annotation.batches == 0 then
        self:_applyAnnotations(dl)
    else
        self:_scheduleGuarded(dl, function() self:_annotationBatch(dl) end, 0.1)
    end
end

function Downloader:_step(dl)
    if dl.cancelled then
        self:_stopDispatch(dl)
        if dl.checkpoint_path then Checkpoint.remove(dl.checkpoint_path) end
        self:_releaseStandby(dl)
        self:_cleanupWorkspace(dl)
        self:_notifyCompletion(dl, false, dl.cancel_reason or "cancelled")
        self:_finishJob(dl)
        if not dl.prefetch then
            self.show_transient(_("Download cancelled"), 2)
        end
        return
    end

    if dl.chapter_dispatch_enabled then
        return self:_dispatchStep(dl)
    end

    if dl.index > dl.total then
        if #dl.selected == 0 then
            if dl.progress_dialog then
                dl.progress_dialog:close()
                dl.progress_dialog = nil
            end
            self:_releaseStandby(dl)
            self:_cleanupWorkspace(dl)
            logger.err("book download failed: no chapters downloaded")
            self:_notifyCompletion(dl, false, "no_chapters_downloaded")
            self:_finishJob(dl)
            if not dl.prefetch then
                self.show_info(_("No chapters were downloaded."))
            end
            return
        end
        -- A full-book cache must be complete. Saving the chapters that happened
        -- to succeed under the stable `full.epub` path makes KOReader present a
        -- structurally valid but truncated book and replaces any previous good
        -- cache. Explicit single- or multi-chapter jobs remain best-effort.
        if dl.suffix == "full" and #dl.failed > 0 then
            if dl.progress_dialog then
                dl.progress_dialog:close()
                dl.progress_dialog = nil
            end
            self:_releaseStandby(dl)
            self:_cleanupWorkspace(dl)
            logger.warn(
                "full-book download aborted after chapter failures:",
                "success=", tostring(#dl.selected),
                "failed=", tostring(#dl.failed),
                "total=", tostring(dl.total)
            )
            self:_notifyCompletion(dl, false, "incomplete_full_book")
            self:_finishJob(dl)
            if not dl.prefetch then
                self.show_info(T(_(
                    "Full-book download stopped: %1 of %2 chapters failed.\n\nNo incomplete EPUB was saved. Please retry the download."
                ), tostring(#dl.failed), tostring(dl.total)))
            end
            return
        end
        if dl.footnote_scans and not dl.footnotes_done then
            self:_startFootnotes(dl)
            return
        end
        self:_setStage(dl, _("Building EPUB..."), dl.total)
        if dl.epub_build then
            return self:_pollEpubBuild(dl)
        end
        if self:_canBuildEpubInSubprocess(dl) and not dl.epub_build_result then
            self:_startEpubBuild(dl)
            return
        end
        local save_started = time.now()
        local ok, path, chapter_paths
        if dl.epub_build_result then
            local result = dl.epub_build_result
            dl.epub_build_result = nil
            save_started = result.started_at or save_started
            ok, path, chapter_paths = result.ok, result.path, nil
            if not ok then path = result.error or "EPUB build worker failed" end
        else
            ok, path, chapter_paths = pcall(function()
            if dl.single_chapter then
                local chapter = dl.selected[1]
                local uid = tostring(chapter.chapterUid or 1)
                return Content.save_chapter_epub(
                    self.settings, dl.book, chapter, dl.bodies[uid],
                    (dl.assets_by_uid and dl.assets_by_uid[uid]) or dl.assets,
                    dl.state.css
                )
            end
            if dl.separate_chapters then
                local paths = {}
                for chapter_index, chapter in ipairs(dl.selected) do
                    local uid = tostring(chapter.chapterUid or chapter_index)
                    paths[uid] = Content.save_chapter_epub(
                        self.settings, dl.book, chapter, dl.bodies[uid],
                        (dl.assets_by_uid and dl.assets_by_uid[uid]) or {},
                        dl.state.css
                    )
                end
                return paths[tostring(dl.selected[1].chapterUid or 1)], paths
            end
            local cover_data
            local cover_url = WeRead.normalize_cover_url(dl.book.cover)
            if cover_url and cover_url ~= "" then
                pcall(function() cover_data = self.client:get_binary(cover_url) end)
            end
            if dl.resume_enabled then
                return Content.save_book_epub_from_files(
                    self.settings, dl.book, dl.selected, dl.body_files,
                    dl.assets, dl.state.css, cover_data)
            end
            return Content.save_book_epub(
                self.settings, dl.book, dl.selected, dl.bodies,
                dl.suffix, dl.assets, dl.state.css, cover_data)
            end)
        end
        self:_perf(dl, "save_epub", save_started, "ok=", tostring(ok),
            "single=", tostring(dl.single_chapter))
        if ok or not dl.resume_enabled then
            self:_cleanupWorkspace(dl)
        end
        if dl.progress_dialog then
            dl.progress_dialog:close()
            dl.progress_dialog = nil
        end
        self:_releaseStandby(dl)
        local books = self.settings:get("books", {})
        local book_id = dl.book.book_id or dl.book.bookId
        if book_id then
            local record = books[book_id]
            if not record then
                record = {}
                for key, value in pairs(dl.book) do record[key] = value end
            end
            local function apply_cache_result(target)
                target.cached_chapters = target.cached_chapters or {}
                if not ok then return end
                if dl.single_chapter then
                    local chapter = dl.selected[1]
                    target.cached_chapters[tostring(chapter.chapterUid or 1)] = path
                elseif dl.separate_chapters then
                    for chapter_index, chapter in ipairs(dl.selected) do
                        local uid = tostring(chapter.chapterUid or chapter_index)
                        target.cached_chapters[uid] = chapter_paths[uid]
                    end
                else
                    local previous_full = target.cached_full_book
                        or target.cached_file
                    for uid, cached_path in pairs(target.cached_chapters) do
                        if cached_path == previous_full or cached_path == path then
                            target.cached_chapters[uid] = nil
                        end
                    end
                    target.cached_full_book = path
                    -- Keep cached_file as a compatibility alias for existing
                    -- installs and cache-management code. Single/partial
                    -- downloads must never overwrite it.
                    target.cached_file = path
                end
            end

            apply_cache_result(dl.book)
            if record ~= dl.book then apply_cache_result(record) end
            record.cache_dir = dl.book.cache_dir or record.cache_dir
            record.reader_url = record.reader_url
                or dl.book.reader_url or WeRead.reader_url(book_id)
            dl.book.reader_url = dl.book.reader_url or record.reader_url
            books[book_id] = record
            self.settings:set("books", books)
            self.settings:flush()
        end
        self.refresh_shelf()
        if not ok then
            logger.err("save downloaded book failed:", log_error(path))
            self:_notifyCompletion(dl, false, path)
            self:_finishJob(dl)
            if not dl.prefetch then
                self.show_info(T(_("Download failed:\n%1"), display_error(path)))
            end
            return
        end
        if dl.resume_enabled and dl.checkpoint_path then
            Checkpoint.remove(dl.checkpoint_path)
        end
        if #dl.failed > 0 then
            logger.warn(
                "book download completed with skipped chapters:",
                "success=", tostring(#dl.selected),
                "failed=", tostring(#dl.failed)
            )
        else
            logger.info("book download completed:", "chapters=", tostring(#dl.selected))
        end
        local completion_text
        if #dl.failed > 0 then
            completion_text = T(
                _("Downloaded %1 chapters; %2 failed.\n\nBook saved:\n%3\n\nRead now?"),
                tostring(#dl.selected), tostring(#dl.failed), path
            )
        else
            completion_text = T(_("Downloaded %1 chapters.\n\nBook saved:\n%2\n\nRead now?"), tostring(#dl.selected), path)
        end
        if dl.annotation_failed_batches > 0 then
            completion_text = completion_text .. "\n\n" .. T(
                _("%1 thought batch(es) failed after retries; the EPUB contains the remaining available thoughts."),
                tostring(dl.annotation_failed_batches)
            )
        end
        if dl.footnote_stats and dl.footnote_stats.unresolved > 0 then
            completion_text = completion_text .. "\n\n" .. T(
                _("%1 footnote reference(s) could not be resolved and were kept as original links."),
                tostring(dl.footnote_stats.unresolved)
            )
        end
        if dl.footnote_stats and dl.footnote_stats.fallback > 0 then
            completion_text = completion_text .. "\n\n" .. T(
                _("%1 chapter(s) kept their original footnote markup after validation fallback."),
                tostring(dl.footnote_stats.fallback)
            )
        end
        self:_perf(dl, "download_total", dl.started_at,
            "success_chapters=", tostring(#dl.selected),
            "failed_chapters=", tostring(#dl.failed),
            "failed_thought_batches=", tostring(dl.annotation_failed_batches),
            "footnotes_converted=", tostring(dl.footnote_stats and dl.footnote_stats.converted or 0),
            "footnotes_unresolved=", tostring(dl.footnote_stats and dl.footnote_stats.unresolved or 0))
        if dl.open_on_complete then
            self:_notifyCompletion(dl, true, path)
            self:_finishJob(dl)
            self.open_file(path)
            return
        end
        self:_notifyCompletion(dl, true, path)
        self:_finishJob(dl)
        if dl.silent_completion then
            return
        end
        if not dl.offer_read then
            self.show_transient(
                T(_("Downloaded %1 chapters."), tostring(#dl.selected)), 2)
            return
        end
        UIManager:show(ConfirmBox:new{
            text = completion_text,
            ok_text = _("Read now"),
            ok_callback = self.safe_callback(_("Read now"), function()
                self.open_file(path)
            end),
            cancel_text = _("Close"),
        })
        return
    end

    local chapter = dl.chapters[dl.index]
    if dl.resume_enabled and dl.checkpoint and dl.checkpoint.completed then
        local uid = tostring(chapter.chapterUid or dl.index)
        local entry = dl.checkpoint.completed[uid]
        if entry and self:_restoreCheckpointChapter(dl, chapter, entry) then
            self:_scheduleGuarded(dl, function() self:_step(dl) end)
            return
        end
    end
    self:_setStage(dl,
        T(_("Downloading chapter %1/%2: %3"), tostring(dl.index), tostring(dl.total),
            chapter.title or tostring(chapter.chapterUid)),
        dl.index - 1)
    local started = time.now()
    local ok, xhtml = pcall(function()
        return Content.fetch_single_chapter_source(
            self.client, self.settings, dl.book, chapter, dl.state
        )
    end)
    self:_perf(dl, "chapter_source", started, "ok=", tostring(ok))
    if not ok then
        self:_retryChapterSource(dl, xhtml)
        return
    end
    if dl.chapter_source_retries then
        dl.chapter_source_retries[tostring(chapter.chapterUid or dl.index)] = nil
    end
    local uid = tostring(chapter.chapterUid or dl.index)
    local scan_ok, scan = pcall(Footnotes.scan_chapter, xhtml, chapter)
    dl.footnote_scans = dl.footnote_scans or {}
    if scan_ok then
        dl.footnote_scans[uid] = scan
    else
        logger.warn("footnote scan failed; chapter will keep original footnote markup:",
            "chapter_uid=", uid, "error=", log_error(scan))
    end
    dl.current = { chapter = chapter, xhtml = xhtml }
    if dl.include_annotations then
        self:_startAnnotations(dl)
    else
        self:_finishChapter(dl)
    end
end

return Downloader
