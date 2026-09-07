-- Persistent state for resumable full-book downloads.
-- The manifest is deliberately kept outside settings/weread.lua: chapter
-- payloads and asset indexes can grow large and must survive plugin restarts.

local Checkpoint = {}

local function safe_component(value)
    value = tostring(value or ""):gsub("[^%w%._-]", "_")
    return value ~= "" and value or "weread"
end

local function parent_dir(path)
    return path and path:match("^(.*)/[^/]+$")
end

local function ensure_dir(path)
    if not path or path == "" then return end
    os.execute("mkdir -p " .. string.format("%q", path))
end

function Checkpoint.path(settings, book_or_id)
    local book_id = type(book_or_id) == "table"
        and (book_or_id.book_id or book_or_id.bookId)
        or book_or_id
    local root = settings and settings.meta_dir
    if type(root) ~= "string" or root == "" then
        root = settings and settings.data_dir or "."
    end
    return root .. "/" .. safe_component(book_id) .. "/download-state.json"
end

function Checkpoint.save(client, path, state)
    if type(client) ~= "table" or type(client.json_encode) ~= "function" then
        return false, "json encoder unavailable"
    end
    if type(path) ~= "string" or path == "" or type(state) ~= "table" then
        return false, "invalid checkpoint"
    end
    local ok, encoded = pcall(client.json_encode, client, state)
    if not ok or type(encoded) ~= "string" then
        return false, encoded or "checkpoint encoding failed"
    end
    ensure_dir(parent_dir(path))
    local tmp_path = path .. ".tmp"
    local file, err = io.open(tmp_path, "wb")
    if not file then return false, err end
    local write_ok, write_err = file:write(encoded)
    file:close()
    if not write_ok then
        os.remove(tmp_path)
        return false, write_err or "checkpoint write failed"
    end
    local renamed, rename_err = os.rename(tmp_path, path)
    if not renamed then
        os.remove(tmp_path)
        return false, rename_err or "checkpoint commit failed"
    end
    return true
end

function Checkpoint.chapter_path(workspace, chapter_uid)
    return tostring(workspace or ".") .. "/chapters/"
        .. safe_component(chapter_uid) .. ".xhtml"
end

function Checkpoint.write_chapter(path, content)
    if type(path) ~= "string" or path == "" or type(content) ~= "string" then
        return false, "invalid chapter payload"
    end
    ensure_dir(parent_dir(path))
    local tmp_path = path .. ".tmp"
    local file, err = io.open(tmp_path, "wb")
    if not file then return false, err end
    local write_ok, write_err = file:write(content)
    file:close()
    if not write_ok then
        os.remove(tmp_path)
        return false, write_err or "chapter payload write failed"
    end
    local renamed, rename_err = os.rename(tmp_path, path)
    if not renamed then
        os.remove(tmp_path)
        return false, rename_err or "chapter payload commit failed"
    end
    return true
end

function Checkpoint.read_chapter(path)
    if type(path) ~= "string" or path == "" then return nil end
    local file = io.open(path, "rb")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    return content
end

function Checkpoint.load(client, path, expected_book_id, expected_suffix)
    if type(path) ~= "string" or path == "" then
        return nil, "invalid_path"
    end
    local file = io.open(path, "rb")
    if not file then return nil, "missing" end
    local encoded = file:read("*a")
    file:close()
    if type(encoded) ~= "string" or encoded == "" then
        return nil, "empty"
    end
    if type(client) ~= "table" or type(client.json_decode) ~= "function" then
        return nil, "json decoder unavailable"
    end
    local ok, state = pcall(client.json_decode, client, encoded)
    if not ok or type(state) ~= "table" then
        return nil, "invalid_json"
    end
    if tonumber(state.version) ~= 1 then
        return nil, "unsupported_version"
    end
    if expected_book_id ~= nil
        and tostring(state.book_id or "") ~= tostring(expected_book_id) then
        return nil, "book_mismatch"
    end
    if expected_suffix ~= nil
        and tostring(state.suffix or "") ~= tostring(expected_suffix) then
        return nil, "suffix_mismatch"
    end
    return state
end

function Checkpoint.remove(path)
    if type(path) ~= "string" or path == "" then return false end
    os.remove(path .. ".tmp")
    return os.remove(path) ~= nil
end

return Checkpoint
