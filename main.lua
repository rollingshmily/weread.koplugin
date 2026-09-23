local WidgetContainer = require("ui/widget/container/widgetcontainer")
local PathIndex = require("weread.lib.path_index")

local function read_plugin_version()
    local info = debug.getinfo(1, "S")
    local source = info and info.source or ""
    local dir = source:match("^@(.*/)[^/]+$")
    if dir then
        local file = io.open(dir .. "_meta.lua", "rb")
        if file then
            local body = file:read("*a") or ""
            file:close()
            local version = body:match('[Vv]ersion%s*=%s*"([^"]+)"')
                or body:match("[Vv]ersion%s*=%s*'([^']+)'")
            if version and version ~= "" then
                return version
            end
        end
    end
    return "0.5.0"
end

local WeReadPlugin = WidgetContainer:extend{
    name = "weread",
    is_doc_only = false,
    version = read_plugin_version(),
}

local function idle_reader(plugin)
    plugin._weread_idle_reader = true
    -- FileManager already mixed reader hooks onto the class. Swallow every
    -- event on this instance so onReadSettings cannot touch nil settings.
    plugin.handleEvent = function() end
end

local function clear_idle(plugin)
    plugin._weread_idle_reader = nil
    plugin.handleEvent = nil
end

local function boot(plugin)
    clear_idle(plugin)
    require("weread.plugin_runtime").boot(plugin)
end

function WeReadPlugin:init()
    local file = self.ui and self.ui.document and self.ui.document.file
    if type(file) == "string" and file ~= "" then
        if not PathIndex.identify(file) then
            idle_reader(self)
            return
        end
    end
    boot(self)
end

function WeReadPlugin:openBookshelf()
    if self._weread_idle_reader or not self.settings then
        boot(self)
    end
    return self:showBookshelf()
end

function WeReadPlugin:launch()
    return self:openBookshelf()
end

function WeReadPlugin:onZenUIReady()
    if self._weread_idle_reader or not self.settings then
        boot(self)
    end
    require("integrations.init").onZenUIReady(self)
    return true
end

return WeReadPlugin
