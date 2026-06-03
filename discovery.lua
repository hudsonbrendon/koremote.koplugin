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
