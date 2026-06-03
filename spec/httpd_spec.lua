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
