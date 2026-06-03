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
        assert.are.equal("Herbert", res.json.author)
        assert.are.equal(3600, res.json.time_spent)
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
