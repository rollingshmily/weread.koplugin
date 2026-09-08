local EpubPath = {}

local function basename(path)
    return (tostring(path):match("([^/\\]+)$")) or path
end

local function dirname(path)
    return tostring(path):match("^(.*)[/\\][^/\\]+$") or ""
end

function EpubPath.normalize_filename(name)
    name = tostring(name or ""):gsub("%.epub$", "")
    -- Fullwidth （...） and ASCII (...).
    name = name:gsub("\239\188\136.-\239\188\137", ""):gsub("%([^%)]-%)", "")
    return name:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

function EpubPath.is_same_renamed_epub(old_path, new_path)
    if type(old_path) ~= "string" or type(new_path) ~= "string" then
        return false
    end
    if old_path == new_path then return true end
    if dirname(old_path) ~= dirname(new_path) then return false end
    return EpubPath.normalize_filename(basename(old_path))
        == EpubPath.normalize_filename(basename(new_path))
end

return EpubPath
