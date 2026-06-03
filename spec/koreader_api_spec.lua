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
