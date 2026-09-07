package.path = "./?.lua;" .. package.path

local failures = 0
local function assert_eq(actual, expected, label)
    if actual ~= expected then
        failures = failures + 1
        io.stderr:write(string.format("FAIL %s: got %q expected %q\n", label, tostring(actual), tostring(expected)))
    end
end

local Aes = require("weread.lib.aes")
local Eink = require("weread.lib.eink")

-- AES-128-CBC NIST-style smoke: encrypt with known Python vector.
do
    local key = "0123456789abcdef"
    local iv = "fedcba9876543210"
    local ct = ""
    for byte in ("52d21baf7ad5501a944d0148111e8bb0"):gmatch("..") do
        ct = ct .. string.char(tonumber(byte, 16))
    end
    assert_eq(Aes.decrypt_cbc(ct, key, iv), "hello eink aes", "aes-cbc roundtrip")
end

assert_eq(Eink.build_chapters_param({ 6 }), "6", "single chapter")
assert_eq(Eink.build_chapters_param({ 1, 2, 3, 4, 5, 6 }), "1-6", "contiguous range")
assert_eq(Eink.build_chapters_param({ 1, 2, 3, 8, 10, 11, 12 }), "1-3,8,10-12", "mixed ranges")
assert_eq(Eink.build_chapters_param({ "12", 10, 11 }), "10-12", "sorts numeric uids")

local marks = {
    { chapterUid = 4, range = "1-2", markText = "a", type = 0 },
    { chapterUid = 4, range = "3-4", markText = "b", type = 1 },
    { chapterUid = 5, range = "9-10", markText = "c", type = 0 },
}
local chapter4 = Eink.underlines_for_chapter(marks, 4)
assert_eq(#chapter4.underlines, 2, "bookmarklist filtered to chapter")
assert_eq(#Eink.underlines_for_chapter(marks, 9).underlines, 0, "empty chapter")

if failures > 0 then
    os.exit(1)
end
print("eink_spec ok")
