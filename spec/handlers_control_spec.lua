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
