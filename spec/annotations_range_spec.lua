package.path = "./?.lua;./?/init.lua;" .. package.path

package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end

local Annotations = require("weread.lib.annotations")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

expect(Annotations.rangeFromMarkText("<p>你好世界</p>", "你好世界") == "3-7",
    "plain paragraph maps to the same 0-index range injectUnderlines uses")
expect(Annotations.rangeFromMarkText("\xef\xbb\xbf<p>你好世界</p>", "你好世界") == "3-7",
    "leading BOM is stripped before indexing")
expect(Annotations.rangeFromMarkText("<p>你<span>好</span>世界</p>", "你好世界") == "3-20",
    "range spans tags between visible characters")
expect(Annotations.rangeFromMarkText("<p>啊啊</p>", "啊") == nil,
    "duplicate visible text refuses to guess")
expect(Annotations.rangeFromMarkText("<p>你好世界</p>", "不存在") == nil,
    "missing text returns nil")
expect(Annotations.rangeFromMarkText("<p>你好世界</p>", "") == nil,
    "empty markText returns nil")
expect(Annotations.rangeFromMarkText("", "你好") == nil,
    "empty html returns nil")

print(string.format("annotations_range_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
