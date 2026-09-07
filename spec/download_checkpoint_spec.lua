package.path = "./?.lua;" .. package.path

local Checkpoint = require("weread.lib.download_checkpoint")

local root = os.tmpname()
os.remove(root)
os.execute("mkdir -p " .. string.format("%q", root))

local encoded_state
local client = {
    json_encode = function(_self, value)
        encoded_state = value
        return "checkpoint-payload"
    end,
    json_decode = function(_self, value)
        if value == "checkpoint-payload" then
            return encoded_state
        end
        error("unexpected payload")
    end,
}
local settings = { meta_dir = root }
local book = { book_id = "book/unsafe" }
local state = {
    version = 1,
    book_id = "book/unsafe",
    suffix = "full",
    workspace = root .. "/workspace",
    completed = {
        ["7"] = {
            uid = "7",
            source_path = root .. "/workspace/chapter-7.xhtml",
            assets = {},
        },
    },
}

local path = Checkpoint.path(settings, book)
assert(path:match("download%-state%.json$"), "checkpoint path was not stable")
assert(Checkpoint.save(client, path, state), "checkpoint save failed")
local chapter_path = Checkpoint.chapter_path(state.workspace, "7")
assert(Checkpoint.write_chapter(chapter_path, "<p>chapter seven</p>"),
    "chapter payload write failed")
assert(Checkpoint.read_chapter(chapter_path) == "<p>chapter seven</p>",
    "chapter payload was not restored")
local loaded, err = Checkpoint.load(client, path, "book/unsafe", "full")
assert(loaded and not err, "checkpoint load failed: " .. tostring(err))
assert(loaded.completed["7"].source_path == state.completed["7"].source_path,
    "completed chapter was not restored")

local bad, bad_err = Checkpoint.load(client, path, "other-book", "full")
assert(not bad and bad_err == "book_mismatch", "book mismatch was not rejected")

assert(Checkpoint.remove(path), "checkpoint remove failed")
local missing, missing_err = Checkpoint.load(client, path, "book/unsafe", "full")
assert(not missing and missing_err == "missing", "removed checkpoint was still readable")

os.execute("rm -rf " .. string.format("%q", root))
print("download_checkpoint_spec: passed")
