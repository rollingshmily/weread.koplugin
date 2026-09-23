-- Opening an unmarked local EPUB must not boot WeRead services.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then
        error(message or ("check " .. checks .. " failed"))
    end
end

package.preload["ui/widget/container/widgetcontainer"] = function()
    local base = {}
    function base:extend(fields)
        fields.__index = fields
        return setmetatable(fields, { __index = self })
    end
    return base
end

package.preload["datastorage"] = function()
    return {
        getSettingsDir = function() return "/tmp/weread-idle-spec" end,
        getFullDataDir = function() return "/tmp/weread-idle-spec" end,
    }
end

local PathIndex = require("weread.lib.path_index")
PathIndex.reset()

local Plugin = dofile("main.lua")
local plugin = setmetatable({
    ui = {
        document = { file = "/mnt/base-us/books/local.epub" },
        menu = {
            registerToMainMenu = function()
                error("idle reader must not register the WeRead menu")
            end,
        },
    },
}, { __index = Plugin })
plugin:init()

expect(plugin._weread_idle_reader == true, "unmarked book stays idle")
expect(plugin.settings == nil, "idle reader does not construct Settings")
expect(package.loaded["weread.plugin_runtime"] == nil,
    "idle reader does not load plugin_runtime")
expect(package.loaded["weread.lib.client"] == nil,
    "idle reader does not load the WeRead client")

print(("plugin_idle_reader_spec: %d checks"):format(checks))
