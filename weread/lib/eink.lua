-- WeRead eink/native download helpers.
-- ZIP decrypt uses response header encryptKey + AES-128-CBC(vid||vid).
-- Existing web cookie/gateway paths stay untouched.

local Aes = require("weread.lib.aes")
local EpubPath = require("weread.lib.epub_path")
local bit = require("bit")
local ffi = require("ffi")

local band, bor, bxor = bit.band, bit.bor, bit.bxor
local lshift, rshift = bit.lshift, bit.rshift

local Eink = {}

Eink.APPVER = "2.1.2.10245900"
Eink.USER_AGENT = "WeRead/2.1.2 WRBrand/Onyx wr_eink Dalvik/2.1.0 (Linux; U; Android 11; BOOX Build/onyx)"

local CRC_TABLE = {}
do
    for i = 0, 255 do
        local crc = i
        for _ = 1, 8 do
            if band(crc, 1) ~= 0 then
                crc = bxor(rshift(crc, 1), 0xedb88320)
            else
                crc = rshift(crc, 1)
            end
        end
        CRC_TABLE[i] = band(crc, 0xffffffff)
    end
end

local function crc32_zip(crc, byte)
    crc = band(crc, 0xffffffff)
    local idx = band(bxor(crc, byte), 0xff)
    local shifted = math.floor((crc < 0 and crc + 4294967296 or crc) / 256)
    return band(bxor(CRC_TABLE[idx], shifted), 0xffffffff)
end

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64map = {}
for i = 1, #b64chars do
    b64map[b64chars:sub(i, i)] = i - 1
end
b64map["-"] = 62
b64map["_"] = 63

