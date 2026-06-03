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
local function serve_once(self)
    if not self.server then return end
    local client = self.server:accept()
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
        local res = self.router:dispatch(req)
        client:send(Httpd.build_response(res, rapidjson.encode))
    end
    client:close()
end

-- Answer one pending UDP discovery probe (non-blocking).
local function discover_once(self)
    if not self.disco then return end
    local data, ip, port = self.disco:receivefrom()
    if data then
        local reply = Discovery.handle_packet(data, {
            name = self.cfg.name or "KOReader",
            ip = local_ip_towards(ip),
            port = self.cfg.http_port,
            version = meta.version,
        }, rapidjson.encode)
        if reply then self.disco:sendto(reply, ip, port) end
    end
end

function KoRemote:_poll()
    serve_once(self)
    discover_once(self)
    if self.running then
        UIManager:scheduleIn(0.2, function() self:_poll() end)
    end
end

function KoRemote:start()
    if self.running then return end
    self.cfg = load_settings()
    if not self.cfg then
        UIManager:show(InfoMessage:new{
            text = "KO Remote: set a token in koremote_settings.lua first." })
        return
    end
    self.router = build_router(self.cfg)

    -- Bind both sockets under pcall so a port conflict (e.g. another server
    -- already on http_port) reports an error instead of crashing KOReader.
    local ok, err = pcall(function()
        self.server = assert(socket.tcp())
        self.server:setoption("reuseaddr", true)
        assert(self.server:bind("*", self.cfg.http_port))
        self.server:listen(4)
        self.server:settimeout(0)

        self.disco = assert(socket.udp())
        self.disco:setoption("reuseaddr", true)
        assert(self.disco:setsockname("*", self.cfg.discovery_port))
        self.disco:settimeout(0)
    end)
    if not ok then
        self:stop()
        UIManager:show(InfoMessage:new{
            text = "KO Remote failed to start: " .. tostring(err) })
        return
    end

    firewall("open", self.cfg)
    self.fw_open = true
    self.running = true
    self:_poll()
    UIManager:show(InfoMessage:new{
        text = string.format("KO Remote on :%d", self.cfg.http_port) })
end

function KoRemote:stop()
    self.running = false
    if self.server then self.server:close(); self.server = nil end
    if self.disco then self.disco:close(); self.disco = nil end
    if self.fw_open and self.cfg then
        firewall("close", self.cfg)
        self.fw_open = false
    end
end

-- Auto-start the server on plugin load when the settings opt in (autostart=true),
-- so the control server comes up without a manual menu tap (e.g. after a reboot).
function KoRemote:init()
    local cfg = load_settings()
    if cfg and cfg.autostart then
        UIManager:nextTick(function() self:start() end)
    end
end

function KoRemote:addToMainMenu(menu_items)
    menu_items.koremote = {
        text = "KO Remote",
        sub_item_table = {
            {
                text = "Start server",
                callback = function() self:start() end,
            },
            {
                text = "Stop server",
                callback = function() self:stop() end,
            },
        },
    }
end

function KoRemote:onCloseWidget()
    self:stop()
end

return KoRemote
