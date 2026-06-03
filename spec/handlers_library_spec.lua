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

    it("returns 400 when path is an empty string", function()
        local res = Library.open(fake_api(), { body = { path = "" } })
        assert.are.equal(400, res.status)
    end)
end)
