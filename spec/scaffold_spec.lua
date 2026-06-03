local meta = require("_meta")

describe("plugin metadata", function()
    it("declares a name and a version", function()
        assert.are.equal("koremote", meta.name)
        assert.is_truthy(meta.version)
    end)
end)