function Eink.base64_decode(data)
    if type(data) ~= "string" or data == "" then
        return ""
    end
    data = data:gsub("%s", "")
    local bytes = {}
    local buf, nbits = 0, 0
    for i = 1, #data do
        local ch = data:sub(i, i)
        if ch ~= "=" then
            local v = b64map[ch]
            if v then
                buf = bor(lshift(buf, 6), v)
                nbits = nbits + 6
                if nbits >= 8 then
                    nbits = nbits - 8
                    bytes[#bytes + 1] = string.char(band(rshift(buf, nbits), 0xff))
                end
            end
        end
    end
    return table.concat(bytes)
end

function Eink.vid_aes_key_iv(vid)
    vid = tostring(vid or "")
    if vid == "" then
        error("eink vid is empty")
    end
    local buf = vid
    while #buf < 32 do
        buf = buf .. vid
    end
    buf = buf:sub(1, 32)
    return buf:sub(1, 16), buf:sub(17, 32)
end

function Eink.decrypt_zip_password(encrypt_key_header, vid)
    local key, iv = Eink.vid_aes_key_iv(vid)
    local raw = Eink.base64_decode(encrypt_key_header or "")
    if #raw == 0 or #raw % 16 ~= 0 then
        error("invalid encryptKey header")
    end
    return Aes.decrypt_cbc(raw, key, iv)
end

function Eink.build_chapters_param(uids)
    local nums = {}
    for _, uid in ipairs(uids or {}) do
        local n = tonumber(uid)
        if n then
            nums[#nums + 1] = n
        end
    end
    table.sort(nums)
    if #nums == 0 then
        return ""
    end
    local parts = {}
    local start, prev = nums[1], nums[1]
    for i = 2, #nums do
        local n = nums[i]
        if n == prev + 1 then
            prev = n
        else
            if start == prev then
                parts[#parts + 1] = tostring(start)
            else
                parts[#parts + 1] = tostring(start) .. "-" .. tostring(prev)
            end
            start, prev = n, n
        end
    end
    if start == prev then
        parts[#parts + 1] = tostring(start)
    else
        parts[#parts + 1] = tostring(start) .. "-" .. tostring(prev)
    end
    return table.concat(parts, ",")
end

ffi.cdef[[
typedef struct z_stream_s {
  unsigned char *next_in;
  unsigned int avail_in;
  unsigned long total_in;
  unsigned char *next_out;
  unsigned int avail_out;
  unsigned long total_out;
  char *msg;
  void *state;
  void *zalloc;
  void *zfree;
  void *opaque;
  int data_type;
  unsigned long adler;
  unsigned long reserved;
} z_stream;
int inflateInit2_(z_stream *strm, int windowBits, const char *version, int stream_size);
int inflate(z_stream *strm, int flush);
int inflateEnd(z_stream *strm);
const char *zlibVersion();
]]

local zlib
local function load_zlib()
    if zlib then
        return zlib
    end
    local ok, lib = pcall(ffi.load, "z")
    if not ok then
        ok, lib = pcall(ffi.load, "libs/libz.so.1")
    end
    if not ok then
        error("zlib is required for eink ZIP inflate")
    end
    zlib = lib
    return zlib
end

function Eink.inflate_raw(data, dest_len)
    dest_len = math.max(tonumber(dest_len) or (#data * 4), 64)
    local z = load_zlib()
    local strm = ffi.new("z_stream")
    local out = ffi.new("unsigned char[?]", dest_len)
    strm.next_in = ffi.cast("unsigned char *", data)
    strm.avail_in = #data
    strm.next_out = out
    strm.avail_out = dest_len
    local ver = ffi.string(z.zlibVersion())
    local rc = z.inflateInit2_(strm, -15, ver, ffi.sizeof("z_stream"))
    if rc ~= 0 then
        error("inflateInit2 failed: " .. tostring(rc))
    end
    rc = z.inflate(strm, 4)
    local n = tonumber(strm.total_out)
    z.inflateEnd(strm)
    if rc ~= 1 and rc ~= 0 then
        error("inflate failed: " .. tostring(rc))
    end
    return ffi.string(out, n)
end

local function u16(s, i)
    local a, b = s:byte(i, i + 1)
    return a + b * 256
end

local function u32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function to_u32(n)
    n = band(n, 0xffffffff)
    if n < 0 then
        n = n + 4294967296
    end
    return n
end

local function umul32(a, b)
    a = to_u32(a)
    b = to_u32(b)
    local a1, a0 = math.floor(a / 65536), a % 65536
    local b1, b0 = math.floor(b / 65536), b % 65536
    return (a0 * b0 + ((a0 * b1 + a1 * b0) % 65536) * 65536) % 4294967296
end

local function zipcrypto_new(password)
    local keys = { 0x12345678, 0x23456789, 0x34567890 }
    local function update(byte)
        keys[1] = crc32_zip(keys[1], byte)
        keys[2] = (to_u32(keys[2]) + band(to_u32(keys[1]), 0xff)) % 4294967296
        keys[2] = (umul32(keys[2], 134775813) + 1) % 4294967296
        keys[3] = crc32_zip(keys[3], math.floor(to_u32(keys[2]) / 16777216))
    end
    for i = 1, #password do
        update(password:byte(i))
    end
    local function decrypt(byte)
        local temp = bor(to_u32(keys[3]), 2)
        local k = math.floor(umul32(temp, bxor(temp, 1)) / 256) % 256
        local c = bxor(byte, k)
        update(c)
        return c
    end
    return decrypt
end

function Eink.unzip_encrypted(data, password)
    if type(data) ~= "string" or data:sub(1, 2) ~= "PK" then
        error("eink download is not a ZIP")
    end
    local files = {}
    local off = 1
    while off + 30 <= #data and data:sub(off, off + 3) == "PK\003\004" do
        local flags = u16(data, off + 6)
        local method = u16(data, off + 8)
        local comp = u32(data, off + 18)
        local uncomp = u32(data, off + 22)
        local namelen = u16(data, off + 26)
        local extralen = u16(data, off + 28)
        local name = data:sub(off + 30, off + 29 + namelen)
        local payload_off = off + 30 + namelen + extralen
        local payload = data:sub(payload_off, payload_off + comp - 1)
        if band(flags, 1) ~= 0 then
            local dec = zipcrypto_new(password)
            local out = {}
            for i = 1, #payload do
                out[i] = string.char(dec(payload:byte(i)))
            end
            payload = table.concat(out):sub(13)
        end
        local body = payload
        if method == 8 then
            body = Eink.inflate_raw(payload, uncomp)
        elseif method ~= 0 then
            error("unsupported ZIP method " .. tostring(method) .. " for " .. name)
        end
        files[name] = body
        off = payload_off + comp
    end
    if not next(files) then
        error("eink ZIP contained no files")
    end
    return files
end

local function basename(path)
    return tostring(path or ""):match("([^/]+)$") or path
end

function Eink.is_tar(data)
    if type(data) ~= "string" or #data < 512 then
        return false
    end
    if data:sub(258, 262) == "ustar" then
        return true
    end
    local name = data:sub(1, 100):match("^[%w%._/%-]+")
    local mode = data:sub(101, 107)
    return name ~= nil and mode:match("^0+%d+$") ~= nil
end

local function tar_octal(s)
    s = tostring(s or ""):gsub("%z", ""):gsub(" ", "")
    if s == "" then
        return 0
    end
    return tonumber(s, 8) or 0
end

function Eink.untar(data)
    if not Eink.is_tar(data) then
        error("eink download is not a tar archive")
    end
    local files = {}
    local off = 1
    while off + 511 <= #data do
        local block = data:sub(off, off + 511)
        if block == string.rep("\0", 512) then
            break
        end
        local name = block:sub(1, 100):gsub("%z.*", "")
        local size = tar_octal(block:sub(125, 136))
        local typeflag = block:sub(157, 157)
        local prefix = block:sub(346, 500):gsub("%z.*", "")
        if prefix ~= "" then
            if name == "" then
                name = prefix
            else
                name = prefix .. "/" .. name
            end
        end
        off = off + 512
        local payload = ""
        if size > 0 then
            payload = data:sub(off, off + size - 1)
            local padded = math.floor((size + 511) / 512) * 512
            off = off + padded
        end
        -- Regular files: POSIX '0'/NUL, historic tar space.
        if name ~= "" and (typeflag == "" or typeflag == "0"
            or typeflag == "\0" or typeflag == " ") then
            files[name] = payload
        end
    end
    if not next(files) then
        error("eink tar contained no files")
    end
    return files
end

local function tar_header_fields(block)
    local name = block:sub(1, 100):gsub("%z.*", "")
    local size = tar_octal(block:sub(125, 136))
    local typeflag = block:sub(157, 157)
    local prefix = block:sub(346, 500):gsub("%z.*", "")
    if prefix ~= "" then
        if name == "" then
            name = prefix
        else
            name = prefix .. "/" .. name
        end
    end
    local regular = name ~= "" and (typeflag == "" or typeflag == "0"
        or typeflag == "\0" or typeflag == " ")
    return name, size, regular
end

function Eink.read_file(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local handle = io.open(path, "rb")
    if not handle then
        return nil
    end
    local data = handle:read("*a")
    handle:close()
    return data
end

function Eink.untar_file(path, out_dir)
    local handle = io.open(path, "rb")
    if not handle then
        error("could not open eink tar: " .. tostring(path))
    end
    local names = {}
    local zero = string.rep("\0", 512)
    while true do
        local block = handle:read(512)
        if not block or #block < 512 or block == zero then
            break
        end
        local name, size, regular = tar_header_fields(block)
        local base = basename(name)
        if regular and base ~= "" and base ~= "." and base ~= ".." then
            local out_path = out_dir .. "/" .. base
            local out = io.open(out_path, "wb")
            if not out then
                handle:close()
                error("could not write " .. out_path)
            end
            local remaining = size
            while remaining > 0 do
                local chunk = handle:read(math.min(remaining, 65536))
                if not chunk or chunk == "" then
                    break
                end
                out:write(chunk)
                remaining = remaining - #chunk
            end
            out:close()
            names[#names + 1] = base
            local pad = (512 - (size % 512)) % 512
            if pad > 0 then
                handle:read(pad)
            end
        elseif size > 0 then
            local padded = math.floor((size + 511) / 512) * 512
            local left = padded
            while left > 0 do
                local skip = handle:read(math.min(left, 65536))
                if not skip or skip == "" then
                    break
                end
                left = left - #skip
            end
        end
    end
    handle:close()
    if #names == 0 then
        error("eink tar contained no files")
    end
    return names
end

local function looks_like_html(body)
    if type(body) ~= "string" or body == "" then
        return false
    end
    local head = body:sub(1, 256):lower()
    return head:find("<html", 1, true) ~= nil
        or head:find("<?xml", 1, true) ~= nil
        or head:find("<!doctype html", 1, true) ~= nil
end

local function is_meta_name(name)
    local base = basename(tostring(name or "")):lower()
    return base == "info.txt" or base == "mimetype" or base == "container.xml"
        or base == "content.opf" or base == "toc.ncx"
end

local function is_image_name(name)
    local lower = tostring(name or ""):lower()
    return lower:match("%.png$") or lower:match("%.jpe?g$") or lower:match("%.gif$")
        or lower:match("%.webp$") or lower:match("%.svg$")
end

function Eink.txt_to_xhtml(text)
    text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    if text:sub(1, 3) == "\239\187\191" then
        text = text:sub(4)
    end
    local parts = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = EpubPath.strip_paragraph_indent(line)
        if line ~= "" then
            local amp = "&" .. "amp;"
            local lt = "&" .. "lt;"
            local gt = "&" .. "gt;"
            parts[#parts + 1] = "<p>" .. line:gsub("&", amp):gsub("<", lt):gsub(">", gt) .. "</p>"
        end
    end
    return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        .. "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title></title></head>\n"
        .. "<body>\n" .. table.concat(parts, "\n") .. "\n</body></html>"
end

function Eink.payload_kind(body)
    if type(body) ~= "string" then
        return type(body)
    end
    if body == "" then
        return "empty"
    end
    local b1, b2 = body:byte(1, 2)
    if b1 == 0x50 and b2 == 0x4b then
        return "zip"
    end
    if b1 == 0x1f and b2 == 0x8b then
        return "gzip"
    end
    if b1 == 0x78 then
        return "zlib"
    end
    if body:find("\0", 1, true) then
        return "binary:" .. tostring(#body)
    end
    if body:match("^%s*{") then
        return "json"
    end
    if looks_like_html(body) then
        return "html:" .. tostring(#body)
    end
    return "text:" .. tostring(#body)
end

function Eink.to_chapter_xhtml(body)
    if type(body) ~= "string" or body == "" then
        return nil
    end
    if body:find("\0", 1, true) then
        local ok, plain = pcall(Eink.inflate_raw, body, math.max(#body * 8, 64))
        if ok and type(plain) == "string" and plain ~= "" and not plain:find("\0", 1, true) then
            body = plain
        else
            return nil
        end
    end
    if looks_like_html(body) then
        return body
    end
    if body:match("^%s*{") then
        return nil
    end
    return Eink.txt_to_xhtml(body)
end

local function lookup_file(files, name)
    if type(name) ~= "string" or name == "" or type(files) ~= "table" then
        return nil
    end
    local candidates = {
        name,
        "./" .. name,
        basename(name),
        "Text/" .. basename(name),
        "OEBPS/Text/" .. basename(name),
    }
    for _, candidate in ipairs(candidates) do
        if files[candidate] then
            return files[candidate], candidate
        end
    end
    return nil
end

local function uid_from_name(name)
    local base = basename(tostring(name or ""))
    return base:match("^%d+_(%d+)_o$")
        or base:match("^(%d+)_o$")
        or base:match("_(%d+)_o$")
        or (base:match("^%d+$") and base)
        or base:gsub("%.[^.]+$", ""):match("^%d+$")
end

local function is_chapter_payload_name(name)
    if is_meta_name(name) or is_image_name(name) then
        return false
    end
    local lower = tostring(name or ""):lower()
    if lower:match("%.xhtml$") or lower:match("%.html$") or lower:match("%.txt$") then
        return true
    end
    local base = basename(name)
    return base:match("_o$") ~= nil or base:match("^%d+$") ~= nil
end

local function lookup_uid(files, uid)
    uid = tostring(uid or "")
    local names = {
        uid,
        uid .. ".txt",
        uid .. ".xhtml",
        uid .. ".html",
        uid .. "_o",
        "Text/" .. uid,
        "Text/" .. uid .. ".txt",
        "Text/" .. uid .. ".xhtml",
        "Text/" .. uid .. ".html",
        "OEBPS/Text/" .. uid .. ".xhtml",
        "OEBPS/Text/" .. uid .. ".html",
    }
    for _, name in ipairs(names) do
        local body, actual = lookup_file(files, name)
        if body then
            return body, actual
        end
    end
    for name, body in pairs(files) do
        if not is_meta_name(name) and not is_image_name(name) then
            if uid_from_name(name) == uid then
                return body, name
            end
        end
    end
    return nil
end

function Eink.build_uid_index(files)
    local index = {}
    for name in pairs(files or {}) do
        if not is_meta_name(name) and not is_image_name(name) then
            local uid = uid_from_name(name)
            if uid and not index[uid] then
                index[uid] = name
            end
        end
    end
    return index
end

function Eink.chapter_xhtml(files, chapter, uid_index)
    if type(files) ~= "table" or type(chapter) ~= "table" then
        return nil
    end
    local uid = tostring(chapter.chapterUid or "")
    local body, name
    for _, file in ipairs(chapter.files or {}) do
        body, name = lookup_file(files, file)
        if body then
            break
        end
    end
    if not body then
        uid_index = uid_index or Eink.build_uid_index(files)
        name = uid_index[uid]
        if name then
            body = files[name]
        end
    end
    if not body then
        body, name = lookup_uid(files, uid)
    end
    if not body then
        return nil
    end
    return Eink.to_chapter_xhtml(body), name
end

function Eink.chapter_xhtml_from_dir(dir, chapter, uid_index)
    if type(dir) ~= "string" or dir == "" or type(chapter) ~= "table" then
        return nil
    end
    local uid = tostring(chapter.chapterUid or "")
    local name = uid_index and uid_index[uid]
    if not name then
        for _, file in ipairs(chapter.files or {}) do
            local base = basename(file)
            if base ~= "" then
                name = base
                break
            end
        end
    end
    if not name then
        return nil
    end
    local body = Eink.read_file(dir .. "/" .. name)
    if not body then
        return nil
    end
    return Eink.to_chapter_xhtml(body), name
end

function Eink.sample_file_names(files, limit)
    limit = tonumber(limit) or 8
    local names = {}
    for name in pairs(files or {}) do
        names[#names + 1] = name
        if #names >= limit then
            break
        end
    end
    table.sort(names)
    return names
end

function Eink.files_to_chapter_bodies(files, chapters)
    local bodies = {}
    local assets = {}
    local src_map = {}
    local used = {}
    for name, data in pairs(files or {}) do
        if is_image_name(name) then
            local href = "images/" .. basename(name)
            src_map[basename(name)] = href
            assets[#assets + 1] = {
                href = href,
                data = data,
                media_type = name:lower():match("%.png$") and "image/png"
                    or name:lower():match("%.gif$") and "image/gif"
                    or name:lower():match("%.svg$") and "image/svg+xml"
                    or name:lower():match("%.webp$") and "image/webp"
                    or "image/jpeg",
            }
        end
    end
    local function rewrite(xhtml)
        if type(xhtml) ~= "string" then
            return xhtml
        end
        return xhtml:gsub("src=(['\"])(.-)%1", function(quote, src)
            local key = basename((src:match("^[^%?#]+") or src))
            local href = src_map[key]
            if href then
                return "src=" .. quote .. href .. quote
            end
            return "src=" .. quote .. src .. quote
        end)
    end
    local function take(name, body)
        if not body or used[name] then
            return nil
        end
        local xhtml = Eink.to_chapter_xhtml(body)
        if not xhtml then
            return nil
        end
        used[name] = true
        return rewrite(xhtml)
    end
    for index, chapter in ipairs(chapters or {}) do
        local uid = tostring(chapter.chapterUid or index)
        local xhtml
        for _, file in ipairs(chapter.files or {}) do
            local body, actual = lookup_file(files, file)
            xhtml = take(actual or file, body)
            if xhtml then
                break
            end
        end
        if not xhtml then
            local body, name = lookup_uid(files, uid)
            if name then
                xhtml = take(name, body)
            end
        end
        if not xhtml then
            for name, body in pairs(files) do
                if not used[name] and is_chapter_payload_name(name) then
                    xhtml = take(name, body)
                    if xhtml then
                        break
                    end
                end
            end
        end
        if xhtml then
            bodies[uid] = xhtml
        end
    end
    return bodies, assets
end

local function bookmark_has_range(item)
    return type(item) == "table" and item.range ~= nil and tostring(item.range) ~= ""
end

-- bestbookmarks may include an empty `updated` list plus the real marks in
-- `items` or `chapters[].bookmarks`. Empty tables are truthy, so callers must
-- not do `payload.updated or payload.items`.
function Eink.collect_bookmark_items(payload)
    local items, seen = {}, {}
    local function add_item(item)
        if not bookmark_has_range(item) then return end
        local key = tostring(item.chapterUid or "") .. ":" .. tostring(item.range)
        if seen[key] then return end
        seen[key] = true
        items[#items + 1] = item
    end
    local function add_list(list)
        if type(list) ~= "table" then return end
        for _, item in ipairs(list) do
            if bookmark_has_range(item) then
                add_item(item)
            elseif type(item) == "table" then
                add_list(item.bookmarks or item.items or item.marks or item.updated)
            end
        end
    end
    if type(payload) ~= "table" then return items end
    add_list(payload.items)
    add_list(payload.bookmarks)
    add_list(payload.marks)
    add_list(payload.chapters)
    add_list(payload.chapterBestBookmarks)
    if bookmark_has_range((payload.updated or {})[1]) then
        add_list(payload.updated)
    end
    return items
end

function Eink.underlines_for_chapter(bookmark_items, chapter_uid)
    local underlines = {}
    chapter_uid = tonumber(chapter_uid)
    for _, item in ipairs(bookmark_items or {}) do
        if tonumber(item.chapterUid) == chapter_uid then
            underlines[#underlines + 1] = {
                range = item.range,
                markText = item.markText,
                chapterUid = item.chapterUid,
                style = item.style,
                type = item.type,
                bookmarkId = item.bookmarkId,
            }
        end
    end
    return { chapterUid = chapter_uid, underlines = underlines }
end

return Eink
