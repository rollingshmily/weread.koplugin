-- Unified overlay must not setStyleSheet after thought download.

package.path = "./?.lua;" .. package.path

package.preload["weread.lib.annotations"] = function() return {} end
package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.ui.download_dialog"] = function() return {} end
package.preload["ui/event"] = function()
    return { new = function() return {} end }
end
package.preload["weread.lib.logger"] = function()
    return { warn = function() end, info = function() end }
end
package.preload["weread.lib.thought_db"] = function() return {} end
package.preload["weread.ui.thought_popup"] = function()
    return { closeVisible = function() end }
end
package.preload["weread.ui.thought_popup.popup_config"] = function() return {} end
package.preload["ui/time"] = function() return { now = function() return 0 end } end
package.preload["ui/uimanager"] = function()
    return { setDirty = function() end, show = function() end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
        log_error = tostring,
        display_error = tostring,
        thought_perf = function() end,
        perf = function() end,
    }
end

local Controller = require("weread.ui.annotations_controller")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local styles = 0
local host = {
    settings = { get = function() return { show_annotations = true } end },
    ui = {
        document = {
            setStyleSheet = function() styles = styles + 1 end,
        },
        handleEvent = function() end,
        typeset = { css = "body{}" },
    },
    _xpointer_overlay = {
        setEnabled = function() end,
    },
    _usesUnifiedAnnotations = function() return true end,
    detectWeReadBook = function() return true end,
}
for key, value in pairs(Controller) do host[key] = value end

host:applyAnnotationVisibility()
expect(styles == 0, "unified overlay skip setStyleSheet after thought download")

print(string.format(
    "annotation_visibility_reflow_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
