local Library = {}

function Library.list(api, req)
    local q = req.query or {}
    local limit = tonumber(q.limit)
    local items = api.library(limit, q.q)
    return { status = 200, json = items }
end

function Library.open(api, req)
    local path = req.body and req.body.path
    if not path or path == "" then
        return { status = 400, json = { error = "path required" } }
    end
    if not api.open_book(path) then
        return { status = 404, json = { error = "not found" } }
    end
    return { status = 200, json = { ok = true } }
end

return Library
