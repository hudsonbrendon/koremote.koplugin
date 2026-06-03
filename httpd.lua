local Httpd = {}

local STATUS_TEXT = {
    [200] = "OK", [204] = "No Content", [400] = "Bad Request",
    [401] = "Unauthorized", [404] = "Not Found",
}

local function parse_query(qs)
    local q = {}
    for k, v in (qs or ""):gmatch("([^&=]+)=([^&=]+)") do
        q[k] = v
    end
    return q
end

-- raw: full HTTP request string. Returns a req table.
function Httpd.parse_request(raw)
    local head, body = raw:match("^(.-)\r\n\r\n(.*)$")
    head = head or raw
    body = body or ""
    local lines = {}
    for line in (head .. "\r\n"):gmatch("(.-)\r\n") do
        lines[#lines + 1] = line
    end
    local method, target = (lines[1] or ""):match("^(%u+)%s+(%S+)")
    local path, qs = (target or ""):match("^([^?]*)%??(.*)$")
    local headers = {}
    for i = 2, #lines do
        local k, v = lines[i]:match("^(.-):%s*(.*)$")
        if k then headers[k:lower()] = v end
    end
    return {
        method = method,
        path = path,
        query = parse_query(qs),
        headers = headers,
        body = body,
    }
end

-- res: a res table. json_encode: function(table) -> string. Returns the HTTP response string.
function Httpd.build_response(res, json_encode)
    local body, ctype
    if res.json ~= nil then
        body = json_encode(res.json)
        ctype = "application/json"
    else
        body = res.body or ""
        ctype = res.content_type or "text/plain"
    end
    local text = STATUS_TEXT[res.status] or "OK"
    return string.format(
        "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
        res.status, text, ctype, #body, body)
end

return Httpd
