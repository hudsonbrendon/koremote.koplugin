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
