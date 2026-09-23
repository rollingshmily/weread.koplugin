-- Reverse path -> bookId map. Built in FileManager; Reader only dofiles this
-- tiny sidecar so local books never open weread.lua or the book table.

local M = {
    map = {},
    by_id = {},
    norm = nil,
    loaded = false,
}

local function index_file_path()
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok or not DataStorage or type(DataStorage.getSettingsDir) ~= "function" then
        return nil
    end
    return DataStorage:getSettingsDir() .. "/weread-path-index.lua"
end

local function dirname(path)
    return tostring(path):match("^(.*)[/\\][^/\\]+$") or ""
end

local function basename(path)
    return tostring(path):match("([^/\\]+)$") or path
end

local function norm_key(path)
    local EpubPath = require("weread.lib.epub_path")
    return dirname(path) .. "\0" .. EpubPath.normalize_filename(basename(path))
end

local function add_path(map, path, book_id)
    if type(path) ~= "string" or path == "" or not book_id then
        return
    end
    book_id = tostring(book_id)
    map[path] = book_id
    M.by_id[book_id] = path
    if M.norm then
        M.norm[norm_key(path)] = book_id
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
end

function M.rebuild(indexes)
    M.by_id = {}
    M.norm = nil
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
    if M.read_marker(file_path) == tostring(book_id) then
        return true
    end
    local source = io.open(file_path, "r")
    if not source then
        return false
    end
    source:close()
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

function M.existing_file(book_id)
    book_id = tostring(book_id or "")
    if book_id == "" then
        return nil
    end
    if not M.loaded then
        M.ensure_loaded()
    end
    local hinted = M.by_id[book_id] or nil
    if hinted then
        local file = io.open(hinted, "r")
        if file then
            file:close()
            return hinted
        end
    end
    for path, mapped in pairs(M.map) do
        if mapped == book_id then
            local file = io.open(path, "r")
            if file then
                file:close()
                M.by_id[book_id] = path
                return path
            end
        end
    end
    return nil
end

function M.adopt_markers(dir)
    if type(dir) ~= "string" or dir == "" then
        return 0
    end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs or type(lfs.dir) ~= "function" then
        return 0
    end
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then
        return 0
    end
    local adopted = 0
    for name in iter, dir_obj do
        local epub_name = type(name) == "string" and name:match("^(.*%.epub)%.weread$")
        if epub_name then
            local epub = dir:gsub("/+$", "") .. "/" .. epub_name
            local book_id = M.read_marker(epub)
            local file = book_id and io.open(epub, "r")
            if file then
                file:close()
                add_path(M.map, epub, book_id)
                adopted = adopted + 1
            end
        end
    end
    if adopted > 0 then
        M.loaded = true
        M.persist()
    end
    return adopted
end

function M.ensure_norm()
    if M.norm then
        return M.norm
    end
    local norm = {}
    for path, book_id in pairs(M.map) do
        norm[norm_key(path)] = book_id
    end
    M.norm = norm
    return norm
end

-- Reader open: sidecar, exact path, then O(1) normalized filename.
function M.identify(file_path)
    local marked = M.read_marker(file_path)
    if marked then
        return marked
    end
    if not M.loaded then
        M.ensure_loaded()
    end
    local hit = M.lookup(file_path)
    if hit then
        return hit
    end
    local book_id = M.ensure_norm()[norm_key(file_path)]
    if not book_id then
        return nil
    end
    M.set(file_path, book_id)
    M.persist()
    return book_id
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
        M.by_id = {}
        for file_path, book_id in pairs(map) do
            M.by_id[book_id] = file_path
        end
    else
        M.map = {}
        M.by_id = {}
    end
    M.norm = nil
    M.loaded = true
    return M.map
end

function M.reset()
    M.map = {}
    M.by_id = {}
    M.norm = nil
    M.loaded = false
end

return M
