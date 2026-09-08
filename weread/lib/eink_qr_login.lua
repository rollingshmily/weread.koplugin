-- WeRead eink native QR login.
-- Stores vid/accessToken in settings.eink and does not replace web cookies.

local Crypto = require("weread.lib.crypto")
local Device = require("device")
local Eink = require("weread.lib.eink")
local I18n = require("weread.lib.i18n")
local logger = require("weread.lib.logger").scoped("EinkQR")
local QRMessage = require("ui/widget/qrmessage")
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")
local WeRead = require("weread.lib.protocol")

local function _(text)
    return I18n.tr(text)
end

local WEREAD_BASE = "https://i.weread.qq.com"
local WX_APPID = "wxab9b71ad2b90ff34"
local WX_SCOPE = "snsapi_userinfo,snsapi_timeline,snsapi_friend"
local QRCONNECT_URL = "https://open.weixin.qq.com/connect/sdk/qrconnect"
local POLL_URL = "https://long.open.weixin.qq.com/connect/l/qrconnect"
local CONFIRM_URL = "https://open.weixin.qq.com/connect/confirm"

local EinkQRLogin = {}
EinkQRLogin.__index = EinkQRLogin

local function error_text(err)
    local text = tostring(err or "unknown error")
    text = text:match("^[^\r\n]+") or text
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

local function rand_digits(n)
    local out = {}
    for i = 1, n do
        out[i] = tostring(math.random(0, 9))
    end
    return table.concat(out)
end

local function new_device_id()
    return "eink334691225" .. rand_digits(19)
end

local function new_install_id()
    return "eink31" .. rand_digits(26)
end

local function now_ms()
    return os.time() * 1000
end

local function login_signature(timestamp_ms, device_id, random_value)
    return Crypto.sha256_hex(
        tostring(timestamp_ms) .. tostring(device_id) .. tostring(random_value)
    )
end

local function eink_headers()
    return {
        ["User-Agent"] = Eink.USER_AGENT,
        ["Accept"] = "*/*",
        ["appver"] = Eink.APPVER,
        ["basever"] = Eink.APPVER,
        ["baseapi"] = "30",
        ["osver"] = "11",
        ["channelId"] = "900",
    }
end

function EinkQRLogin:new(host, client, settings)
    return setmetatable({
        host = host,
        client = client,
        settings = settings,
        generation = 0,
        qr_dialog = nil,
        programmatic_close = false,
        started_at = nil,
        poll_last = nil,
        device_id = nil,
    }, self)
end

function EinkQRLogin:_request(url, opts, stage)
    opts = opts or {}
    opts.url = url
    opts.skip_cookie = true
    opts.persist_response_cookies = false
    local text, code, headers, status = self.client:request(opts)
    if not code then
        error(stage .. " failed: " .. tostring(status or headers or "request failed"))
    end
    if code < 200 or code >= 300 then
        error(stage .. " failed: HTTP " .. tostring(code))
    end
    return text, code, headers or {}
end

function EinkQRLogin:_request_json(url, opts, stage)
    local text = self:_request(url, opts, stage)
    local ok, parsed = pcall(self.client.json_decode, self.client, text)
    if not ok or type(parsed) ~= "table" then
        error(stage .. " returned invalid JSON")
    end
    return parsed
end

function EinkQRLogin:_begin_protocol()
    local ticket = self:_request_json(
        WEREAD_BASE .. "/wxticket?nonceStr=weread",
        {
            method = "GET",
            timeout = { 15, 25 },
            headers = eink_headers(),
            diagnostic_api = "/wxticket",
        },
        "eink ticket"
    )
    local sig = ticket.signature
    local timestamp = ticket.timeStamp or ticket.timestamp
    if type(sig) ~= "string" or sig == "" or timestamp == nil then
        error("eink ticket missing signature")
    end
    local query = {
        "appid=" .. WeRead.urlencode(WX_APPID),
        "noncestr=" .. WeRead.urlencode("weread"),
        "timestamp=" .. WeRead.urlencode(tostring(timestamp)),
        "scope=" .. WeRead.urlencode(WX_SCOPE),
        "signature=" .. WeRead.urlencode(sig),
    }
    local qr = self:_request_json(
        QRCONNECT_URL .. "?" .. table.concat(query, "&"),
        {
            method = "GET",
            timeout = { 15, 25 },
            headers = { ["User-Agent"] = Eink.USER_AGENT },
            diagnostic_api = "wx qrconnect",
        },
        "eink qrconnect"
    )
    local errcode = tonumber(qr.errcode) or -1
    local uuid = qr.uuid
    if errcode ~= 0 or type(uuid) ~= "string" or uuid == "" then
        error("eink QR create failed: " .. tostring(errcode))
    end
    return uuid, new_device_id()
