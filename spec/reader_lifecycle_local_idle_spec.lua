-- Non-WeRead documents must not run progress sync, read report, overlay, or prefetch.

package.path = "./?.lua;" .. package.path

local scheduled = {}
local thought_db_opens = 0
local overlay_setups = 0
local overlay_teardowns = 0
local sync_ready = 0
local sync_close = 0
local report_ready = 0
local report_close = 0
local report_stops = {}
local releases = {}
local prefetches = 0
local unified_ready = 0
local thought_popup_cleanup = 0

package.preload["weread.lib.content"] = function()
    return {}
end
package.preload["weread.lib.logger"] = function()
    return { scoped = function() return {} end }
end
package.preload["weread.lib.protocol"] = function()
    return {}
end
package.preload["weread.ui.thought_popup"] = function()
    return {
        closeVisible = function() end,
        cleanup = function()
            thought_popup_cleanup = thought_popup_cleanup + 1
        end,
    }
end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback)
            scheduled[#scheduled + 1] = callback
        end,
    }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
        display_error = tostring,
        file_exists = function() return false end,
        log_error = tostring,
    }
end

local Lifecycle = require("weread.lib.reader_lifecycle")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local host = {
    ui = {
        document = { file = "/mnt/onboard/Documents/local.epub" },
        status = {},
    },
    settings = {
        get = function(_self, key)
            if key == "cache" then
                return { show_annotations = true }
            end
            return {}
        end,
    },
    progress_sync = {
        on_reader_ready = function()
            sync_ready = sync_ready + 1
        end,
        on_close_document = function()
            sync_close = sync_close + 1
        end,
        on_page_update = function()
            error("page update must not run for local books")
        end,
        on_resume = function()
            error("resume must not run for local books")
        end,
        release_document = function(_self, reason)
            releases[#releases + 1] = reason
        end,
    },
    read_report = {
        on_reader_ready = function()
            report_ready = report_ready + 1
        end,
        on_close_document = function()
            report_close = report_close + 1
        end,
        on_resume = function()
            error("read report resume must not run for local books")
        end,
        stop = function(_self, reason)
            report_stops[#report_stops + 1] = reason
        end,
    },
    detectWeReadBook = function() return nil end,
    _teardownThoughtInterception = function() end,
    _installReaderHighlightTapGuard = function() end,
    _setupThoughtInterception = function()
        error("thought interception must not install for local books")
    end,
    _setupXPointerOverlayPrototype = function()
        overlay_setups = overlay_setups + 1
    end,
    _teardownXPointerOverlayPrototype = function()
        overlay_teardowns = overlay_teardowns + 1
    end,
    maybePrefetchNextChapter = function()
        prefetches = prefetches + 1
    end,
    onUnifiedAnnotationsReady = function()
        unified_ready = unified_ready + 1
    end,
    _ensureThoughtDB = function()
        thought_db_opens = thought_db_opens + 1
    end,
    downloader = { cancelPrefetch = function() end },
    _removeReaderHighlightTapGuard = function() end,
}

for key, value in pairs(Lifecycle) do
    host[key] = value
end
host.detectWeReadBook = function() return nil end

host:onReaderReady()
while #scheduled > 0 do
    local callback = table.remove(scheduled, 1)
    callback()
end

expect(sync_ready == 0, "local open does not start progress sync")
expect(report_ready == 0, "local open does not start read report")
expect(overlay_setups == 0, "local open does not install annotation overlay")
expect(prefetches == 0, "local open does not prefetch WeRead chapters")
expect(unified_ready == 0, "local open does not run annotation ready")
expect(thought_db_opens == 0, "local open does not open thought DB")
expect(#releases == 1 and releases[1] == "not_weread",
    "local open abandons any leftover progress-sync session")
expect(#report_stops == 1 and report_stops[1] == "document_not_weread",
    "local open stops leftover read report")

host:onPageUpdate()
host:onResume()

host:onCloseDocument()
expect(sync_close == 0, "local close does not capture progress")
expect(report_close == 0, "local close does not run WeRead read-report close")
expect(overlay_teardowns == 0, "local close does not tear down unused overlay")
expect(thought_popup_cleanup == 0, "local close does not pool-clean thought popups")
expect(releases[#releases] == "document_closed",
    "local close still invalidates progress-sync generation")

print(string.format(
    "reader_lifecycle_local_idle_spec: %d checks, %d failure(s)",
    checks, failures))
os.exit(failures == 0 and 0 or 1)
