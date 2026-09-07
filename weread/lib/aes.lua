-- AES-128-CBC with PKCS7 unpadding. LuaJIT bitops only.
local bit = require("bit")
local band, bxor = bit.band, bit.bxor
local lshift, rshift = bit.lshift, bit.rshift

local Aes = {}

local S = {
    99,124,119,123,242,107,111,197,48,1,103,43,254,215,171,118,
    202,130,201,125,250,89,71,240,173,212,162,175,156,164,114,192,
    183,253,147,38,54,63,247,204,52,165,229,241,113,216,49,21,
    4,199,35,195,24,150,5,154,7,18,128,226,235,39,178,117,
    9,131,44,26,27,110,90,160,82,59,214,179,41,227,47,132,
    83,209,0,237,32,252,177,91,106,203,190,57,74,76,88,207,
    208,239,170,251,67,77,51,133,69,249,2,127,80,60,159,168,
    81,163,64,143,146,157,56,245,188,182,218,33,16,255,243,210,
    205,12,19,236,95,151,68,23,196,167,126,61,100,93,25,115,
    96,129,79,220,34,42,144,136,70,238,184,20,222,94,11,219,
    224,50,58,10,73,6,36,92,194,211,172,98,145,149,228,121,
    231,200,55,109,141,213,78,169,108,86,244,234,101,122,174,8,
    186,120,37,46,28,166,180,198,232,221,116,31,75,189,139,138,
    112,62,181,102,72,3,246,14,97,53,87,185,134,193,29,158,
    225,248,152,17,105,217,142,148,155,30,135,233,206,85,40,223,
    140,161,137,13,191,230,66,104,65,153,45,15,176,84,187,22,
}

local IS = {}
for i = 0, 255 do
    IS[S[i + 1] + 1] = i
end

local RCON = { 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36 }

local function xtime(a)
    local hi = band(a, 0x80)
    a = band(lshift(a, 1), 0xff)
    if hi ~= 0 then
        a = bxor(a, 0x1b)
    end
    return a
end

local function gmul(a, b)
    local p = 0
    for _ = 1, 8 do
        if band(b, 1) ~= 0 then
            p = bxor(p, a)
        end
        a = xtime(a)
        b = rshift(b, 1)
    end
    return band(p, 0xff)
end

local function expand_key(key)
    local w = { key:byte(1, 16) }
    local i = 16
    local rcon_i = 1
    while #w < 176 do
        local t = { w[#w - 3], w[#w - 2], w[#w - 1], w[#w] }
        if i % 16 == 0 then
            local a, b, c, d = t[2], t[3], t[4], t[1]
            t[1] = bxor(S[a + 1], RCON[rcon_i])
            t[2] = S[b + 1]
            t[3] = S[c + 1]
            t[4] = S[d + 1]
            rcon_i = rcon_i + 1
        end
        for j = 1, 4 do
            w[#w + 1] = bxor(w[#w - 15], t[j])
        end
        i = i + 4
    end
    return w
end

local function add_round_key(s, rk, off)
    for i = 1, 16 do
        s[i] = bxor(s[i], rk[off + i])
    end
end

local function inv_sub(s)
    for i = 1, 16 do
        s[i] = IS[s[i] + 1]
    end
end

local function inv_shift(s)
    -- Column-major: index = col * 4 + row + 1
    local t
    t = s[14]; s[14] = s[10]; s[10] = s[6]; s[6] = s[2]; s[2] = t
    t = s[3]; s[3] = s[11]; s[11] = t
    t = s[7]; s[7] = s[15]; s[15] = t
    t = s[4]; s[4] = s[8]; s[8] = s[12]; s[12] = s[16]; s[16] = t
end

local function inv_mix(s)
    for c = 0, 3 do
        local i = c * 4
        local a, b, d, e = s[i + 1], s[i + 2], s[i + 3], s[i + 4]
        s[i + 1] = bxor(gmul(a, 14), gmul(b, 11), gmul(d, 13), gmul(e, 9))
        s[i + 2] = bxor(gmul(a, 9), gmul(b, 14), gmul(d, 11), gmul(e, 13))
        s[i + 3] = bxor(gmul(a, 13), gmul(b, 9), gmul(d, 14), gmul(e, 11))
        s[i + 4] = bxor(gmul(a, 11), gmul(b, 13), gmul(d, 9), gmul(e, 14))
    end
end

local function decrypt_block(block, rk)
    local s = { block:byte(1, 16) }
    add_round_key(s, rk, 160)
    for round = 9, 1, -1 do
        inv_shift(s)
        inv_sub(s)
        add_round_key(s, rk, round * 16)
        inv_mix(s)
    end
    inv_shift(s)
    inv_sub(s)
    add_round_key(s, rk, 0)
    return string.char(s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8],
        s[9], s[10], s[11], s[12], s[13], s[14], s[15], s[16])
end

function Aes.pkcs7_unpad(data)
    if type(data) ~= "string" or #data == 0 then
        return data
    end
    local n = data:byte(#data)
    if n < 1 or n > 16 or n > #data then
        return data
    end
    for i = #data - n + 1, #data do
        if data:byte(i) ~= n then
            return data
        end
    end
    return data:sub(1, #data - n)
end

function Aes.decrypt_cbc(ciphertext, key, iv)
    if type(ciphertext) ~= "string" or #ciphertext == 0 or #ciphertext % 16 ~= 0 then
        error("AES ciphertext must be a non-empty multiple of 16 bytes")
    end
    if #key ~= 16 or #iv ~= 16 then
        error("AES-128 key and IV must be 16 bytes")
    end
    local rk = expand_key(key)
    local prev = iv
    local out = {}
    for i = 1, #ciphertext, 16 do
        local block = ciphertext:sub(i, i + 15)
        local plain = decrypt_block(block, rk)
        local xored = {}
        for j = 1, 16 do
            xored[j] = bxor(plain:byte(j), prev:byte(j))
        end
        out[#out + 1] = string.char(xored[1], xored[2], xored[3], xored[4],
            xored[5], xored[6], xored[7], xored[8],
            xored[9], xored[10], xored[11], xored[12],
            xored[13], xored[14], xored[15], xored[16])
        prev = block
    end
    return Aes.pkcs7_unpad(table.concat(out))
end

return Aes
