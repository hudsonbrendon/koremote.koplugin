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
