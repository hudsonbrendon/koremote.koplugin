# koremote.koplugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a KOReader plugin that runs a token-authed HTTP REST control API + UDP discovery responder on the e-reader, so a Nintendo Switch companion app (separate project) can read device/book info and remote-control the reader.

**Architecture:** Pure, injectable Lua modules (router, request parser, discovery, handlers) that are fully unit-tested with a fake KOReader adapter, plus one thin `koreader_api.lua` adapter that is the only file touching KOReader globals and is verified by an on-device smoke test. `main.lua` wires the TCP/UDP servers into KOReader's UIManager loop.

**Tech Stack:** Lua 5.1 / LuaJIT (KOReader runtime), bundled `rapidjson` + LuaSocket, `busted` for tests (mirrors the existing `hatelemetry.koplugin` setup).

---

## File Structure

| File | Responsibility | Unit-tested? |
|---|---|---|
| `_meta.lua` | Plugin metadata (name, version) | n/a |
| `.busted` | Busted config | n/a |
| `router.lua` | Bearer-token auth + method/path → handler dispatch | yes |
| `httpd.lua` | Parse raw HTTP request; build HTTP response string | yes |
| `discovery.lua` | UDP discovery packet handling | yes |
| `handlers/status.lua` | `GET /status` | yes (fake api) |
| `handlers/book.lua` | `GET /book`, `GET /book/cover` | yes (fake api) |
| `handlers/library.lua` | `GET /library`, `POST /open` | yes (fake api) |
| `handlers/control.lua` | `POST /control/page|frontlight|screenshot|refresh` | yes (fake api) |
| `koreader_api.lua` | Adapter over KOReader globals; pure `format_history` helper | partial (helper unit-tested; globals smoke-tested) |
| `main.lua` | Plugin lifecycle + TCP/UDP server loop wired into UIManager | smoke-tested on device |

**Key seam:** every handler is a plain function `handler(api, req) -> res`. Tests pass a fake `api`; production passes `koreader_api`. This keeps all request logic testable without a device.

**Shared types** (used across tasks — keep names identical):
- `req` = `{ method=string, path=string, query={[k]=string}, headers={[lower_k]=string}, body=table|nil }`
- `res` = `{ status=number, json=table|nil, body=string|nil, content_type=string|nil }`
- `api` = table of functions: `battery()`, `is_charging()`, `version()`, `model()`, `storage_free()`, `wifi_on()`, `current_book()`, `cover_png()`, `library(limit, q)`, `open_book(path)`, `turn_page(dir)`, `set_frontlight(brightness, warmth)`, `screenshot_png()`, `refresh()`.

---

## Task 1: Project scaffold

**Files:**
- Create: `_meta.lua`
- Create: `.busted`
- Create: `spec/scaffold_spec.lua`

- [ ] **Step 1: Write the failing test**

Create `spec/scaffold_spec.lua`:

```lua
local meta = require("_meta")

describe("plugin metadata", function()
    it("declares a name and a version", function()
        assert.are.equal("koremote", meta.name)
        assert.is_truthy(meta.version)
    end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted spec/scaffold_spec.lua`
Expected: FAIL — `module '_meta' not found` (and `.busted` config missing).

- [ ] **Step 3: Write minimal implementation**

Create `.busted`:

```lua
return {
    default = {
        lpath = "./?.lua;./?/init.lua",
        pattern = "_spec",
    },
}
```

Create `_meta.lua`:

```lua
return {
    name = "koremote",
    fullname = "KO Remote",
    description = "HTTP REST control API + UDP discovery so a companion app can read device/book info and remote-control KOReader.",
    version = "v0.1.0",
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `busted`
Expected: PASS — `1 success / 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add _meta.lua .busted spec/scaffold_spec.lua
git commit -m "chore: scaffold koremote plugin metadata and busted config"
```

---

## Task 2: Router (auth + dispatch)

**Files:**
- Create: `router.lua`
- Test: `spec/router_spec.lua`

- [ ] **Step 1: Write the failing test**

Create `spec/router_spec.lua`:

```lua
local Router = require("router")

local function make()
    local r = Router.new({ token = "SECRET" })
    r:add("GET", "/ping", function(req) return { status = 200, json = { pong = true } } end)
    return r
end

describe("Router auth", function()
    it("rejects a missing token with 401", function()
        local res = make():dispatch({ method = "GET", path = "/ping", headers = {} })
        assert.are.equal(401, res.status)
    end)
    it("rejects a wrong token with 401", function()
        local res = make():dispatch({ method = "GET", path = "/ping",
            headers = { ["authorization"] = "Bearer NOPE" } })
        assert.are.equal(401, res.status)
    end)
    it("accepts the correct bearer token", function()
        local res = make():dispatch({ method = "GET", path = "/ping",
            headers = { ["authorization"] = "Bearer SECRET" } })
        assert.are.equal(200, res.status)
        assert.is_true(res.json.pong)
    end)
end)

