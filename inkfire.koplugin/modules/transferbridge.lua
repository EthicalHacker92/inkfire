--[[
InkFire — TransferBridge Module
Pure logic layer: HTTP server lifecycle, upload handling, file organization.
UIManager scheduling is handled by main.lua (passes poll function via schedule callback).
NO KOReader UI imports.

State keys published:
  - transferbridge.is_running  boolean
  - transferbridge.url         string or nil
--]]

local lfs    = require("libs/libkoreader-lfs")
local logger = require("logger")
local socket = require("socket")

local State = require("plugins/inkfire.koplugin/modules/state")

local TRANSFER_PORT    = 8765
local MAX_UPLOAD_BYTES = 500 * 1024 * 1024  -- 500 MB

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

-- ── Internal state ────────────────────────────────────────────────────────────

local _server    = nil
local _is_running = false
local _base_dir  = nil
local _plugin_dir = nil
local _status    = { files = {}, done = 0, errors = 0 }

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function getDeviceIP()
    local udp = socket.udp()
    if udp then
        udp:setpeername("8.8.8.8", 80)
        local ip = udp:getsockname()
        udp:close()
        if ip and ip ~= "0.0.0.0" then return ip end
    end
    return "127.0.0.1"
end

local function destPath(filename)
    local ext    = (filename:match("%.([^%.]+)$") or ""):lower()
    local subdir = EXT_TO_DIR["." .. ext] or "books"
    return ("%s/%s/%s"):format(_base_dir, subdir, filename)
end

local function isDuplicate(filename, data)
    local dest  = destPath(filename)
    local attrs = lfs.attributes(dest)
    return attrs and attrs.size == #data
end

local function saveFile(filename, data)
    if isDuplicate(filename, data) then
        return { filename = filename, status = "duplicate" }
    end
    local dest = destPath(filename)
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

local function ensureDirs()
    for _, subdir in pairs({ "manga", "books" }) do
        local p = _base_dir .. "/" .. subdir
        if not lfs.attributes(p, "mode") then lfs.mkdir(p) end
    end
end

-- ── JSON encoder ──────────────────────────────────────────────────────────────