end

function EinkQRLogin:_parse_poll(text)
    if type(text) ~= "string" or text == "" then
        return nil, nil
    end
    local ok, parsed = pcall(self.client.json_decode, self.client, text)
    if ok and type(parsed) == "table" then
        return tonumber(parsed.wx_errcode), tostring(parsed.wx_code or "")
    end
    local code = tonumber(text:match("wx_errcode%s*=%s*(%-?%d+)"))
    local wx_code = text:match("wx_code%s*=%s*'([^']*)'")
        or text:match('wx_code%s*=%s*"([^"]*)"')
        or ""
    return code, wx_code
end

function EinkQRLogin:_exchange(wx_code, device_id)
    local timestamp = now_ms()
    local random_value = math.random(0, 999)
    local body = {
        appFirstInstall = 1,
        code = wx_code,
        deviceId = device_id,
        deviceName = "BOOX",
        installId = new_install_id(),
        isAutoLogout = 0,
        isFromQrcode = 1,
        random = random_value,
        signature = login_signature(timestamp, device_id, random_value),
        timestamp = timestamp,
        trackId = "",
        deviceType = 3,
    }
    local headers = eink_headers()
    headers["Content-Type"] = "application/json; charset=UTF-8"
    local payload = self:_request_json(
        WEREAD_BASE .. "/login",
        {
            method = "POST",
            body = self.client:json_encode(body),
            timeout = { 15, 25 },
            headers = headers,
            diagnostic_api = "/login",
        },
        "eink login"
    )
    local access_token = tostring(payload.accessToken or "")
    local refresh_token = tostring(payload.refreshToken or "")
    local vid = tostring(payload.vid or "")
    if access_token == "" or refresh_token == "" or not vid:match("^%d+$") then
        error("eink login did not return credentials")
    end
    local user = type(payload.user) == "table" and payload.user or {}
    return {
        vid = vid,
        access_token = access_token,
        refresh_token = refresh_token,
        device_id = device_id,
        skey = tostring(payload.skey or ""),
        name = tostring(user.name or ""),
    }
end

function EinkQRLogin:_save(creds)
    -- Keep eink credentials out of the web cookie/account records.
    self.settings:update_auth({
        eink = {
            vid = creds.vid,
            access_token = creds.access_token,
            refresh_token = creds.refresh_token,
            device_id = creds.device_id,
            skey = creds.skey,
            name = creds.name or "",
            login_time = tostring(os.time()),
        },
    }, { replace_cookies = false })
    local eink = self.settings:get("eink", {}) or {}
    eink.auth_failed = nil
    self.settings:set("eink", eink)
    if self.client then self.client._eink_auth_failed = nil end
    if type(self.settings.flush) == "function" then self.settings:flush() end
end

function EinkQRLogin:_close_qr_dialog(programmatic)
    if not self.qr_dialog then
        return
    end
    self.programmatic_close = programmatic and true or false
    UIManager:close(self.qr_dialog)
    self.qr_dialog = nil
    self.programmatic_close = false
end

function EinkQRLogin:cancel()
    self.generation = self.generation + 1
    self.started_at = nil
    self.poll_last = nil
    self.device_id = nil
    self:_close_qr_dialog(true)
end

