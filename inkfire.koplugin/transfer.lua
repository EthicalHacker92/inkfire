--[[
InkFire — transfer.lua
WiFi drop: a tiny non-blocking HTTP server on :8765. Open the URL on any
device on your network, drop files, they land sorted — manga/ for comics,
books/ for everything else. Logic only; main.lua schedules poll().
--]]

local lfs    = require("libs/libkoreader-lfs")
local logger = require("logger")
local socket = require("socket")

local PORT      = 8765
local MAX_BYTES = 500 * 1024 * 1024

local EXT_DIR = {
    cbz = "manga", cbr = "manga", cb7 = "manga",
    epub = "books", mobi = "books", azw = "books", azw3 = "books",
    fb2 = "books", pdf = "books", txt = "books", zip = "books",
}

local Transfer = {}

local _server, _running = nil, false
local _base = "/mnt/onboard"
local _done, _errors = 0, 0

local PAGE = [[
<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>InkFire Drop</title><style>
:root{color-scheme:light dark}
body{font:16px/1.5 -apple-system,system-ui,sans-serif;max-width:480px;
margin:8vh auto;padding:0 20px;text-align:center}
h1{font-size:22px;letter-spacing:.02em}
#z{border:2px dashed #888;border-radius:16px;padding:56px 20px;margin:24px 0;
cursor:pointer;transition:.15s}
#z.over{border-color:#e25822;background:rgba(226,88,34,.07)}
#log{text-align:left;font-size:14px;color:#666}
small{color:#888}</style></head><body>
<h1>&#x1F525; InkFire Drop</h1>
<div id="z">Drop books or manga here<br><small>cbz &middot; epub &middot; pdf &middot; mobi</small>
<input type="file" id="f" multiple style="display:none"></div>
<div id="log"></div>
<script>
const z=document.getElementById('z'),f=document.getElementById('f'),
log=document.getElementById('log');
z.onclick=()=>f.click();
z.ondragover=e=>{e.preventDefault();z.classList.add('over')};
z.ondragleave=()=>z.classList.remove('over');
z.ondrop=e=>{e.preventDefault();z.classList.remove('over');send(e.dataTransfer.files)};
f.onchange=()=>send(f.files);
async function send(files){
for(const file of files){
const line=document.createElement('div');line.textContent='↑ '+file.name+' …';
log.prepend(line);
const fd=new FormData();fd.append('file',file,file.name);
try{const r=await fetch('/upload',{method:'POST',body:fd});
const j=await r.json();
line.textContent=(j.status==='ok'?'✓ ':'⚠ ')+file.name+
(j.status==='duplicate'?' (already on device)':'');
}catch(e){line.textContent='✗ '+file.name}}}
</script></body></html>
]]

-- ── helpers ───────────────────────────────────────────────────────────────────

local function destFor(filename)
    local ext = (filename:match("%.([^%.]+)$") or ""):lower()
    local sub = EXT_DIR[ext] or "books"
    return ("%s/%s/%s"):format(_base, sub, filename), sub
end

local function ensureDirs()
    for _, d in pairs({ "manga", "books" }) do
        local p = _base .. "/" .. d
        if not lfs.attributes(p, "mode") then lfs.mkdir(p) end
    end
end

local function reply(client, code, ctype, body)
    local names = { [200] = "OK", [400] = "Bad Request", [404] = "Not Found",
                    [413] = "Payload Too Large" }
    client:send(table.concat({
        ("HTTP/1.1 %d %s"):format(code, names[code] or "Error"),
        "Content-Type: " .. ctype,
        "Content-Length: " .. #body,
        "Connection: close", "", body,
    }, "\r\n"))
end

