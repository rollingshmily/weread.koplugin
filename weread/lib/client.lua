local ltn12 = require("ltn12")
local logger = require("weread.lib.logger")
local socketutil = require("socketutil")
local http = require("socket.http")
local Cookie = require("weread.lib.cookie")
local WeRead = require("weread.lib.protocol")
local Eink = require("weread.lib.eink")

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local DEFAULT_TIMEOUT_SECONDS = 15
local Client = {}
Client.__index = Client

local function header_value(headers, name)
    if type(headers) ~= "table" or type(name) ~= "string" then return nil end
    if headers[name] ~= nil then return headers[name] end
    local target = name:lower()
    if headers[target] ~= nil then return headers[target] end
    for key, value in pairs(headers) do
        if type(key) == "string" and key:lower() == target then return value end
    end
    return nil
end

local function scalar_header_value(headers, name)
    local value = header_value(headers, name)
    if type(value) == "table" then
        if value[1] == nil then return nil end
        return tostring(value[1])
    end
    return value
end

local function http_error(client, code, text, headers)
    text = text or ""
    local content_type = tostring(header_value(headers, "content-type") or "unknown")
    local parts = {
        "HTTP " .. tostring(code),
        "content_type=" .. content_type,
        "body_bytes=" .. tostring(#text),
    }
    local looks_like_json = content_type:lower():find("json", 1, true)
        or text:match("^%s*{") ~= nil
        or text:match("^%s*%[") ~= nil
    if looks_like_json and #text <= 65536 then
        local ok, data = pcall(function()
            return client:json_decode(text)
        end)
        if ok and type(data) == "table" then
            local err_code = data.errCode or data.errcode or data.code
            local err_message = data.errMsg or data.errmsg or data.message or data.msg
            if err_code ~= nil then
                table.insert(parts, "error_code=" .. tostring(err_code))
            end
            if err_message ~= nil then
                local message = tostring(err_message):gsub("[%c]+", " "):sub(1, 200)
                table.insert(parts, "error_message=" .. message)
            end
        end
    end
    return table.concat(parts, ", ")
end

local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, item in pairs(value) do
        out[key] = deepcopy(item)
    end
    return out
end

local function table_summary(value)
    if type(value) ~= "table" then
        return type(value)
    end
    local count = 0
    for _key in pairs(value) do
        count = count + 1
    end
    return "table(" .. tostring(count) .. ")"
end

local function log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

local function log_response(label, context, text)
    context = context or {}
    text = text or ""
    logger.err(
        label,
        "method=", tostring(context.method or "unknown"),
        "url=", tostring(context.url or "unknown"),
        "api=", tostring(context.api_name or "unknown"),
        "status=", tostring(context.code or "unknown"),
        "content_type=", tostring(header_value(context.headers, "content-type") or "unknown"),
        "body_bytes=", tostring(#text),
        "response_body=", text
    )
end

local function merge_req_opts(default_opts, user_opts)
    default_opts = default_opts or {}
    if not user_opts then
        return deepcopy(default_opts)
    end
    local result = deepcopy(default_opts)
    for k, v in pairs(user_opts) do
        if k == "headers" and type(v) == "table" then
            result.headers = result.headers or {}
            for hk, hv in pairs(v) do
                local target = hk:lower()
                for existing_k, _ in pairs(result.headers) do
                    if type(existing_k) == "string" and existing_k:lower() == target then
                        result.headers[existing_k] = nil
                    end
                end
                result.headers[hk] = deepcopy(hv)
            end
        else
            result[k] = deepcopy(v)
        end
    end
    return result
end

local function is_weread_url(url)
    local authority = tostring(url or ""):match("^https?://([^/]+)")
    if not authority then
        return false
    end
    local host = authority:lower():gsub(":%d+$", "")
    return host == "weread.qq.com" or host:sub(-#".weread.qq.com") == ".weread.qq.com"
end

local function absolute_url(base_url, location)
    if type(location) ~= "string" or location == "" then
        return nil
    end
    if location:match("^https?://") then
        return location
    end
    local scheme, host = tostring(base_url or ""):match("^(https?)://([^/]+)")
    if not scheme then
        return location
    end
    if location:sub(1, 1) == "/" then
        return scheme .. "://" .. host .. location
    end
    local prefix = base_url:match("^(https?://.*/)") or (scheme .. "://" .. host .. "/")
    return prefix .. location
end

local function url_origin(url)
    local scheme, authority = tostring(url or ""):match("^(https?)://([^/]+)")
    if not scheme then
        return nil
    end
    return scheme:lower() .. "://" .. authority:lower()
end

local function clear_cross_origin_headers(headers)
    for key in pairs(headers or {}) do
        local name = tostring(key):lower()
        if name == "authorization" or name == "cookie" or name == "origin" then
            headers[key] = nil
        end
    end
end

function Client:new(settings)
    return setmetatable({
        settings = settings,
    }, self)
end

function Client:json_encode(data)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.encode then
        return json.encode(data)
    end
    return json:encode(data)
end

function Client:json_decode(text)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.decode then
        return json.decode(text)
    end
    return json:decode(text)
end

function Client:decode_http_json(text, context)
    local ok, data = pcall(self.json_decode, self, text)
    if not ok then
        log_response("HTTP JSON decode failed:", context, text)
        error(data, 0)
    end

    if type(data) == "table" then
        local err_code = data.errCode or data.errcode
        local failed_succ = data.succ ~= nil
            and data.succ ~= true
            and tonumber(data.succ) ~= 1
        if (err_code ~= nil and tonumber(err_code) ~= 0) or failed_succ then
            log_response("API response reported an error:", context, text)
        end
    end
    return data
end

function Client:request(opts)
    opts = opts or {}
    local body = opts.body
    local response
    local headers = {
        ["User-Agent"] = WeRead.USER_AGENT,
        ["Accept"] = "application/json, text/plain, */*"
    }
    local is_handle_cookie = not opts.skip_cookie and is_weread_url(opts.url)

    if is_handle_cookie then
        local cookies = self.settings:get("cookies", {})
        local cookie_header = Cookie.to_header(cookies)
        if cookie_header ~= "" then
            headers["Cookie"] = cookie_header
        end
    end

    if body then
        headers["Content-Length"] = tostring(#body)
    end
    local block_timeout = DEFAULT_TIMEOUT_SECONDS
    local total_timeout = -1
    if type(opts.timeout) == "table" and opts.timeout[1] then
        block_timeout = opts.timeout[1]
        total_timeout = opts.timeout[2] or block_timeout
    elseif type(opts.timeout) == "number" then
        block_timeout = opts.timeout
    end
    socketutil:set_timeout(block_timeout, total_timeout)

    local sink_to_use = opts.sink
    if not sink_to_use then
        response = {}
        sink_to_use = socketutil.table_sink(response)
    end

    local req_opts = merge_req_opts({
        method = body and "POST" or "GET",
        source = body and ltn12.source.string(body) or nil,
        sink = sink_to_use,
        headers = headers,
    }, opts)
    -- Redirects are handled explicitly by request_follow so credentials can be
    -- rebuilt for every destination instead of being copied across origins.
    req_opts.redirect = false
    local diagnostic_api = req_opts.diagnostic_api
    req_opts.diagnostic_api = nil
    local log_http_errors = req_opts.log_http_errors
    req_opts.log_http_errors = nil

    local results = { pcall(http.request, req_opts) }
    socketutil:reset_timeout()
    if not results[1] then
        logger.err(
            "HTTP transport failed:",
            "method=", tostring(req_opts.method),
            "url=", tostring(req_opts.url),
            "api=", tostring(diagnostic_api or "unknown"),
            "error=", tostring(results[2])
        )
        error(results[2])
    end
    local _, raw_code, resp_headers, status = results[2], results[3], results[4], results[5]
    if status == nil and type(raw_code) == "string" then
        status = raw_code
    end

    if not opts.sink then response = table.concat(response) end
    if is_handle_cookie and opts.persist_response_cookies ~= false then
        local set_cookie = header_value(resp_headers, "set-cookie")
        if set_cookie then
            self.settings:merge_set_cookie(set_cookie)
        end
    end

    local code = tonumber(raw_code)
    if code and code >= 400 and log_http_errors ~= false then
        log_response("HTTP response failed:", {
            method = req_opts.method,
            url = req_opts.url,
            api_name = diagnostic_api,
            code = code,
            headers = resp_headers,
        }, type(response) == "string" and response or "")
    elseif not code then
        log_response("HTTP response unavailable:", {
            method = req_opts.method,
            url = req_opts.url,
            api_name = diagnostic_api,
            code = status or raw_code,
            headers = resp_headers,
        }, type(response) == "string" and response or "")
    end

    return response, code, resp_headers or {}, status
end

function Client:request_follow(opts, max_redirects)
    local request_opts = deepcopy(opts or {})
    local on_redirect = request_opts.on_redirect
    request_opts.on_redirect = nil
    max_redirects = max_redirects or request_opts.maxredirects or 5
    request_opts.maxredirects = nil
    local url = request_opts.url

    for _redirect_index = 0, max_redirects do
        request_opts.url = url
        local text, code, headers, status = self:request(request_opts)
        local is_redirect = code == 301 or code == 302 or code == 303
            or code == 307 or code == 308
        if not is_redirect then
            return text, code, headers, status, url
        end

        local next_url = absolute_url(url, header_value(headers, "location"))
        if not next_url then
            return text, code, headers, status, url
        end
        if on_redirect then
            on_redirect(url, next_url, code)
        end
        if url_origin(url) ~= url_origin(next_url) then
            clear_cross_origin_headers(request_opts.headers)
        end
        if code == 303 or ((code == 301 or code == 302)
            and request_opts.method ~= "GET" and request_opts.method ~= "HEAD") then
            request_opts.method = "GET"
            request_opts.body = nil
            request_opts.source = nil
            if request_opts.headers then
                for key in pairs(request_opts.headers) do
                    if tostring(key):lower() == "content-length" then
                        request_opts.headers[key] = nil
                    end
                end
            end
        end
        url = next_url
    end
    error("Too many redirects")
end

-- Download a response directly to disk. The sink deliberately stays open when
-- LuaSocket signals end-of-response because request_follow may need to reuse it
-- after a redirect. On every redirect the partial response body is discarded.
function Client:download_to_file(url, path, opts)
    opts = opts or {}
    local part_path = path .. ".part"
    pcall(os.remove, part_path)
    local handle, open_err = io.open(part_path, "wb")
    if not handle then error(open_err or "could not create download file") end

    local bytes = 0
    local max_bytes = tonumber(opts.max_bytes)
    local function reopen()
        if handle then handle:close() end
        handle, open_err = io.open(part_path, "wb")
        if not handle then error(open_err or "could not reset download file") end
        bytes = 0
    end
    local function sink(chunk)
        if not chunk then return 1 end
        if max_bytes and bytes + #chunk > max_bytes then
            return nil, "download exceeds size limit"
        end
        local ok, err = handle:write(chunk)
        if not ok then return nil, err end
        bytes = bytes + #chunk
        return 1
    end

    local request_opts = merge_req_opts(opts, {
        url = url,
        method = "GET",
        maxredirects = 5,
        sink = sink,
        on_redirect = function()
            reopen()
        end,
        headers = {
            ["Accept"] = header_value(opts.headers, "Accept") or opts.accept or "*/*",
            ["Referer"] = header_value(opts.headers, "Referer") or opts.referer or "https://weread.qq.com/",
        },
    })
    request_opts.max_bytes = nil
    request_opts.accept = nil
    request_opts.referer = nil

    local ok, text, code, resp_headers = pcall(function()
        return self:request_follow(request_opts)
    end)
    if handle then handle:close() end
    handle = nil
    if not ok then
        pcall(os.remove, part_path)
        error(text, 0)
    end
    if not code or code < 200 or code >= 300 then
        pcall(os.remove, part_path)
        error(http_error(self, code, text, resp_headers))
    end
    if bytes == 0 then
        pcall(os.remove, part_path)
        error("download returned an empty body")
    end
    pcall(os.remove, path)
    local renamed, rename_err = os.rename(part_path, path)
    if not renamed then
        pcall(os.remove, part_path)
        error(rename_err or "could not commit downloaded file")
    end
    return path, bytes, resp_headers
end

function Client:post_json(url, data, opts)
    opts = opts or {}
    local referer = header_value(opts.headers, "Referer") or opts.referer
    local req_opts = merge_req_opts(opts, {
        url = url,
        method = "POST",
        body = self:json_encode(data),
        headers = {
            ["Content-Type"] = "application/json;charset=UTF-8",
            ["Origin"] = "https://weread.qq.com",
            ["Referer"] = referer or "https://weread.qq.com/",
        }})
    local text, code, resp_headers = self:request(req_opts)
    if code and code >= 200 and code < 300 then
        return self:decode_http_json(text, {
            method = "POST",
            url = url,
            api_name = opts.diagnostic_api,
            code = code,
            headers = resp_headers,
        }), code, resp_headers
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:get_text(url, opts)
    opts = opts or {}
    local accept = header_value(opts.headers, "Accept") or opts.accept
    local referer = header_value(opts.headers, "Referer") or opts.referer
    local req_opts = merge_req_opts(opts, {
        url = url,
        method = "GET",
        headers = {
            ["Accept"] = accept or "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Referer"] = referer or "https://weread.qq.com/",
        }})
    local text, code, resp_headers = self:request(req_opts)
    if code and code >= 200 and code < 300 then
        return text, code, resp_headers
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:get_public_text(url, opts)
    opts = opts or {}
    local req_opts = merge_req_opts(opts, {
        maxredirects = 5,
        headers = {
            ["Accept"] = header_value(opts.headers, "Accept") or opts.accept or "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Referer"] = header_value(opts.headers, "Referer") or opts.referer or "https://mp.weixin.qq.com/",
        }
    })
    local text, code, resp_headers, _status, final_url = self:request_follow(
        merge_req_opts(req_opts, { url = url, method = "GET" })
    )
    if not code or code < 200 or code >= 300 then
        error(http_error(self, code, text, resp_headers))
    end
    return text, {
        code = code,
        content_type = header_value(resp_headers, "content-type"),
        length = #(text or ""),
        url = final_url or url,
    }
end

function Client:get_binary(url, opts)
    opts = opts or {}
    local req_opts = merge_req_opts(opts, {
        maxredirects = 5,
        headers = {
            ["Accept"] = header_value(opts.headers, "Accept") or opts.accept or "*/*",
            ["Referer"] = header_value(opts.headers, "Referer") or opts.referer or "https://weread.qq.com/",
        }
    })
    local text, code, resp_headers = self:request_follow(
        merge_req_opts(req_opts, { url = url, method = "GET" })
    )
    if code and code >= 200 and code < 300 then
        return text, code, resp_headers
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:renew_cookie()
    local result, code, resp_headers = self:post_json("https://weread.qq.com/web/login/renewal", {
        rq = "%2Fweb%2Fbook%2Fread",
        ql = false,
    }, {
        -- Do not persist renewal cookies until the response explicitly confirms
        -- success; failed renewals must leave the current credential set intact.
        persist_response_cookies = false,
    })
    if not WeRead.is_success_response(result) then
        error("Cookie renewal response did not include succ=1")
    end
    local updates = {}
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        updates.cookies = Cookie.merge_set_cookie(
            self.settings:get("cookies", {}),
            set_cookie
        )
    end
    local wr_ticket = scalar_header_value(resp_headers, "x-wr-ticket")
    if wr_ticket and wr_ticket ~= "" then
        updates.wr_ticket = wr_ticket
    end
    local wr_wrpa = scalar_header_value(resp_headers, "x-wrpa-0")
    if wr_wrpa and wr_wrpa ~= "" then
        updates.wr_wrpa = wr_wrpa
    end
    self.settings:update_auth(updates, { replace_cookies = true })
    return result, code, resp_headers
end

function Client:gateway(api_name, params)
    local payload = merge_req_opts({
        api_name = api_name,
        skill_version = (params and params.skill_version) or WeRead.SKILL_VERSION
    }, params)

    local api_key = self.settings:get("api_key", "")
    if api_key == "" then
        error("WeRead API key is not configured")
    end
    return self:post_json("https://i.weread.qq.com/api/agent/gateway", payload, {
        diagnostic_api = api_name,
        skip_cookie = true,
        headers = {
            ["Authorization"] = "Bearer " .. api_key,
        },
    })
end

function Client:get_shelf()
    logger.info(
        "shelf sync request:",
        "api=/shelf/sync",
        "skill_version=", WeRead.SKILL_VERSION,
        "auth=api_key",
        "cookies=skipped",
        "params=none"
    )
    local ok, result, code, headers = pcall(
        self.gateway,
        self,
        "/shelf/sync",
        {}
    )
    if not ok then
        logger.err(
            "shelf sync failed:",
            "api=/shelf/sync",
            "skill_version=", WeRead.SKILL_VERSION,
            "error=", log_error(result)
        )
        error(result, 0)
    end

    logger.info(
        "shelf sync completed:",
        "api=/shelf/sync",
        "http_status=", tostring(code or "unknown"),
        "response=", table_summary(result),
        "books=", table_summary(type(result) == "table" and result.books or nil),
        "archive=", table_summary(type(result) == "table" and result.archive or nil),
        "albums=", table_summary(type(result) == "table" and result.albums or nil),
        "mp=", table_summary(type(result) == "table" and result.mp or nil)
    )
    return result, code, headers
end

function Client:get_book_info(book_id)
    return self:gateway("/book/info", { bookId = book_id })
end

function Client:get_book_reviews(book_id, review_list_type, count)
    return self:gateway("/review/list", {
        bookId = book_id,
        reviewListType = review_list_type or 1,
        count = count or 20,
    })
end

function Client:get_progress(book_id)
    return self:gateway("/book/getprogress", { bookId = book_id })
end

function Client:get_web_progress(book_id)
    local url = "https://weread.qq.com/web/book/getProgress?bookId="
        .. WeRead.urlencode(book_id)
        .. "&_=" .. tostring(os.time() * 1000)
    local text, code, headers = self:get_text(url, {
        accept = "application/json, text/plain, */*",
        referer = WeRead.reader_url(book_id),
    })
    return self:decode_http_json(text, {
        method = "GET",
        url = url,
        code = code,
        headers = headers,
    })
end

-- Reading statistics detail.
-- mode: "weekly" | "monthly" | "annually" | "overall"
-- base_time: optional Unix timestamp; server normalizes it to the period start
--            (Monday / 1st of month / Jan 1st). Pass 0/nil for the current period.
function Client:get_read_stats(mode, base_time)
    local params = { mode = mode or "monthly" }
    if base_time and tonumber(base_time) and tonumber(base_time) > 0 then
        params.baseTime = tonumber(base_time)
    end
    return self:gateway("/readdata/detail", params)
end

function Client:get_mp_articles(book_id, max_idx, count, wr_ticket)
    local url = string.format(
        "https://weread.qq.com/web/mp/articles?bookId=%s&maxIdx=%d&count=%d",
        WeRead.urlencode(book_id),
        max_idx or 0,
        count or 100
    )

    local custom_headers = {
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = "https://weread.qq.com/",
    }

    if wr_ticket and wr_ticket ~= "" then
        custom_headers["x-wr-ticket"] = wr_ticket
    end

    local wrpa = self.settings:get("wr_wrpa", "")
    if wrpa ~= "" then
        custom_headers["x-wrpa-0"] = wrpa
    end

    local text, code, resp_headers = self:request({
        url = url,
        method = "GET",
        headers = custom_headers,
    })

    if code and code >= 200 and code < 300 then
        local data = self:decode_http_json(text, {
            method = "GET",
            url = url,
            code = code,
            headers = resp_headers,
        })
        if data.errCode and data.errCode ~= 0 then
            return nil, data.errCode
        end
        return data, nil
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:get_mp_content(review_id, opts)
    opts = opts or {}
    local url = "https://weread.qq.com/web/mp/content?reviewId=" .. WeRead.urlencode(review_id)

    local custom_headers = {
        ["Accept"] = "text/html,application/xhtml+xml,*/*",
        ["Referer"] = opts.referer or "https://weread.qq.com/",
    }
    if not opts.skip_mp_auth_headers then
        local wr_ticket = self.settings:get("wr_ticket", "")
        if wr_ticket ~= "" then custom_headers["x-wr-ticket"] = wr_ticket end

        local wrpa = self.settings:get("wr_wrpa", "")
        if wrpa ~= "" then custom_headers["x-wrpa-0"] = wrpa end
    end

    local text, code, resp_headers = self:request({
        url = url,
        method = "GET",
        headers = custom_headers,
        timeout = opts.timeout,
    })

    if code and code >= 200 and code < 300 then
        return text, {
            code = code,
            content_type = header_value(resp_headers, "content-type"),
            length = #(text or ""),
            url = url,
        }
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:report_read(payload, referer)
    return self:post_json("https://weread.qq.com/web/book/read", payload, {
        referer = referer or "https://weread.qq.com/",
    })
end

local function eink_payload_error(data)
    if type(data) ~= "table" then return nil end
    local err = data.errCode or data.errcode
    if err ~= nil and tostring(err) ~= "0" then return err end
    return nil
end

local function merge_chapter_underlines(rows, seen, items, chapter_uid)
    local data = Eink.underlines_for_chapter(items, chapter_uid)
    for _, row in ipairs(data.underlines or {}) do
        local key = tostring(row.range or "")
        if key ~= "" and not seen[key] then
            seen[key] = true
            rows[#rows + 1] = row
        end
    end
end

function Client:_web_chapter_underlines(book_id, chapter_uid)
    local ok, result = pcall(function()
        return self:gateway("/book/underlines", {
            bookId = tostring(book_id),
            chapterUid = chapter_uid,
        })
    end)
    if not ok then
        return false, nil, tostring(result)
    end
    if type(result) ~= "table" then
        return false, nil, "underlines: gateway returned non-table"
    end
    return true, result
end

function Client:get_chapter_underlines(book_id, chapter_uid)
    if not book_id or tostring(book_id) == "" then
        return false, nil, "empty book_id"
    end
    if not chapter_uid then
        return false, nil, "empty chapter_uid"
    end

    local own_items
    if self:can_eink_download() then
        local ok_own, own = pcall(function()
            return self:eink_bookmarklist(book_id)
        end)
        if ok_own and type(own) == "table" and not eink_payload_error(own) then
            own_items = own.updated
        end
        local ok_best, best = false, nil
        if self:can_eink_download() then
            ok_best, best = pcall(function()
                return self:eink_bestbookmarks(book_id)
            end)
        end
        if ok_best and type(best) == "table" and not eink_payload_error(best) then
            local rows, seen = {}, {}
            merge_chapter_underlines(rows, seen,
                best.updated or best.bookmarks or best.items, chapter_uid)
            merge_chapter_underlines(rows, seen, own_items, chapter_uid)
            logger.info("chapter underlines via eink",
                "book=", tostring(book_id), "chapter=", tostring(chapter_uid),
                "count=", tostring(#rows))
            return true, { chapterUid = chapter_uid, underlines = rows }
        end
        logger.warn("eink bestbookmarks failed, falling back to web:",
            tostring(not ok_best and best or eink_payload_error(best) or "invalid"))
    end

    local ok, result, err = self:_web_chapter_underlines(book_id, chapter_uid)
    if ok and own_items then
        result.underlines = result.underlines or {}
        local seen = {}
        for _, row in ipairs(result.underlines) do
            seen[tostring(row.range or "")] = true
        end
        merge_chapter_underlines(result.underlines, seen, own_items, chapter_uid)
    end
    return ok, result, err
end

function Client:build_chapter_review_batches(ranges)
    local BATCH_SIZE = 30
    local batches = {}
    for batch_start = 1, #(ranges or {}), BATCH_SIZE do
        local batch = {}
        for index = batch_start, math.min(batch_start + BATCH_SIZE - 1, #ranges) do
            batch[#batch + 1] = {
                range = ranges[index],
                maxIdx = 0,
                count = 30,
                synckey = 0,
            }
        end
        batches[#batches + 1] = batch
    end
    return batches
end

function Client:get_chapter_reviews_batch(book_id, chapter_uid, batch)
    if not book_id or tostring(book_id) == "" then
        return false, nil, "empty book_id"
    end
    if not chapter_uid then
        return false, nil, "empty chapter_uid"
    end
    if type(batch) ~= "table" or #batch == 0 then
        return true, { reviews = {} }
    end

    if self:can_eink_download() then
        local ok, result = pcall(function()
            return self:eink_post_json("/book/readreviews", {
                bookId = tostring(book_id),
                chapterUid = chapter_uid,
                reviews = batch,
            })
        end)
        if ok and type(result) == "table" and type(result.reviews) == "table"
            and not eink_payload_error(result) then
            logger.info("chapter thoughts via eink",
                "book=", tostring(book_id), "chapter=", tostring(chapter_uid),
                "reviews=", tostring(#result.reviews))
            return true, result
        end
        logger.warn("eink readreviews failed, falling back to web:",
            tostring(not ok and result or eink_payload_error(result) or "invalid"))
    end

    local ok, result = pcall(function()
        return self:gateway("/book/readreviews", {
            bookId = tostring(book_id),
            chapterUid = chapter_uid,
            reviews = batch,
        })
    end)
    if not ok then
        return false, nil, tostring(result)
    end
    if type(result) ~= "table" or type(result.reviews) ~= "table" then
        return false, nil, "readreviews: gateway returned invalid data"
    end
    return true, result
end

function Client:get_chapter_reviews(book_id, chapter_uid, ranges)
    if type(ranges) ~= "table" or #ranges == 0 then
        return true, { reviews = {} }
    end

    local all_reviews = {}
    local batches = self:build_chapter_review_batches(ranges)
    local socket_ok, socket = pcall(require, "socket")

    for batch_index, batch in ipairs(batches) do
        local ok, result = self:get_chapter_reviews_batch(book_id, chapter_uid, batch)
        if ok and type(result) == "table" and type(result.reviews) == "table" then
            for _, review in ipairs(result.reviews) do
                all_reviews[#all_reviews + 1] = review
            end
        end

        if batch_index < #batches and socket_ok and socket.sleep then
            socket.sleep(0.3)
        end
    end

    return true, { reviews = all_reviews }
end

function Client:get_review_comments(review_id, count, opts)
    opts = opts or {}
    if type(review_id) ~= "string" or review_id == "" then
        return false, nil, "empty review_id"
    end

    local comments_count = count or 20
    local url = "https://weread.qq.com/web/review/single"
        .. "?reviewId=" .. WeRead.urlencode(review_id)
        .. "&commentsCount=" .. tostring(comments_count)
        .. "&commentsDirection=" .. tostring(opts.comments_direction or 0)
        .. "&likesCount=" .. tostring(opts.likes_count or 0)
        .. "&synckey=" .. tostring(opts.synckey or 0)

    local ok, text, code, headers = pcall(function()
        return self:get_text(url, {
            accept = "application/json, text/plain, */*",
            referer = opts.referer or "https://weread.qq.com/",
            timeout = opts.timeout,
        })
    end)
    if not ok then
        return false, nil, tostring(text)
    end
    if not text or text == "" then
        return false, nil, "empty response"
    end

    local decode_ok, parsed = pcall(function()
        return self:decode_http_json(text, {
            method = "GET",
            url = url,
            code = code,
            headers = headers,
        })
    end)
    if not decode_ok or type(parsed) ~= "table" then
        return false, text, "invalid JSON"
    end
    return true, parsed, nil
end

function Client:eink_credentials()
    local eink = self.settings:get("eink", {}) or {}
    local vid = tostring(eink.vid or "")
    local token = tostring(eink['access_token'] or "")
    if vid == "" or token == "" then
        return nil
    end
    return vid, token
end

function Client:mark_eink_auth_failed()
    if self._eink_auth_failed then return end
    self._eink_auth_failed = true
    local settings = self.settings
    if settings and type(settings.get) == "function" and type(settings.set) == "function" then
        local eink = settings:get("eink", {}) or {}
        eink.auth_failed = true
        settings:set("eink", eink)
        if type(settings.flush) == "function" then settings:flush() end
    end
    logger.warn("eink login expired; falling back to web until you scan again")
end

function Client:can_eink_download()
    if not self:eink_credentials() then return false end
    if self._eink_auth_failed then return false end
    local eink = self.settings and self.settings.get and self.settings:get("eink", {}) or {}
    if eink.auth_failed == true then
        self._eink_auth_failed = true
        return false
    end
    return true
end

local function eink_body_preview(body)
    if type(body) == "table" then
        local errcode = body.errcode or body.errCode or body.code
        local errmsg = body.errmsg or body.errMsg or body.errlog
        local bits = {}
        if errcode ~= nil then bits[#bits + 1] = "errcode=" .. tostring(errcode) end
        if errmsg ~= nil then bits[#bits + 1] = "errmsg=" .. tostring(errmsg) end
        if #bits > 0 then
            return table.concat(bits, " ")
        end
        return "json-object"
    end
    if type(body) ~= "string" or body == "" then
        return tostring(body)
    end
    local prefix = body:sub(1, 180):gsub("[%c]+", " ")
    return prefix
end

function Client:eink_request(path, params)
    local vid, token = self:eink_credentials()
    if not vid then
        error("eink credentials are missing")
    end
    local query = {}
    for key, value in pairs(params or {}) do
        query[#query + 1] = WeRead.urlencode(tostring(key)) .. "=" .. WeRead.urlencode(tostring(value))
    end
    table.sort(query)
    local url = "https://i.weread.qq.com" .. path
    if #query > 0 then
        url = url .. "?" .. table.concat(query, "&")
    end
    local body, code, headers = self:request({
        url = url,
        method = "GET",
        skip_cookie = true,
        persist_response_cookies = false,
        timeout = { 30, 180 },
        headers = {
            ["User-Agent"] = Eink.USER_AGENT,
            ["Accept"] = "*/*",
            ["vid"] = vid,
            ["accessToken"] = token,
            ["appver"] = Eink.APPVER,
            ["basever"] = Eink.APPVER,
            ["baseapi"] = "30",
            ["osver"] = "11",
            ["channelId"] = "900",
        },
        diagnostic_api = path,
        log_http_errors = false,
    })
    if tonumber(code) == 401 then self:mark_eink_auth_failed() end
    return body, code, headers or {}
end

function Client:eink_json(path, params)
    local body, code = self:eink_request(path, params)
    if not code or code < 200 or code >= 300 then
        error("eink " .. path .. " failed: HTTP " .. tostring(code or "unknown"))
    end
    return self:decode_http_json(body, {
        method = "GET",
        url = path,
        code = code,
    }), code
end

function Client:eink_post_json(path, payload)
    local vid, token = self:eink_credentials()
    if not vid then
        error("eink credentials are missing")
    end
    local body, code = self:request({
        url = "https://i.weread.qq.com" .. path,
        method = "POST",
        skip_cookie = true,
        persist_response_cookies = false,
        timeout = { 30, 180 },
        headers = {
            ["User-Agent"] = Eink.USER_AGENT,
            ["Accept"] = "*/*",
            ["Content-Type"] = "application/json;charset=UTF-8",
            ["vid"] = vid,
            ["accessToken"] = token,
            ["appver"] = Eink.APPVER,
            ["basever"] = Eink.APPVER,
            ["baseapi"] = "30",
            ["osver"] = "11",
            ["channelId"] = "900",
        },
        body = self:json_encode(payload or {}),
        diagnostic_api = path,
        log_http_errors = false,
    })
    if tonumber(code) == 401 then self:mark_eink_auth_failed() end
    if not code or code < 200 or code >= 300 then
        error("eink POST " .. path .. " failed: HTTP " .. tostring(code or "unknown"))
    end
    return self:decode_http_json(body, {
        method = "POST",
        url = path,
        code = code,
    })
end

function Client:eink_chapterinfo(book_id)
    local body, code = self:eink_request("/book/chapterinfo", { bookId = tostring(book_id) })
    if not code or code < 200 or code >= 300 then
        error("eink chapterinfo failed: HTTP " .. tostring(code or "unknown"))
    end
    return self:decode_http_json(body, {
        method = "GET",
        url = "/book/chapterinfo",
        code = code,
    })
end

function Client:eink_bestbookmarks(book_id)
    book_id = tostring(book_id or "")
    self._eink_bestbookmarks_cache = self._eink_bestbookmarks_cache or {}
    if self._eink_bestbookmarks_cache[book_id] then
        return self._eink_bestbookmarks_cache[book_id]
    end
    local data = self:eink_json("/book/bestbookmarks", { bookId = book_id })
    local err = eink_payload_error(data)
    if err then
        error("eink bestbookmarks errCode=" .. tostring(err))
    end
    self._eink_bestbookmarks_cache[book_id] = data
    return data
end

function Client:eink_bookmarklist(book_id)
    book_id = tostring(book_id or "")
    self._eink_bookmark_cache = self._eink_bookmark_cache or {}
    if self._eink_bookmark_cache[book_id] then
        return self._eink_bookmark_cache[book_id]
    end
    local body, code = self:eink_request("/book/bookmarklist", { bookId = book_id })
    if not code or code < 200 or code >= 300 then
        error("eink bookmarklist failed: HTTP " .. tostring(code or "unknown"))
    end
    local data = self:decode_http_json(body, {
        method = "GET",
        url = "/book/bookmarklist",
        code = code,
    })
    self._eink_bookmark_cache[book_id] = data
    return data
end

function Client:eink_download_to_file(book_id, chapters_param, path)
    local vid, token = self:eink_credentials()
    if not vid then
        error("eink credentials are missing")
    end
    local query = {
        "bookId=" .. WeRead.urlencode(tostring(book_id)),
        "chapters=" .. WeRead.urlencode(tostring(chapters_param)),
    }
    table.sort(query)
    local url = "https://i.weread.qq.com/book/chapterdownload?" .. table.concat(query, "&")
    return self:download_to_file(url, path, {
        skip_cookie = true,
        persist_response_cookies = false,
        timeout = { 30, 300 },
        headers = {
            ["User-Agent"] = Eink.USER_AGENT,
            ["Accept"] = "*/*",
            ["vid"] = vid,
            ["accessToken"] = token,
            ["appver"] = Eink.APPVER,
            ["basever"] = Eink.APPVER,
            ["baseapi"] = "30",
            ["osver"] = "11",
            ["channelId"] = "900",
        },
        diagnostic_api = "/book/chapterdownload",
    })
end

function Client:eink_download_zip(book_id, chapters_param)
    local vid = self:eink_credentials()
    local body, code, headers = self:eink_request("/book/chapterdownload", {
        bookId = tostring(book_id),
        chapters = tostring(chapters_param),
    })
    if not code or code < 200 or code >= 300 then
        error("eink chapterdownload failed: HTTP " .. tostring(code or "unknown")
            .. " " .. eink_body_preview(body))
    end
    if type(body) == "string" and body:sub(1, 1) == "{" then
        local ok_errjson, parsed = pcall(self.json_decode, self, body)
        if ok_errjson then
            error("eink chapterdownload did not return a ZIP: HTTP "
                .. tostring(code) .. " " .. eink_body_preview(parsed))
        end
    end
    if type(body) == "string" and Eink.is_tar(body) then
        return Eink.untar(body)
    end
    if type(body) ~= "string" or body:sub(1, 2) ~= "PK" then
        error("eink chapterdownload did not return a ZIP: HTTP "
            .. tostring(code) .. " " .. eink_body_preview(body))
    end
    local encrypt_key = header_value(headers, "encryptKey") or header_value(headers, "encryptkey")
    if not encrypt_key or encrypt_key == "" then
        error("eink chapterdownload missing encryptKey header")
    end
    local password = Eink.decrypt_zip_password(encrypt_key, vid)
    return Eink.unzip_encrypted(body, password)
end

return Client
