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
