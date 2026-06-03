local Router = {}
Router.__index = Router

function Router.new(opts)
    return setmetatable({ token = opts.token, routes = {} }, Router)
end

function Router:add(method, path, handler)
    self.routes[method .. " " .. path] = handler
end

local function authorized(self, req)
    local h = req.headers and (req.headers["authorization"] or req.headers["Authorization"])
    return h == "Bearer " .. self.token
end

function Router:dispatch(req)
    if not authorized(self, req) then
        return { status = 401, json = { error = "unauthorized" } }
    end
    local handler = self.routes[req.method .. " " .. req.path]
    if not handler then
        return { status = 404, json = { error = "not found" } }
    end
    return handler(req)
end

return Router