local function jsonEncode(v)
    local t = type(v)
    if t == "nil"     then return "null"
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "number"  then return tostring(v)
    elseif t == "string"  then
        return '"' .. v:gsub('\\','\\\\'):gsub('"','\\"')
                        :gsub('\n','\\n'):gsub('\r','\\r') .. '"'
    elseif t == "table" then
        local is_array = (#v > 0)
        if is_array then
            local a = {}
            for _, item in ipairs(v) do table.insert(a, jsonEncode(item)) end
            return "[" .. table.concat(a, ",") .. "]"
        else
            local o = {}
            for k, val in pairs(v) do
                table.insert(o, jsonEncode(tostring(k)) .. ":" .. jsonEncode(val))
            end
            return "{" .. table.concat(o, ",") .. "}"
        end
    end
    return "null"
end

-- ── HTTP reply ────────────────────────────────────────────────────────────────

local STATUS_TEXT = {
    [200] = "OK", [400] = "Bad Request",
    [404] = "Not Found", [413] = "Payload Too Large",
}

local function reply(client, code, ctype, body)
    client:send(table.concat({
        ("HTTP/1.1 %d %s"):format(code, STATUS_TEXT[code] or "Error"),
        ("Content-Type: %s"):format(ctype),
        ("Content-Length: %d"):format(#body),
        "Access-Control-Allow-Origin: *",
        "Connection: close",
        "", body,
    }, "\r\n"))
end

-- ── Multipart parser ──────────────────────────────────────────────────────────

local function parseMultipart(body, boundary)
    local parts = {}
    local delim = "--" .. boundary
    local pos   = 1

    while true do
        local ds, de = body:find(delim, pos, true)
        if not ds then break end
        if body:sub(de + 1, de + 2) == "--" then break end

        local chunk_start = de + 1
        if body:sub(chunk_start, chunk_start + 1) == "\r\n" then
            chunk_start = chunk_start + 2
        end

        local ne = body:find(delim, chunk_start, true)
        if not ne then break end

        local chunk = body:sub(chunk_start, ne - 3)
        local hend  = chunk:find("\r\n\r\n", 1, true)
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

-- ── HTTP handlers ─────────────────────────────────────────────────────────────

local function serveHTML(client)
    local path = _plugin_dir .. "/ui/dropzone.html"
    local f    = io.open(path, "r")
    local body = f and f:read("*a") or "<h1>TransferBridge — UI missing</h1>"
    if f then f:close() end
    local url  = ("http://%s:%d"):format(getDeviceIP(), TRANSFER_PORT)
    body = body:gsub("__DEVICE_URL__", url)
    reply(client, 200, "text/html; charset=utf-8", body)
end

local function serveStatus(client)
    reply(client, 200, "application/json", jsonEncode(_status))
end

local function handleUpload(client, headers)
    local clen  = tonumber(headers["content-length"]) or 0
    local ctype = headers["content-type"] or ""

    if clen > MAX_UPLOAD_BYTES then
        reply(client, 413, "application/json", '{"error":"file too large"}')
        return
    end

    local boundary = ctype:match('boundary="([^"]+)"') or ctype:match("boundary=([^\r\n;%s]+)")
    if not boundary then
        reply(client, 400, "application/json", '{"error":"missing boundary"}')
        return
    end

    local chunks   = {}
    local received = 0
    while received < clen do
        local chunk = client:receive(math.min(65536, clen - received))
        if not chunk then break end
        table.insert(chunks, chunk)
        received = received + #chunk
    end
    if received < clen then
        reply(client, 400, "application/json", '{"error":"incomplete upload"}')
        return
    end
    local body = table.concat(chunks)

    local results = {}
    for _, part in ipairs(parseMultipart(body, boundary)) do
        local res = saveFile(part.filename, part.data)
        table.insert(results, res)
        if res.status == "ok" then
            _status.done = _status.done + 1
            table.insert(_status.files, { name = part.filename, status = "ok" })
        else
            _status.errors = _status.errors + 1
            table.insert(_status.files, { name = part.filename, status = res.status })
        end
    end

    if #results > 0 then
        -- Signal main.lua to refresh the file manager
        State.set("transferbridge.refresh_needed", true)
    end
    reply(client, 200, "application/json", jsonEncode({ results = results }))
end

local function dispatch(client)
    local req_line = client:receive("*l")
    if not req_line then return end

    local method, path = req_line:match("^(%u+) ([^%s]+)")
    if not method then return end

    local headers = {}
    while true do
        local line = client:receive("*l")
        if not line or line == "" then break end
        local k, v = line:match("^([^:]+):%s*(.+)$")
        if k then headers[k:lower()] = v end
    end

    if     method == "GET"  and path == "/"           then serveHTML(client)
    elseif method == "GET"  and path == "/api/status" then serveStatus(client)
    elseif method == "POST" and path == "/api/upload" then handleUpload(client, headers)
    else   reply(client, 404, "text/plain", "Not found")
    end
end

-- ── Public API ────────────────────────────────────────────────────────────────

local TransferBridge = {}

--- Start the HTTP server.
--- plugin_dir: path to inkfire.koplugin (for serving dropzone.html).
--- Returns { url } on success, or { error } on failure.
function TransferBridge.start(plugin_dir, base_dir)
    if _is_running then
        return { url = ("http://%s:%d"):format(getDeviceIP(), TRANSFER_PORT) }
    end

    _plugin_dir = plugin_dir
    _base_dir   = base_dir or "/mnt/onboard"
    if not lfs.attributes(_base_dir, "mode") then
        local ok, DS = pcall(require, "datastorage")
        _base_dir = ok and DS:getDataDir() or "/tmp"
    end

    local srv, err = socket.bind("*", TRANSFER_PORT)
    if not srv then
        logger.warn("TransferBridge: bind failed:", err)
        return { error = tostring(err) }
    end

    srv:settimeout(0)
    _server    = srv
    _is_running = true
    _status    = { files = {}, done = 0, errors = 0 }

    ensureDirs()

    local url = ("http://%s:%d"):format(getDeviceIP(), TRANSFER_PORT)
    State.set("transferbridge.is_running", true)
    State.set("transferbridge.url",        url)

    logger.dbg("TransferBridge: started on", url)
    return { url = url }
end

--- Stop the server.
function TransferBridge.stop()
    if not _is_running then return end
    _is_running = false
    if _server then
        _server:close()
        _server = nil
    end
    State.set("transferbridge.is_running", false)
    State.set("transferbridge.url",        nil)
    logger.dbg("TransferBridge: stopped")
end

--- Poll for one incoming connection (non-blocking). Call via UIManager:scheduleIn.
--- Returns true if a connection was handled.
function TransferBridge.poll()
    if not _is_running or not _server then return false end

    local client = _server:accept()
    if client then
        client:settimeout(120)
        local ok, err = pcall(dispatch, client)
        if not ok then logger.warn("TransferBridge dispatch error:", err) end
        client:close()
        return true
    end
    return false
end

--- Returns current device IP string.
function TransferBridge.getDeviceIP()
    return getDeviceIP()
end

--- Returns current running state.
function TransferBridge.isRunning()
    return _is_running
end

--- Returns current transfer status { files, done, errors }.
function TransferBridge.getStatus()
    return _status
end

return TransferBridge
