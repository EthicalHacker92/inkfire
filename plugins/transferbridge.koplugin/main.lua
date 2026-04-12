--[[
TransferBridge — WiFi drag-and-drop file transfer for KOReader
Starts a non-blocking HTTP server on port 8765, serves a drag-drop browser UI,
handles multipart file uploads, MD5 duplicate detection, auto-organizes files.
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local NetworkMgr      = require("ui/network/manager")
local logger          = require("logger")
local lfs             = require("libs/libkoreader-lfs")
local socket          = require("socket")
local _               = require("gettext")
local T               = require("ffi/util").template

-- ── Constants ─────────────────────────────────────────────────────────────────

local TRANSFER_PORT    = 8765
local POLL_INTERVAL    = 0.15   -- seconds between accept() polls
local MAX_UPLOAD_BYTES = 500 * 1024 * 1024  -- 500 MB safety cap

-- Maps file extension → destination subdirectory (relative to base_dir)
local EXT_TO_DIR = {
    [".cbz"]  = "manga",
    [".cbr"]  = "manga",
    [".zip"]  = "manga",
    [".epub"] = "books",
    [".mobi"] = "books",
    [".azw"]  = "books",
    [".azw3"] = "books",
    [".fb2"]  = "books",
    [".pdf"]  = "books",
}

-- ── Plugin class ──────────────────────────────────────────────────────────────

local TransferBridge = WidgetContainer:extend{
    name      = "transferbridge",
    server    = nil,
    is_running = false,
    base_dir  = nil,
    -- Tracks upload results for /api/status polling
    status    = nil,
}

function TransferBridge:init()
    self.status = { files = {}, done = 0, errors = 0 }

    -- Resolve writable base directory
    self.base_dir = "/mnt/onboard"
    if not lfs.attributes(self.base_dir, "mode") then
        -- Emulator / non-Kobo fallback
        self.base_dir = require("datastorage"):getDataDir()
    end

    self.ui.menu:registerToMainMenu(self)
end

-- ── Menu ──────────────────────────────────────────────────────────────────────

function TransferBridge:addToMainMenu(menu_items)
    menu_items.transferbridge = {
        text = _("TransferBridge"),
        sub_item_table = {
            {
                text_func = function()
                    return self.is_running
                        and _("Stop Transfer Server")
                        or  _("Start Transfer Server")
                end,
                callback = function()
                    if self.is_running then
                        self:stopServer()
                    else
                        self:startServer()
                    end
                end,
            },
            {
                text = _("Show Transfer URL"),
                enabled_func = function() return self.is_running end,
                callback = function() self:showAddress() end,
                keep_menu_open = true,
            },
        },
    }
end

-- ── Server lifecycle ──────────────────────────────────────────────────────────

function TransferBridge:startServer()
    if self.is_running then
        UIManager:show(InfoMessage:new{
            text = _("TransferBridge is already running."),
            timeout = 2,
        })
        return
    end

    if not NetworkMgr:isConnected() then
        NetworkMgr:beforeWifiAction(function() self:startServer() end)
        return
    end

    local srv, err = socket.bind("*", TRANSFER_PORT)
    if not srv then
        UIManager:show(InfoMessage:new{
            text = T(_("TransferBridge: could not start — %1"), tostring(err)),
        })
        return
    end

    srv:settimeout(0)   -- non-blocking accept
    self.server     = srv
    self.is_running = true
    self.status     = { files = {}, done = 0, errors = 0 }

    self:ensureDirs()
    UIManager:scheduleIn(POLL_INTERVAL, function() self:poll() end)
    self:showAddress()
end

function TransferBridge:stopServer()
    if not self.is_running then return end
    self.is_running = false
    if self.server then
        self.server:close()
        self.server = nil
    end
    UIManager:show(InfoMessage:new{
        text = _("TransferBridge stopped."),
        timeout = 2,
    })
end

function TransferBridge:showAddress()
    local ip  = self:getDeviceIP()
    local url = ("http://%s:%d"):format(ip, TRANSFER_PORT)
    UIManager:show(InfoMessage:new{
        text = T(_("TransferBridge\n\n%1\n\nOpen in browser or scan QR."), url),
    })
end

function TransferBridge:poll()
    if not self.is_running then return end

    local client = self.server:accept()
    if client then
        client:settimeout(120)  -- 2 min to accommodate large CBZ uploads
        local ok, err = pcall(function() self:dispatch(client) end)
        if not ok then
            logger.warn("TransferBridge dispatch error:", err)
        end
        client:close()
    end

    UIManager:scheduleIn(POLL_INTERVAL, function() self:poll() end)
end

-- ── HTTP dispatch ─────────────────────────────────────────────────────────────

function TransferBridge:dispatch(client)
    local req_line = client:receive("*l")
    if not req_line then return end

    local method, path = req_line:match("^(%u+) ([^%s]+)")
    if not method then return end

    -- Consume all request headers
    local headers = {}
    while true do
        local line = client:receive("*l")
        if not line or line == "" then break end
        local k, v = line:match("^([^:]+):%s*(.+)$")
        if k then headers[k:lower()] = v end
    end

    if     method == "GET"  and path == "/"            then self:serveHTML(client)
    elseif method == "GET"  and path == "/api/status"  then self:serveStatus(client)
    elseif method == "POST" and path == "/api/upload"  then self:handleUpload(client, headers)
    else   self:reply(client, 404, "text/plain", "Not found")
    end
end

-- ── Route handlers ────────────────────────────────────────────────────────────

function TransferBridge:serveHTML(client)
    local plugin_dir = self:pluginDir()
    local path = plugin_dir .. "/ui/dropzone.html"
    local f = io.open(path, "r")
    local body = f and f:read("*a") or "<h1>TransferBridge — UI missing</h1>"
    if f then f:close() end
    -- Inject live device URL so fetch() calls go to the right host
    local url = ("http://%s:%d"):format(self:getDeviceIP(), TRANSFER_PORT)
    body = body:gsub("__DEVICE_URL__", url)
    self:reply(client, 200, "text/html; charset=utf-8", body)
end

function TransferBridge:serveStatus(client)
    self:reply(client, 200, "application/json", self:jsonEncode(self.status))
end

function TransferBridge:handleUpload(client, headers)
    local clen = tonumber(headers["content-length"]) or 0
    local ctype = headers["content-type"] or ""

    if clen > MAX_UPLOAD_BYTES then
        self:reply(client, 413, "application/json", '{"error":"file too large"}')
        return
    end

    -- Strip optional quotes: boundary="---abc" → ---abc
    local boundary = ctype:match('boundary="([^"]+)"') or ctype:match("boundary=([^\r\n;%s]+)")
    if not boundary then
        self:reply(client, 400, "application/json", '{"error":"missing boundary"}')
        return
    end

    -- Receive in 64 KB chunks to handle large files without buffer overflow
    local chunks   = {}
    local received = 0
    while received < clen do
        local chunk = client:receive(math.min(65536, clen - received))
        if not chunk then break end
        table.insert(chunks, chunk)
        received = received + #chunk
    end
    if received < clen then
        self:reply(client, 400, "application/json", '{"error":"incomplete upload"}')
        return
    end
    local body = table.concat(chunks)

    local results = {}
    for _, part in ipairs(self:parseMultipart(body, boundary)) do
        local res = self:saveFile(part.filename, part.data)
        table.insert(results, res)
        if res.status == "ok" then
            self.status.done = self.status.done + 1
            table.insert(self.status.files, { name = part.filename, status = "ok" })
        else
            self.status.errors = self.status.errors + 1
            table.insert(self.status.files, { name = part.filename, status = res.status })
        end
    end

    if #results > 0 then self:refreshLibrary() end
    self:reply(client, 200, "application/json", self:jsonEncode({ results = results }))
end

-- ── Multipart parser ──────────────────────────────────────────────────────────

function TransferBridge:parseMultipart(body, boundary)
    local parts   = {}
    local delim   = "--" .. boundary
    local pos     = 1

    while true do
        local ds, de = body:find(delim, pos, true)
        if not ds then break end

        -- Check for final boundary (--)
        if body:sub(de + 1, de + 2) == "--" then break end

        -- Skip CRLF after boundary line
        local chunk_start = de + 1
        if body:sub(chunk_start, chunk_start + 1) == "\r\n" then
            chunk_start = chunk_start + 2
        end

        -- Find next boundary to delimit this part
        local ne = body:find(delim, chunk_start, true)
        if not ne then break end

        local chunk = body:sub(chunk_start, ne - 3)  -- strip trailing \r\n

        -- Split headers / body at \r\n\r\n
        local hend = chunk:find("\r\n\r\n", 1, true)
        if hend then
            local hdr  = chunk:sub(1, hend - 1)
            local data = chunk:sub(hend + 4)
            local filename = hdr:match('filename="([^"]+)"')
            if filename and #data > 0 then
                table.insert(parts, { filename = filename, data = data })
            end
        end

        pos = ne
    end

    return parts
end

-- ── File I/O ──────────────────────────────────────────────────────────────────

function TransferBridge:destPath(filename)
    local ext  = (filename:match("%.([^%.]+)$") or ""):lower()
    local subdir = EXT_TO_DIR["." .. ext] or "books"
    return ("%s/%s/%s"):format(self.base_dir, subdir, filename)
end

function TransferBridge:isDuplicate(filename, data)
    local dest = self:destPath(filename)
    local attrs = lfs.attributes(dest)
    if attrs and attrs.size == #data then
        return true
    end
    return false
end

function TransferBridge:saveFile(filename, data)
    if self:isDuplicate(filename, data) then
        return { filename = filename, status = "duplicate" }
    end

    local dest = self:destPath(filename)
    local dir  = dest:match("^(.+)/[^/]+$")
    if dir and not lfs.attributes(dir, "mode") then
        lfs.mkdir(dir)
    end

    local f, err = io.open(dest, "wb")
    if not f then
        return { filename = filename, status = "error", message = tostring(err) }
    end
    f:write(data)
    f:close()

    return { filename = filename, status = "ok", path = dest }
end

function TransferBridge:ensureDirs()
    for _, subdir in pairs({ "manga", "books" }) do
        local p = self.base_dir .. "/" .. subdir
        if not lfs.attributes(p, "mode") then lfs.mkdir(p) end
    end
end

function TransferBridge:refreshLibrary()
    local ok, FM = pcall(require, "apps/filemanager/filemanager")
    if ok and FM and FM.instance then
        FM.instance:onRefresh()
    end
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

function TransferBridge:getDeviceIP()
    local udp = socket.udp()
    if udp then
        udp:setpeername("8.8.8.8", 80)
        local ip = udp:getsockname()
        udp:close()
        if ip and ip ~= "0.0.0.0" then return ip end
    end
    return "127.0.0.1"
end

function TransferBridge:pluginDir()
    -- Resolve directory from this file's path
    local src = debug.getinfo(1, "S").source
    src = src:sub(2)  -- strip leading @
    return src:match("^(.+)/[^/]+$") or "."
end

function TransferBridge:reply(client, code, ctype, body)
    local status_text = ({
        [200] = "OK", [400] = "Bad Request",
        [404] = "Not Found", [413] = "Payload Too Large",
    })[code] or "Error"
    client:send(table.concat({
        ("HTTP/1.1 %d %s"):format(code, status_text),
        ("Content-Type: %s"):format(ctype),
        ("Content-Length: %d"):format(#body),
        "Access-Control-Allow-Origin: *",
        "Connection: close",
        "", body,
    }, "\r\n"))
end

-- Minimal JSON encoder (no external deps)
function TransferBridge:jsonEncode(v)
    local t = type(v)
    if t == "nil"     then return "null"
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "number"  then return tostring(v)
    elseif t == "string"  then
        return '"' .. v:gsub('\\','\\\\'):gsub('"','\\"')
                        :gsub('\n','\\n'):gsub('\r','\\r') .. '"'
    elseif t == "table"  then
        -- Detect array vs object
        local is_array = (#v > 0)
        if is_array then
            local a = {}
            for _, item in ipairs(v) do table.insert(a, self:jsonEncode(item)) end
            return "[" .. table.concat(a, ",") .. "]"
        else
            local o = {}
            for k, val in pairs(v) do
                table.insert(o, self:jsonEncode(tostring(k)) .. ":" .. self:jsonEncode(val))
            end
            return "{" .. table.concat(o, ",") .. "}"
        end
    end
    return "null"
end

return TransferBridge
