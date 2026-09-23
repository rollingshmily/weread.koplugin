-- Reverse path -> bookId map. Built in FileManager; Reader only dofiles this
-- tiny sidecar so local books never open weread.lua or the book table.

local M = {
    map = {},
    loaded = false,
}

local function index_file_path()
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok or not DataStorage or type(DataStorage.getSettingsDir) ~= "function" then
        return nil
    end
    return DataStorage:getSettingsDir() .. "/weread-path-index.lua"
end

local function add_path(map, path, book_id)
    if type(path) == "string" and path ~= "" and book_id then
        map[path] = tostring(book_id)
    end
end

function M.ingest_index(map, book_id, index)
    if type(index) ~= "table" then
        return
    end
    add_path(map, index.cached_file, book_id)
    add_path(map, index.cached_full_book, book_id)
    if type(index.cached_chapters) == "table" then
        for _uid, chapter_path in pairs(index.cached_chapters) do
            add_path(map, chapter_path, book_id)
        end
    end
    M.write_marker(index.cached_file, book_id)
    M.write_marker(index.cached_full_book, book_id)
    if type(index.cached_chapters) == "table" then
        for _uid, chapter_path in pairs(index.cached_chapters) do
            M.write_marker(chapter_path, book_id)
        end
    end
end

function M.rebuild(indexes)
    local map = {}
    for book_id, index in pairs(indexes or {}) do
        M.ingest_index(map, book_id, index)
    end
    M.map = map
    M.loaded = true
    M.persist()
    return map
end

function M.marker_path(file_path)
    if type(file_path) ~= "string" or file_path == "" then
        return nil
    end
    return file_path .. ".weread"
end

function M.write_marker(file_path, book_id)
    local marker = M.marker_path(file_path)
    if not marker or not book_id then
        return false
    end
    local file = io.open(marker, "w")
    if not file then
        return false
    end
    file:write(tostring(book_id), "\n")
    file:close()
    return true
end

function M.read_marker(file_path)
    local marker = M.marker_path(file_path)
    if not marker then
        return nil
    end
    local file = io.open(marker, "r")
    if not file then
        return nil
    end
    local book_id = file:read("*l")
    file:close()
    if type(book_id) == "string" then
        book_id = book_id:match("^%s*(.-)%s*$")
    end
    if book_id == "" then
        return nil
    end
    return book_id
end

function M.set(path, book_id)
    if type(path) ~= "string" or path == "" or not book_id then
        return
    end
    M.map[path] = tostring(book_id)
    M.loaded = true
    M.write_marker(path, book_id)
end

function M.lookup(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    return M.map[path]
end

-- Reader open: sidecar next to the EPUB, then the in-memory/disk path map.
function M.identify(file_path)
    local marked = M.read_marker(file_path)
    if marked then
        return marked
    end
    if not M.loaded then
        M.ensure_loaded()
    end
    return M.lookup(file_path)
end

function M.persist()
    local path = index_file_path()
    if not path then
        return false
    end
    local chunks = { "return {\n" }
    for file_path, book_id in pairs(M.map) do
        chunks[#chunks + 1] = string.format("    [%q] = %q,\n", file_path, book_id)
    end
    chunks[#chunks + 1] = "}\n"
    local file, err = io.open(path, "w")
    if not file then
        return false, err
    end
    file:write(table.concat(chunks))
    file:close()
    return true
end

function M.ensure_loaded()
    if M.loaded then
        return M.map
    end
    local path = index_file_path()
    if not path then
        M.loaded = true
        return M.map
    end
    local ok, map = pcall(dofile, path)
    if ok and type(map) == "table" then
        M.map = map
    else
        M.map = {}
    end
    M.loaded = true
    return M.map
end

function M.reset()
    M.map = {}
    M.loaded = false
end

return M