function EinkQRLogin:start()
    math.randomseed(os.time())
    if not self.host:isNetworkOnline() then
        self.host:showOffline(_("Eink QR login"))
        return
    end
    self:cancel()
    local generation = self.generation
    self.started_at = os.time()
    self.host:showBusy(_("Getting eink login QR code..."))
    self.host:runOnlineTask(_("Eink QR login"), function()
        local ok, result = pcall(function()
            local uuid, device_id = self:_begin_protocol()
            return { uuid = uuid, device_id = device_id }
        end)
        self.host:closeBusy()
        if generation ~= self.generation then
            return
        end
        if not ok then
            logger.err("eink QR begin failed:", error_text(result))
            self.host:showInfo(T(_("Eink QR login failed:\n%1"), error_text(result)))
            return
        end
        self.device_id = result.device_id
        self.poll_last = nil
        self:_show_qr(result.uuid, generation)
    end)
end

function EinkQRLogin:_show_qr(uuid, generation)
    local screen_width = Device.screen:getWidth()
    local screen_height = Device.screen:getHeight()
    local qr_size = math.floor(math.min(screen_width, screen_height) * 0.72)
    local dialog
    dialog = QRMessage:new{
        text = CONFIRM_URL .. "?uuid=" .. WeRead.urlencode(uuid),
        width = qr_size,
        height = qr_size,
        dismiss_callback = function()
            if self.qr_dialog == dialog then
                self.qr_dialog = nil
            end
            if not self.programmatic_close and generation == self.generation then
                self:cancel()
                self.host:showTransientInfo(_("Eink QR login cancelled."))
            end
        end,
        scale_factor = 0.9,
    }
    self.qr_dialog = dialog
    UIManager:show(dialog)
    self.host:refreshUI()
    self:_schedule_poll(uuid, generation)
end

function EinkQRLogin:_schedule_poll(uuid, generation)
    UIManager:scheduleIn(0.5, function()
        if generation == self.generation and self.qr_dialog then
            self:_poll(uuid, generation)
        end
    end)
end

function EinkQRLogin:_poll(uuid, generation)
    if generation ~= self.generation or not self.qr_dialog then
        return
    end
    local query = {
        "f=json",
        "uuid=" .. WeRead.urlencode(uuid),
    }
    if self.poll_last ~= nil then
        query[#query + 1] = "last=" .. WeRead.urlencode(tostring(self.poll_last))
    end
    local ok, text = pcall(function()
        local body, http_code = self.client:request({
            url = POLL_URL .. "?" .. table.concat(query, "&"),
            method = "GET",
            skip_cookie = true,
            persist_response_cookies = false,
            timeout = { 20, 25 },
            headers = { ["User-Agent"] = "Mozilla/5.0" },
            diagnostic_api = "wx poll",
        })
        if not http_code then
            error("poll request failed")
        end
        return body or ""
    end)
    if generation ~= self.generation or not self.qr_dialog then
        return
    end
    if not ok then
        self:_schedule_poll(uuid, generation)
        return
    end
    local wx_errcode, wx_code = self:_parse_poll(text)
    if wx_errcode then
        self.poll_last = wx_errcode
    end
    if wx_errcode == 405 and type(wx_code) == "string" and wx_code ~= "" then
        self.host:showBusy(_("Completing eink login..."))
        local ok_login, creds = pcall(self._exchange, self, wx_code, self.device_id)
        self.host:closeBusy()
        if generation ~= self.generation then
            return
        end
        if not ok_login then
            logger.err("eink login exchange failed:", error_text(creds))
            self:cancel()
            self.host:showInfo(T(_("Eink QR login failed:\n%1"), error_text(creds)))
            return
        end
        self:_save(creds)
        self:_close_qr_dialog(true)
        if self.host.refreshLoginMenu then
            self.host:refreshLoginMenu()
        end
        self.host:showTransientInfo(T(_("Eink logged in · %1"), creds.name ~= "" and creds.name or creds.vid), 3)
        return
    end
    if wx_errcode == 402 then
        self:cancel()
        self.host:showInfo(_("The eink QR code has expired. Please try again."))
        return
    end
    if wx_errcode == 403 then
        self:cancel()
        self.host:showInfo(_("Eink QR login was declined."))
        return
    end
    self:_schedule_poll(uuid, generation)
end

-- exported for specs
EinkQRLogin._login_signature = login_signature
EinkQRLogin._confirm_url = function(uuid)
    return CONFIRM_URL .. "?uuid=" .. WeRead.urlencode(uuid)
end

return EinkQRLogin
