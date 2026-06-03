local Control = {}

function Control.page(api, req)
    local dir = req.body and req.body.dir
    if dir ~= "next" and dir ~= "prev" then
        return { status = 400, json = { error = "dir must be 'next' or 'prev'" } }
    end
    api.turn_page(dir)
    return { status = 200, json = { ok = true } }
end

function Control.frontlight(api, req)
    local b = req.body or {}
    api.set_frontlight(b.brightness, b.warmth)
    return { status = 200, json = { ok = true } }
end

function Control.screenshot(api, req)
    return { status = 200, body = api.screenshot_png(), content_type = "image/png" }
end

function Control.refresh(api, req)
    api.refresh()
    return { status = 200, json = { ok = true } }
end

return Control