local function parseMultipart(body, boundary)
    local parts, delim, pos = {}, "--" .. boundary, 1
    while true do
        local ds, de = body:find(delim, pos, true)
        if not ds then break end
        if body:sub(de + 1, de + 2) == "--" then break end
        local cs = de + 1
        if body:sub(cs, cs + 1) == "\r\n" then cs = cs + 2 end
        local ne = body:find(delim, cs, true)
        if not ne then break end
        local chunk = body:sub(cs, ne - 3)
        local hend = chunk:find("\r\n\r\n", 1, true)
        if hend then
            local hdr, data = chunk:sub(1, hend - 1), chunk:sub(hend + 4)
            local filename = hdr:match('filename="([^"]+)"')
            if filename and #data > 0 then
                parts[#parts + 1] = { filename = filename, data = data }
            end
        end
        pos = ne
    end
    return parts
end

local function saveFile(filename, data)
    local dest = destFor(filename)
    local attrs = lfs.attributes(dest)
    if attrs and attrs.size == #data then
        return { filename = filename, status = "duplicate" }
    end
    local f, err = io.open(dest, "wb")
    if not f then return { filename = filename, status = "error", message = tostring(err) } end
    f:write(data)
    f:close()
    return { filename = filename, status = "ok" }
end

local function handleUpload(client, headers)
    local clen = tonumber(headers["content-length"]) or 0
    if clen > MAX_BYTES then
        reply(client, 413, "application/json", '{"status":"error"}')
        return
    end
    local boundary = (headers["content-type"] or ""):match('boundary="?([^"\r\n;]+)"?')
    if not boundary then
        reply(client, 400, "application/json", '{"status":"error"}')
        return
    end
    local chunks, got = {}, 0
    while got < clen do
        local chunk = client:receive(math.min(65536, clen - got))
        if not chunk then break end
        chunks[#chunks + 1] = chunk
        got = got + #chunk
    end
    if got < clen then
        reply(client, 400, "application/json", '{"status":"error"}')
        return
    end
    local result = { status = "error" }
    for _, part in ipairs(parseMultipart(table.concat(chunks), boundary)) do
        result = saveFile(part.filename, part.data)
        if result.status == "ok" then _done = _done + 1
        elseif result.status ~= "duplicate" then _errors = _errors + 1 end
    end
    reply(client, 200, "application/json",
        ('{"status":"%s"}'):format(result.status))
end

local function dispatch(client)
    local req = client:receive("*l")
    if not req then return end
    local method, path = req:match("^(%u+) ([^%s]+)")
    if not method then return end
    local headers = {}
    while true do
        local line = client:receive("*l")
        if not line or line == "" then break end
        local k, v = line:match("^([^:]+):%s*(.+)$")
        if k then headers[k:lower()] = v end
    end
    if method == "GET" and path == "/" then
        reply(client, 200, "text/html; charset=utf-8", PAGE)
    elseif method == "POST" and path == "/upload" then
        handleUpload(client, headers)
    else
        reply(client, 404, "text/plain", "not found")
    end
end

-- ── public API ────────────────────────────────────────────────────────────────

function Transfer.deviceIP()
    local udp = socket.udp()
    if udp then
        udp:setpeername("8.8.8.8", 80)
        local ip = udp:getsockname()
        udp:close()
        if ip and ip ~= "0.0.0.0" then return ip end
    end
    return nil
end

--- Returns { url } or { error }.
function Transfer.start(base_dir)
    if _running then
        return { url = ("http://%s:%d"):format(Transfer.deviceIP() or "?", PORT) }
    end
    _base = base_dir or "/mnt/onboard"
    if not lfs.attributes(_base, "mode") then
        local ok, DS = pcall(require, "datastorage")
        _base = ok and DS:getDataDir() or "/tmp"
    end
    local srv, err = socket.bind("*", PORT)
    if not srv then
        logger.warn("InkFire transfer bind failed:", err)
        return { error = tostring(err) }
    end
    srv:settimeout(0)
    _server, _running = srv, true
    _done, _errors = 0, 0
    pcall(ensureDirs)
    local ip = Transfer.deviceIP()
    if not ip then
        Transfer.stop()
        return { error = "no network" }
    end
    return { url = ("http://%s:%d"):format(ip, PORT) }
end

function Transfer.stop()
    _running = false
    if _server then _server:close(); _server = nil end
end

function Transfer.isRunning() return _running end
function Transfer.counts() return _done, _errors end

--- Handle at most a few pending connections; returns true if any handled.
function Transfer.poll()
    if not _running or not _server then return false end
    local handled = false
    for _ = 1, 4 do
        local client = _server:accept()
        if not client then break end
        handled = true
        client:settimeout(120)
        local ok, err = pcall(dispatch, client)
        if not ok then logger.warn("InkFire transfer dispatch:", err) end
        client:close()
    end
    return handled
end

return Transfer
