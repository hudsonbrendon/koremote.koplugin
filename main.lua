local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Device = require("device")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local DataStorage = require("datastorage")
local socket = require("socket")
local rapidjson = require("rapidjson")

local Router = require("router")
local Httpd = require("httpd")
local Discovery = require("discovery")
local api = require("koreader_api")
local Status = require("handlers.status")
local Book = require("handlers.book")
local Library = require("handlers.library")
local Control = require("handlers.control")

local meta = require("_meta")

local KoRemote = WidgetContainer:extend{
    name = "koremote",
    is_doc_only = false,
}

-- Module-level singleton server state. KOReader creates a fresh plugin instance for
-- each UI (FileManager / ReaderUI) and tears the old one down on every document
-- switch. Keeping the server here — not on `self` — lets it survive those switches,
-- so the control API stays up while you navigate or change books.
local S = { running = false }

-- Forward declarations so start/stop can reference each other.
local start_server, stop_server

local function load_settings()
    local path = DataStorage:getSettingsDir() .. "/koremote_settings.lua"
    local ok, cfg = pcall(dofile, path)
    if ok and type(cfg) == "table" and cfg.token and cfg.token ~= "" then
        return cfg
    end
    return nil
end

-- On Kindle the firewall's INPUT policy is DROP, so a listening server is
-- unreachable until we punch a hole for its ports (mirrors KOReader's SSH plugin).
-- action is "open" (-A, append) or "close" (-D, delete).
local function firewall(action, cfg)
    if not Device:isKindle() then return end
    local d = action == "open" and "-A" or "-D"
    os.execute(string.format(
        "iptables %s INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT",
        d, cfg.http_port))
    os.execute(string.format(
        "iptables %s OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT",
        d, cfg.http_port))
    os.execute(string.format("iptables %s INPUT -p udp --dport %d -j ACCEPT", d, cfg.discovery_port))
    os.execute(string.format("iptables %s OUTPUT -p udp --sport %d -j ACCEPT", d, cfg.discovery_port))
end

local function build_router(cfg)
    local r = Router.new({ token = cfg.token })
    r:add("GET",  "/status",             function(req) return Status.get(api, req) end)
    r:add("GET",  "/book",               function(req) return Book.get(api, req) end)
    r:add("GET",  "/book/cover",         function(req) return Book.cover(api, req) end)
    r:add("GET",  "/library",            function(req) return Library.list(api, req) end)
    r:add("POST", "/open",               function(req) return Library.open(api, req) end)
    r:add("POST", "/control/page",       function(req) return Control.page(api, req) end)
    r:add("POST", "/control/frontlight", function(req) return Control.frontlight(api, req) end)
    r:add("POST", "/control/screenshot", function(req) return Control.screenshot(api, req) end)
    r:add("POST", "/control/refresh",    function(req) return Control.refresh(api, req) end)
    return r
end

-- Determine our LAN IP on the interface that routes toward peer_ip.
-- A connected UDP socket performs no I/O but resolves the local address.
local function local_ip_towards(peer_ip)
    local probe = socket.udp()
    local ok = probe:setpeername(peer_ip, 9)
    local ip = ok and probe:getsockname() or nil
    probe:close()
    return ip or "0.0.0.0"
end

-- Accept one pending TCP connection (non-blocking) and serve it.
local function serve_once()
    if not S.server then return end
    local client = S.server:accept()
    if not client then return end
    client:settimeout(2)
    local request_line = client:receive("*l")
    if request_line then
        local headers_done, content_length = false, 0
        local buf = { request_line }
        while not headers_done do
            local line = client:receive("*l")
            if not line or line == "" then
                headers_done = true
            else
                buf[#buf + 1] = line
                local cl = line:lower():match("^content%-length:%s*(%d+)")
                if cl then content_length = tonumber(cl) end
            end
        end
        local body = ""
        if content_length > 0 then
            body = client:receive(content_length) or ""
        end
        local request_text = table.concat(buf, "\r\n") .. "\r\n\r\n" .. body
        local req = Httpd.parse_request(request_text)
        if req.body and req.body ~= "" then
            local ok, decoded = pcall(rapidjson.decode, req.body)
            req.body = ok and decoded or nil
        else
            req.body = nil
        end
        local res = S.router:dispatch(req)
        client:send(Httpd.build_response(res, rapidjson.encode))
    end
    client:close()
end

-- Answer one pending UDP discovery probe (non-blocking).
local function discover_once()
    if not S.disco then return end
    local data, ip, port = S.disco:receivefrom()
    if data then
        local reply = Discovery.handle_packet(data, {
            name = S.cfg.name or "KOReader",
            ip = local_ip_towards(ip),
            port = S.cfg.http_port,
            version = meta.version,
        }, rapidjson.encode)
        if reply then S.disco:sendto(reply, ip, port) end
    end
end

local function poll()
    if not S.running then return end
    serve_once()
    discover_once()
    UIManager:scheduleIn(0.2, poll)
end

-- Start the singleton server. Idempotent. Returns ok(boolean), err(string|nil).
start_server = function()
    if S.running then return true end
    local cfg = load_settings()
    if not cfg then return false, "no token set in koremote_settings.lua" end
    S.cfg = cfg
    S.router = build_router(cfg)

    -- Bind both sockets under pcall so a port conflict (e.g. another server
    -- already on http_port) reports an error instead of crashing KOReader.
    local ok, err = pcall(function()
        S.server = assert(socket.tcp())
        S.server:setoption("reuseaddr", true)
        assert(S.server:bind("*", cfg.http_port))
        S.server:listen(4)
        S.server:settimeout(0)

        S.disco = assert(socket.udp())
        S.disco:setoption("reuseaddr", true)
        assert(S.disco:setsockname("*", cfg.discovery_port))
        S.disco:settimeout(0)
    end)
    if not ok then
        stop_server()
        return false, tostring(err)
    end

    firewall("open", cfg)
    S.fw_open = true
    S.running = true
    poll()
    return true
end

-- Stop the singleton server and release its firewall hole. Idempotent.
stop_server = function()
    S.running = false
    if S.server then S.server:close(); S.server = nil end
    if S.disco then S.disco:close(); S.disco = nil end
    if S.fw_open and S.cfg then
        firewall("close", S.cfg)
        S.fw_open = false
    end
end

-- Auto-start the server on plugin load when the settings opt in (autostart=true),
-- so the control server comes up without a manual menu tap (e.g. after a reboot).
-- No-op if the singleton is already running (e.g. after a document switch).
function KoRemote:init()
    if S.running then return end
    local cfg = load_settings()
    if cfg and cfg.autostart then
        UIManager:nextTick(function() start_server() end)
    end
end

function KoRemote:addToMainMenu(menu_items)
    menu_items.koremote = {
        text = "KO Remote",
        sub_item_table = {
            {
                text = "Start server",
                callback = function()
                    local ok, err = start_server()
                    UIManager:show(InfoMessage:new{
                        text = ok
                            and string.format("KO Remote on :%d", S.cfg.http_port)
                            or ("KO Remote failed to start: " .. tostring(err)) })
                end,
            },
            {
                text = "Stop server",
                callback = function()
                    stop_server()
                    UIManager:show(InfoMessage:new{ text = "KO Remote stopped." })
                end,
            },
        },
    }
end

return KoRemote