describe("Router dispatch", function()
    it("returns 404 for an unknown route", function()
        local res = make():dispatch({ method = "GET", path = "/nope",
            headers = { ["authorization"] = "Bearer SECRET" } })
        assert.are.equal(404, res.status)
    end)
    it("passes the request through to the handler", function()
        local r = Router.new({ token = "T" })
        local seen
        r:add("POST", "/echo", function(req) seen = req; return { status = 200 } end)
        r:dispatch({ method = "POST", path = "/echo",
            headers = { ["authorization"] = "Bearer T" }, body = { a = 1 } })
        assert.are.equal(1, seen.body.a)
    end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted spec/router_spec.lua`
Expected: FAIL — `module 'router' not found`.

- [ ] **Step 3: Write minimal implementation**

Create `router.lua`:

```lua
local Router = {}
Router.__index = Router

function Router.new(opts)
    return setmetatable({ token = opts.token, routes = {} }, Router)
end

function Router:add(method, path, handler)
    self.routes[method .. " " .. path] = handler
end

local function authorized(self, req)
    local h = req.headers and (req.headers["authorization"] or req.headers["Authorization"])
    return h == "Bearer " .. self.token
end

function Router:dispatch(req)
    if not authorized(self, req) then
        return { status = 401, json = { error = "unauthorized" } }
    end
    local handler = self.routes[req.method .. " " .. req.path]
    if not handler then
        return { status = 404, json = { error = "not found" } }
    end
    return handler(req)
end

return Router
```

- [ ] **Step 4: Run test to verify it passes**

Run: `busted spec/router_spec.lua`
Expected: PASS — `5 successes / 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add router.lua spec/router_spec.lua
git commit -m "feat: router with bearer-token auth and path dispatch"
```

---

## Task 3: Httpd (request parse + response build)

**Files:**
- Create: `httpd.lua`
- Test: `spec/httpd_spec.lua`

- [ ] **Step 1: Write the failing test**

Create `spec/httpd_spec.lua`:

```lua
local Httpd = require("httpd")

describe("Httpd.parse_request", function()
    it("parses method, path, query and headers", function()
        local raw = "GET /library?limit=5&q=dune HTTP/1.1\r\n" ..
                    "Host: reader.local\r\nAuthorization: Bearer T\r\n\r\n"
        local req = Httpd.parse_request(raw)
        assert.are.equal("GET", req.method)
        assert.are.equal("/library", req.path)
        assert.are.equal("5", req.query.limit)
        assert.are.equal("dune", req.query.q)
        assert.are.equal("Bearer T", req.headers["authorization"])
    end)

    it("parses a POST body", function()
        local raw = "POST /open HTTP/1.1\r\nContent-Length: 9\r\n\r\n{\"x\":\"y\"}"
        local req = Httpd.parse_request(raw)
        assert.are.equal("POST", req.method)
        assert.are.equal("/open", req.path)
        assert.are.equal('{"x":"y"}', req.body)
    end)
end)

describe("Httpd.build_response", function()
    local function enc(t) return '{"ok":true}' end

    it("serializes a json response with content-type and length", function()
        local out = Httpd.build_response({ status = 200, json = { ok = true } }, enc)
        assert.is_truthy(out:find("HTTP/1.1 200 OK", 1, true))
        assert.is_truthy(out:find("Content-Type: application/json", 1, true))
        assert.is_truthy(out:find("Content-Length: 11", 1, true))
        assert.is_truthy(out:find('{"ok":true}', 1, true))
    end)

    it("serializes a raw body with a custom content-type", function()
        local out = Httpd.build_response(
            { status = 200, body = "PNGDATA", content_type = "image/png" }, enc)
        assert.is_truthy(out:find("Content-Type: image/png", 1, true))
        assert.is_truthy(out:find("PNGDATA", 1, true))
    end)

    it("emits 204 with an empty body", function()
        local out = Httpd.build_response({ status = 204 }, enc)
        assert.is_truthy(out:find("HTTP/1.1 204 No Content", 1, true))
        assert.is_truthy(out:find("Content-Length: 0", 1, true))
    end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted spec/httpd_spec.lua`
Expected: FAIL — `module 'httpd' not found`.

- [ ] **Step 3: Write minimal implementation**

Create `httpd.lua`:

```lua
local Httpd = {}

local STATUS_TEXT = {
    [200] = "OK", [204] = "No Content", [400] = "Bad Request",
    [401] = "Unauthorized", [404] = "Not Found",
}

local function parse_query(qs)
    local q = {}
    for k, v in (qs or ""):gmatch("([^&=]+)=([^&=]+)") do
        q[k] = v
    end
    return q
end

-- raw: full HTTP request string. Returns a req table.
function Httpd.parse_request(raw)
    local head, body = raw:match("^(.-)\r\n\r\n(.*)$")
    head = head or raw
    body = body or ""
    local lines = {}
    for line in (head .. "\r\n"):gmatch("(.-)\r\n") do
        lines[#lines + 1] = line
    end
    local method, target = (lines[1] or ""):match("^(%u+)%s+(%S+)")
    local path, qs = (target or ""):match("^([^?]*)%??(.*)$")
    local headers = {}
    for i = 2, #lines do
        local k, v = lines[i]:match("^(.-):%s*(.*)$")
        if k then headers[k:lower()] = v end
    end
    return {
        method = method,
        path = path,
        query = parse_query(qs),
        headers = headers,
        body = body,
    }
end

-- res: a res table. json_encode: function(table) -> string. Returns the HTTP response string.
function Httpd.build_response(res, json_encode)
    local body, ctype
    if res.json ~= nil then
        body = json_encode(res.json)
        ctype = "application/json"
    else
        body = res.body or ""
        ctype = res.content_type or "text/plain"
    end
    local text = STATUS_TEXT[res.status] or "OK"
    return string.format(
        "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
        res.status, text, ctype, #body, body)
end

return Httpd
```

- [ ] **Step 4: Run test to verify it passes**

Run: `busted spec/httpd_spec.lua`
Expected: PASS — `5 successes / 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add httpd.lua spec/httpd_spec.lua
git commit -m "feat: HTTP request parser and response builder"
```

---

## Task 4: Discovery (UDP packet handling)

**Files:**
- Create: `discovery.lua`
- Test: `spec/discovery_spec.lua`

- [ ] **Step 1: Write the failing test**

Create `spec/discovery_spec.lua`:

```lua
local Discovery = require("discovery")

local function enc(t)
    -- deterministic stub encoder for assertion
    return string.format('{"name":"%s","ip":"%s","port":%d,"version":"%s"}',
        t.name, t.ip, t.port, t.version)
end

describe("Discovery.handle_packet", function()
    local info = { name = "Kindle", ip = "192.168.1.50", port = 8080, version = "v0.1.0" }

    it("replies to the discovery probe", function()
        local reply = Discovery.handle_packet("KOREMOTE?", info, enc)
        assert.are.equal('{"name":"Kindle","ip":"192.168.1.50","port":8080,"version":"v0.1.0"}', reply)
    end)

    it("ignores unrelated packets", function()
        assert.is_nil(Discovery.handle_packet("hello", info, enc))
        assert.is_nil(Discovery.handle_packet("", info, enc))
    end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted spec/discovery_spec.lua`
Expected: FAIL — `module 'discovery' not found`.

- [ ] **Step 3: Write minimal implementation**

Create `discovery.lua`:

```lua
local Discovery = {}

Discovery.PROBE = "KOREMOTE?"

-- payload: bytes received on the UDP socket. info: {name, ip, port, version}.
-- json_encode: function(table) -> string. Returns a reply string or nil to ignore.
function Discovery.handle_packet(payload, info, json_encode)
    if payload ~= Discovery.PROBE then
        return nil
    end
    return json_encode({
        name = info.name,
        ip = info.ip,
        port = info.port,
        version = info.version,
    })
end

return Discovery
```

- [ ] **Step 4: Run test to verify it passes**

Run: `busted spec/discovery_spec.lua`
Expected: PASS — `2 successes / 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add discovery.lua spec/discovery_spec.lua
git commit -m "feat: UDP discovery probe handling"
```

---

## Task 5: Status handler

**Files:**
- Create: `handlers/status.lua`
- Test: `spec/handlers_status_spec.lua`

- [ ] **Step 1: Write the failing test**

Create `spec/handlers_status_spec.lua`:

```lua
local Status = require("handlers.status")

local fake_api = {
    battery = function() return 82 end,
    is_charging = function() return false end,
    version = function() return "2025.04" end,
    model = function() return "Kindle Oasis" end,
    storage_free = function() return 1234567 end,
    wifi_on = function() return true end,
}

describe("handlers/status GET", function()
    it("returns a 200 device-info snapshot", function()
        local res = Status.get(fake_api, { method = "GET", path = "/status" })
        assert.are.equal(200, res.status)
        assert.are.equal(82, res.json.battery)
        assert.is_false(res.json.charging)
        assert.are.equal("2025.04", res.json.version)
        assert.are.equal("Kindle Oasis", res.json.model)
        assert.are.equal(1234567, res.json.storage_free)
        assert.is_true(res.json.wifi)
    end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted spec/handlers_status_spec.lua`
Expected: FAIL — `module 'handlers.status' not found`.

- [ ] **Step 3: Write minimal implementation**

Create `handlers/status.lua`:

```lua
local Status = {}

-- api: the koreader adapter. req: the request table. Returns a res table.
function Status.get(api, req)
    return {
        status = 200,
        json = {
            battery = api.battery(),
            charging = api.is_charging(),
            version = api.version(),
            model = api.model(),
            storage_free = api.storage_free(),
            wifi = api.wifi_on(),
        },
    }
end

return Status
```

- [ ] **Step 4: Run test to verify it passes**

Run: `busted spec/handlers_status_spec.lua`
Expected: PASS — `1 success / 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add handlers/status.lua spec/handlers_status_spec.lua
git commit -m "feat: GET /status device-info handler"
```

---

## Task 6: Book handler (info + cover)

**Files:**
- Create: `handlers/book.lua`
- Test: `spec/handlers_book_spec.lua`

- [ ] **Step 1: Write the failing test**

Create `spec/handlers_book_spec.lua`:

```lua
local Book = require("handlers.book")

local function api_with(book, png)
    return {
        current_book = function() return book end,
        cover_png = function() return png end,
    }
end

describe("handlers/book GET /book", function()
    it("returns 200 with book fields when a book is open", function()
        local b = { title = "Dune", author = "Herbert", page = 42, pages = 600,
                    percent = 7, time_spent = 3600 }
        local res = Book.get(api_with(b), {})
        assert.are.equal(200, res.status)
        assert.are.equal("Dune", res.json.title)
        assert.are.equal(42, res.json.page)
        assert.are.equal(600, res.json.pages)
        assert.are.equal(7, res.json.percent)
    end)

    it("returns 204 when no book is open", function()
        local res = Book.get(api_with(nil), {})
        assert.are.equal(204, res.status)
        assert.is_nil(res.json)
    end)
end)

describe("handlers/book GET /book/cover", function()
    it("returns the cover png", function()
        local res = Book.cover(api_with(nil, "PNGBYTES"), {})
        assert.are.equal(200, res.status)
        assert.are.equal("image/png", res.content_type)
        assert.are.equal("PNGBYTES", res.body)
    end)

    it("returns 204 when there is no cover", function()
        local res = Book.cover(api_with(nil, nil), {})
        assert.are.equal(204, res.status)
    end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted spec/handlers_book_spec.lua`
Expected: FAIL — `module 'handlers.book' not found`.

- [ ] **Step 3: Write minimal implementation**

Create `handlers/book.lua`:

```lua
local Book = {}

function Book.get(api, req)
    local b = api.current_book()
    if not b then
        return { status = 204 }
    end
    return {
        status = 200,
        json = {
            title = b.title,
            author = b.author,
            page = b.page,
            pages = b.pages,
            percent = b.percent,
            time_spent = b.time_spent,
        },
    }
end

function Book.cover(api, req)
    local png = api.cover_png()
    if not png then
        return { status = 204 }
    end
    return { status = 200, body = png, content_type = "image/png" }
end

return Book
```

- [ ] **Step 4: Run test to verify it passes**

Run: `busted spec/handlers_book_spec.lua`
Expected: PASS — `4 successes / 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add handlers/book.lua spec/handlers_book_spec.lua
git commit -m "feat: GET /book and /book/cover handlers"
```

---

## Task 7: Library handler (list + open)

**Files:**
- Create: `handlers/library.lua`
- Test: `spec/handlers_library_spec.lua`

- [ ] **Step 1: Write the failing test**

Create `spec/handlers_library_spec.lua`:

```lua
local Library = require("handlers.library")

local function fake_api(opts)
    opts = opts or {}
    return {
        library = function(limit, q)
            return { { path = "/b/dune.epub", title = "Dune", author = "Herbert" } }
        end,
        open_book = function(path) return opts.exists ~= false end,
    }
end

describe("handlers/library GET /library", function()
    it("returns 200 with a list of books", function()
        local res = Library.list(fake_api(), { query = {} })
        assert.are.equal(200, res.status)
        assert.are.equal("Dune", res.json[1].title)
        assert.are.equal("/b/dune.epub", res.json[1].path)
    end)

    it("forwards limit and q to the adapter", function()
        local seen = {}
        local api = { library = function(limit, q) seen.limit = limit; seen.q = q; return {} end }
        Library.list(api, { query = { limit = "5", q = "du" } })
        assert.are.equal(5, seen.limit)
        assert.are.equal("du", seen.q)
    end)
end)

describe("handlers/library POST /open", function()
    it("opens an existing book", function()
        local res = Library.open(fake_api({ exists = true }), { body = { path = "/b/dune.epub" } })
        assert.are.equal(200, res.status)
        assert.is_true(res.json.ok)
    end)

    it("returns 400 when path is missing", function()
        local res = Library.open(fake_api(), { body = {} })
        assert.are.equal(400, res.status)
    end)

    it("returns 404 when the book does not exist", function()
        local res = Library.open(fake_api({ exists = false }), { body = { path = "/nope.epub" } })
        assert.are.equal(404, res.status)
    end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted spec/handlers_library_spec.lua`
Expected: FAIL — `module 'handlers.library' not found`.

- [ ] **Step 3: Write minimal implementation**

Create `handlers/library.lua`:

```lua
local Library = {}

function Library.list(api, req)
    local q = req.query or {}
    local limit = tonumber(q.limit)
    local items = api.library(limit, q.q)
    return { status = 200, json = items }
end

function Library.open(api, req)
    local path = req.body and req.body.path
    if not path or path == "" then
        return { status = 400, json = { error = "path required" } }
    end
    if not api.open_book(path) then
        return { status = 404, json = { error = "not found" } }
    end
    return { status = 200, json = { ok = true } }
end

return Library
```

- [ ] **Step 4: Run test to verify it passes**

Run: `busted spec/handlers_library_spec.lua`
Expected: PASS — `5 successes / 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add handlers/library.lua spec/handlers_library_spec.lua
git commit -m "feat: GET /library and POST /open handlers"
```

---

## Task 8: Control handler (page, frontlight, screenshot, refresh)

**Files:**
- Create: `handlers/control.lua`
- Test: `spec/handlers_control_spec.lua`

- [ ] **Step 1: Write the failing test**

Create `spec/handlers_control_spec.lua`:

```lua
local Control = require("handlers.control")

local function recording_api()
    local calls = {}
    return {
        calls = calls,
        turn_page = function(dir) calls.turn = dir end,
        set_frontlight = function(b, w) calls.fl = { b = b, w = w } end,
        screenshot_png = function() return "PNG" end,
        refresh = function() calls.refresh = true end,
    }
end

describe("handlers/control POST /control/page", function()
    it("turns the page forward", function()
        local api = recording_api()
        local res = Control.page(api, { body = { dir = "next" } })
        assert.are.equal(200, res.status)
        assert.are.equal("next", api.calls.turn)
    end)

    it("rejects an invalid direction with 400", function()
        local res = Control.page(recording_api(), { body = { dir = "sideways" } })
        assert.are.equal(400, res.status)
    end)
end)

describe("handlers/control POST /control/frontlight", function()
    it("forwards brightness and warmth", function()
        local api = recording_api()
        local res = Control.frontlight(api, { body = { brightness = 10, warmth = 3 } })
        assert.are.equal(200, res.status)
        assert.are.equal(10, api.calls.fl.b)
        assert.are.equal(3, api.calls.fl.w)
    end)
end)

describe("handlers/control POST /control/screenshot", function()
    it("returns a png", function()
        local res = Control.screenshot(recording_api(), {})
        assert.are.equal(200, res.status)
        assert.are.equal("image/png", res.content_type)
        assert.are.equal("PNG", res.body)
    end)
end)

describe("handlers/control POST /control/refresh", function()
    it("triggers a refresh", function()
        local api = recording_api()
        local res = Control.refresh(api, {})
        assert.are.equal(200, res.status)
        assert.is_true(api.calls.refresh)
    end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted spec/handlers_control_spec.lua`
Expected: FAIL — `module 'handlers.control' not found`.

- [ ] **Step 3: Write minimal implementation**

Create `handlers/control.lua`:

```lua
local Control = {}

function Control.page(api, req)
    local dir = req.body and req.body.dir
    if dir ~= "next" and dir ~= "prev" then
        return { status = 400, json = { error = "dir must be 'next' or 'prev'" } }
    end
    api.turn_page(dir)
    return { status = 200, json = { ok = true } }
end

function Control.frontlight(api, req)
    local b = req.body or {}
    api.set_frontlight(b.brightness, b.warmth)
    return { status = 200, json = { ok = true } }
end

function Control.screenshot(api, req)
    return { status = 200, body = api.screenshot_png(), content_type = "image/png" }
end

function Control.refresh(api, req)
    api.refresh()
    return { status = 200, json = { ok = true } }
end

return Control
```

- [ ] **Step 4: Run test to verify it passes**

Run: `busted spec/handlers_control_spec.lua`
Expected: PASS — `5 successes / 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add handlers/control.lua spec/handlers_control_spec.lua
git commit -m "feat: POST /control page, frontlight, screenshot, refresh handlers"
```

---

## Task 9: koreader_api adapter (pure helper unit-tested; globals smoke-tested)

This is the only file that touches KOReader globals. The pure `format_history` transform
is unit-tested; the global-touching functions are thin and verified on device in Task 11.

**Files:**
- Create: `koreader_api.lua`
- Test: `spec/koreader_api_spec.lua`

- [ ] **Step 1: Write the failing test**

Create `spec/koreader_api_spec.lua`:

```lua
local KoreaderApi = require("koreader_api")

describe("KoreaderApi.format_history", function()
    local hist = {
        { file = "/books/dune.epub" },
        { file = "/books/it.epub" },
        { file = "/books/hobbit.epub" },
    }

    it("maps history entries to {path, title, author}", function()
        local out = KoreaderApi.format_history(hist, nil, nil)
        assert.are.equal(3, #out)
        assert.are.equal("/books/dune.epub", out[1].path)
        assert.are.equal("dune", out[1].title)        -- filename without extension
    end)

    it("applies a limit", function()
        local out = KoreaderApi.format_history(hist, 2, nil)
        assert.are.equal(2, #out)
    end)

    it("filters case-insensitively by query", function()
        local out = KoreaderApi.format_history(hist, nil, "DU")
        assert.are.equal(1, #out)
        assert.are.equal("/books/dune.epub", out[1].path)
    end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `busted spec/koreader_api_spec.lua`
Expected: FAIL — `module 'koreader_api' not found`.

- [ ] **Step 3: Write minimal implementation**

Create `koreader_api.lua`. The `format_history` helper is pure; the remaining functions
lazily `require` KOReader modules so the file loads under busted (the helper test never
calls them).

```lua
local KoreaderApi = {}

-- ---- pure helper (unit-tested) ----

local function basename_noext(path)
    local name = path:match("([^/]+)$") or path
    return (name:gsub("%.[^.]+$", ""))
end

-- entries: list of {file=string} (KOReader ReadHistory shape).
-- limit: number|nil. q: string|nil. Returns list of {path, title, author}.
function KoreaderApi.format_history(entries, limit, q)
    local out = {}
    local needle = q and q:lower() or nil
    for _, e in ipairs(entries) do
        local title = basename_noext(e.file)
        if not needle or title:lower():find(needle, 1, true) then
            out[#out + 1] = { path = e.file, title = title, author = e.author or "" }
        end
        if limit and #out >= limit then break end
    end
    return out
end

-- ---- KOReader global adapters (smoke-tested on device) ----

local function powerd()
    return require("device"):getPowerDevice()
end

function KoreaderApi.battery()
    return powerd():getCapacity()
end

function KoreaderApi.is_charging()
    return powerd():isCharging()
end

function KoreaderApi.version()
    return require("version"):getNormalizedCurrentVersion()
end

function KoreaderApi.model()
    return require("device").model
end

function KoreaderApi.storage_free()
    -- statvfs-backed free bytes for the home dir; nil if unavailable on this device.
    local ok, util = pcall(require, "ffi/util")
    if ok and util.statvfs then
        local home = require("datastorage"):getDataDir()
        local stat = util.statvfs(home)
        if stat then return stat.f_bavail * stat.f_bsize end
    end
    return nil
end

function KoreaderApi.wifi_on()
    return require("ui/network/manager"):isWifiOn()
end

function KoreaderApi.current_book()
    local ReaderUI = require("apps/reader/readerui")
    local ui = ReaderUI.instance
    if not ui or not ui.document then return nil end
    local doc = ui.document
    local props = doc:getProps() or {}
    local page = ui.view and ui.view.state and ui.view.state.page or doc:getCurrentPage()
    local pages = doc:getPageCount()
    local stats = ui.statistics and ui.statistics:getCurrentStat and ui.statistics:getCurrentStat()
    return {
        title = props.title or basename_noext(ui.document.file or ""),
        author = props.authors or props.author or "",
        page = page,
        pages = pages,
        percent = pages and pages > 0 and math.floor((page / pages) * 100) or 0,
        time_spent = stats and stats.total_time or 0,
    }
end

function KoreaderApi.cover_png()
    local ReaderUI = require("apps/reader/readerui")
    local ui = ReaderUI.instance
    if not ui or not ui.document then return nil end
    local cover = ui.document:getCoverPageImage()
    if not cover then return nil end
    local png = cover:writePNG and cover:writePNG() or nil
    if cover.free then cover:free() end
    return png
end

function KoreaderApi.library(limit, q)
    local ReadHistory = require("readhistory")
    return KoreaderApi.format_history(ReadHistory.hist or {}, limit, q)
end

function KoreaderApi.open_book(path)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "file" then return false end
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(path)
    return true
end

function KoreaderApi.turn_page(dir)
    local UIManager = require("ui/uimanager")
    local Event = require("ui/event")
    local rel = dir == "next" and 1 or -1
    UIManager:broadcastEvent(Event:new("GotoViewRel", rel))
end

function KoreaderApi.set_frontlight(brightness, warmth)
    local pd = powerd()
    if brightness ~= nil and pd.setIntensity then pd:setIntensity(brightness) end
    if warmth ~= nil and pd.setWarmth then pd:setWarmth(warmth) end
end

function KoreaderApi.screenshot_png()
    local Screen = require("device").screen
    local bb = Screen:shot and Screen:shot() or Screen.bb
    local png = bb and bb.writePNG and bb:writePNG() or nil
    return png
end

function KoreaderApi.refresh()
    local UIManager = require("ui/uimanager")
    UIManager:setDirty("all", "full")
end

return KoreaderApi
```

> **Note for the engineer:** the global-touching functions call KOReader's own internal
> APIs (`Device`, `ReaderUI`, `PowerDevice`, `ReadHistory`, `Screen`). Method names match
> current KOReader source as of mid-2026 but can drift between KOReader releases — Task 11
> smoke-tests every one on a real device and is where you fix any mismatch. The pure
> `format_history` helper is the only part covered by unit tests here.

- [ ] **Step 4: Run test to verify it passes**

Run: `busted spec/koreader_api_spec.lua`
Expected: PASS — `3 successes / 0 failures`. (Only `format_history` runs; the lazy
`require`s are never triggered under busted.)

- [ ] **Step 5: Commit**

```bash
git add koreader_api.lua spec/koreader_api_spec.lua
git commit -m "feat: koreader_api adapter with unit-tested history formatter"
```

---

## Task 10: main.lua — wire servers into KOReader

`main.lua` builds the router, registers every handler bound to `koreader_api`, decodes
JSON request bodies, and runs the TCP + UDP servers as non-blocking sockets polled by
KOReader's `UIManager`. There are no unit tests for this glue (it requires the full
KOReader runtime); it is smoke-tested in Task 11.

**Files:**
- Create: `main.lua`
- Create: `koremote_settings.sample.lua`
- Modify: `.gitignore` (add `koremote_settings.lua`)

- [ ] **Step 1: Create the settings sample and gitignore entry**

Create `koremote_settings.sample.lua`:

```lua
-- Copy to koremote_settings.lua (gitignored) and set your own token.
return {
    token = "change-me-to-a-long-random-string",
    http_port = 8080,
    discovery_port = 8089,
    name = "KOReader",
}
```

Append to `.gitignore`:

```
koremote_settings.lua
```

- [ ] **Step 2: Write `main.lua`**

Create `main.lua`:

```lua
local WidgetContainer = require("ui/widget/container/widgetcontainer")
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
    -- fall back to a co-located sample only to read defaults; no token => disabled
    return nil
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

-- Accept one pending TCP connection (non-blocking) and serve it.
local function serve_once(self)
    if not self.server then return end
    local client = self.server:accept()
    if not client then return end
    client:settimeout(2)
    local raw, err = client:receive("*l")
    if raw then
        local rest = ""
        -- read headers + optional body until blank line, then content-length bytes
        local headers_done, content_length = false, 0
        local buf = { raw }
        while not headers_done do
            local line = client:receive("*l")
            if not line or line == "" then headers_done = true
            else
                buf[#buf + 1] = line
                local cl = line:lower():match("^content%-length:%s*(%d+)")
                if cl then content_length = tonumber(cl) end
            end
        end
        if content_length > 0 then
            rest = client:receive(content_length) or ""
        end
        local request_text = table.concat(buf, "\r\n") .. "\r\n\r\n" .. rest
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
    local data, ip = self.disco:receivefrom()
    if data then
        local reply = Discovery.handle_packet(data, {
            name = self.cfg.name or "KOReader",
            ip = self.local_ip or "0.0.0.0",
            port = self.cfg.http_port,
            version = meta.version,
        }, rapidjson.encode)
        if reply then self.disco:sendto(reply, ip, select(2, self.disco:getsockname()) and 0 or 0) end
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
    self.cfg = load_settings()
    if not self.cfg then
        UIManager:show(InfoMessage:new{
            text = "KO Remote: set a token in koremote_settings.lua first." })
        return
    end
    self.router = build_router(self.cfg)

    self.server = assert(socket.tcp())
    self.server:setoption("reuseaddr", true)
    assert(self.server:bind("*", self.cfg.http_port))
    self.server:listen(4)
    self.server:settimeout(0)
    self.local_ip = self.server:getsockname()

    self.disco = assert(socket.udp())
    self.disco:setoption("reuseaddr", true)
    assert(self.disco:setsockname("*", self.cfg.discovery_port))
    self.disco:settimeout(0)

    self.running = true
    self:_poll()
    UIManager:show(InfoMessage:new{
        text = string.format("KO Remote on :%d", self.cfg.http_port) })
end

function KoRemote:stop()
    self.running = false
    if self.server then self.server:close(); self.server = nil end
    if self.disco then self.disco:close(); self.disco = nil end
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
```

- [ ] **Step 3: Verify the full unit suite still passes**

Run: `busted`
Expected: PASS — all specs green (`main.lua` is not required by any spec, so the suite is
unaffected). Confirm the total: `25 successes / 0 failures`.

- [ ] **Step 4: Commit**

```bash
git add main.lua koremote_settings.sample.lua .gitignore
git commit -m "feat: main plugin wiring with TCP REST + UDP discovery servers"
```

---

## Task 11: On-device smoke test

No code change — this task verifies the adapter and servers against a real KOReader
device, since `koreader_api.lua` and `main.lua` cannot be unit-tested off-device.

- [ ] **Step 1: Install the plugin**

Copy the whole folder to the device's plugins dir (USB or SSH), keeping the suffix:

```bash
scp -r ../koremote.koplugin <device>:/mnt/us/koreader/plugins/
```

Create `koremote_settings.lua` (from the sample) in KOReader's settings dir on the device
with a real token, then restart KOReader.

- [ ] **Step 2: Start the server**

On the device: **Menu → KO Remote → Start server**. Confirm the "KO Remote on :8080"
message appears.

- [ ] **Step 3: Exercise every endpoint with curl**

From a computer on the same LAN (replace `<ip>` and `<token>`):

```bash
H="Authorization: Bearer <token>"
curl -s -H "$H" http://<ip>:8080/status
curl -s -H "$H" http://<ip>:8080/book
curl -s -H "$H" http://<ip>:8080/library?limit=5
curl -s -H "$H" -X POST -d '{"dir":"next"}'      http://<ip>:8080/control/page
curl -s -H "$H" -X POST -d '{"brightness":10}'   http://<ip>:8080/control/frontlight
curl -s -H "$H" -X POST http://<ip>:8080/control/refresh
curl -s    http://<ip>:8080/status      # expect 401 (no token)
curl -s -H "$H" -X POST -d '{"path":"/mnt/us/documents/somebook.epub"}' http://<ip>:8080/open
```

Expected: `/status` returns JSON with battery/version/model; `/book` reflects the open
book; `/control/page` turns the page on the device; the no-token call returns 401.
Fix any KOReader API mismatch in `koreader_api.lua` (see the Task 9 note) and re-test.

- [ ] **Step 4: Verify discovery**

```bash
# send the probe as a broadcast and read the reply
echo -n "KOREMOTE?" | nc -u -w1 -b 255.255.255.255 8089
```

Expected: a JSON reply `{"name":...,"ip":...,"port":8080,"version":"v0.1.0"}`.

- [ ] **Step 5: Commit any fixes**

```bash
git add koreader_api.lua main.lua
git commit -m "fix: align adapter calls with on-device KOReader APIs"
```

(Skip the commit if no fixes were needed.)

---

## Task 12: README + finalize

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write `README.md`**

Create `README.md`:

```markdown
# koremote.koplugin

KOReader plugin that exposes a token-authed **HTTP REST control API** plus a **UDP
discovery responder** on the e-reader, so a companion app (e.g. a Nintendo Switch
homebrew, inspired by [mister-companion-nx](https://github.com/Anime0t4ku/mister-companion-nx))
can read device/book info and remote-control the reader.

## Install

Copy this folder into KOReader's plugins directory, keeping the `.koplugin` suffix:

```
koreader/plugins/koremote.koplugin/
```

Then copy `koremote_settings.sample.lua` to `koremote_settings.lua` in KOReader's
settings directory, set a long random `token`, and restart KOReader.
Start it from **Menu → KO Remote → Start server**.

## API

All routes require `Authorization: Bearer <token>`.

| Method | Path | Description |
|---|---|---|
| GET | `/status` | battery, charging, version, model, storage_free, wifi |
| GET | `/book` | current book title/author/page/pages/percent/time_spent (204 if none) |
| GET | `/book/cover` | current cover as PNG (204 if none) |
| GET | `/library?limit=&q=` | list of `{path, title, author}` |
| POST | `/open` | `{path}` → open a book |
| POST | `/control/page` | `{dir:"next"\|"prev"}` |
| POST | `/control/frontlight` | `{brightness?, warmth?}` |
| POST | `/control/screenshot` | returns PNG |
| POST | `/control/refresh` | full screen refresh |

### Discovery

Send UDP `KOREMOTE?` to the discovery port (default `8089`); the plugin replies with
`{name, ip, port, version}`.

## Develop

```bash
busted        # run the unit test suite
```

The request logic (router, parser, handlers, discovery) is fully unit-tested with a fake
KOReader adapter. `koreader_api.lua` is the only file touching KOReader internals and is
verified on-device.
```

- [ ] **Step 2: Run the full suite one last time**

Run: `busted`
Expected: PASS — `25 successes / 0 failures`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README with install, API, and discovery reference"
```

---

## Self-Review notes

- **Spec coverage:** every v1 endpoint in the design (`/status`, `/book`, `/book/cover`,
  `/library`, `/open`, `/control/*`, UDP discovery, Bearer auth) maps to a task
  (Tasks 2–10). Discovery → Task 4; auth → Task 2.
- **Type consistency:** `req`/`res`/`api` shapes are fixed in the File Structure section
  and used identically across every handler task. Adapter function names
  (`battery`, `is_charging`, `current_book`, `cover_png`, `library`, `open_book`,
  `turn_page`, `set_frontlight`, `screenshot_png`, `refresh`, `wifi_on`, `version`,
  `model`, `storage_free`) match between Task 9 (`koreader_api.lua`) and the handler
  tests/handlers that consume them.
- **Untestable glue isolated:** `koreader_api.lua` globals and `main.lua` servers are the
  only non-unit-tested code, and both are covered by the on-device smoke test (Task 11).

## Project conventions

- Commits exclusively under Hudson Brendon (no `Co-Authored-By` trailer).
- Squash the per-task agent commits into one clean commit before the first public push.
