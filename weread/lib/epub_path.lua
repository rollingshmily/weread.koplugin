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

function EpubPath.strip_paragraph_indent(line)
    line = tostring(line or "")
    local i = 1
    while i <= #line do
        local b = line:byte(i)
        if b == 32 or b == 9 then
            i = i + 1
        elseif b == 0xC2 and line:byte(i + 1) == 0xA0 then
            i = i + 2
        elseif b == 0xE3 and line:byte(i + 1) == 0x80 and line:byte(i + 2) == 0x80 then
            i = i + 3
        else
            break
        end
    end
    line = line:sub(i)
    while #line > 0 do
        local last = line:byte(#line)
        if last == 32 or last == 9 then
            line = line:sub(1, -2)
        elseif #line >= 2 and line:byte(#line - 1) == 0xC2 and last == 0xA0 then
            line = line:sub(1, -3)
        elseif #line >= 3 and line:byte(#line - 2) == 0xE3
            and line:byte(#line - 1) == 0x80 and last == 0x80 then
            line = line:sub(1, -4)
        else
            break
        end
    end
    return line
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
