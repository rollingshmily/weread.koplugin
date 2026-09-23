package.path = "./?.lua;" .. package.path

local PathIndex = require("weread.lib.path_index")
PathIndex.reset()

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local root = os.tmpname()
os.remove(root)
assert(os.execute("mkdir -p " .. root) == 0, "mkdir temp root")

local epub = root .. "/weread-book.epub"
local local_epub = root .. "/local.epub"
local epub_file = io.open(epub, "w")
epub_file:write("epub")
epub_file:close()
local local_file = io.open(local_epub, "w")
local_file:write("local")
local_file:close()

PathIndex.set(epub, "465030")
expect(PathIndex.read_marker(epub) == "465030",
    "download writes a sibling .weread marker")
expect(PathIndex.identify(epub) == "465030",
    "WeRead EPUB is identified from the sibling marker")
expect(PathIndex.identify(local_epub) == nil,
    "unmarked local EPUB is ignored")

PathIndex.reset()
expect(PathIndex.identify(epub) == "465030",
    "marker still identifies the book with an empty in-memory map")
expect(PathIndex.identify(local_epub) == nil,
    "local EPUB stays unmarked after reset")

os.remove(PathIndex.marker_path(epub))
PathIndex.reset()
PathIndex.loaded = true
PathIndex.map[root .. "/weread-book (tv).epub"] = "465030"
expect(PathIndex.identify(epub) == "465030",
    "same-folder normalized filenames still match WeRead books")
expect(PathIndex.identify(local_epub) == nil,
    "local EPUB does not match a different WeRead filename")

PathIndex.reset()
PathIndex.loaded = true
PathIndex.map[epub] = "465030"
expect(PathIndex.existing_file("465030") == epub,
    "existing_file returns a live EPUB path for the book id")

os.remove(PathIndex.marker_path(epub))
os.remove(epub)
os.remove(local_epub)
os.remove(root)

print(string.format("path_index_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
