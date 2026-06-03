local Status = {}

-- api: the koreader adapter. req: the request table. Returns a res table.
function Status.get(api, req)
    return {
        status = 200,
        json = {
            battery = api.battery(),
            charging = api.is_charging(),
            version = api.version(),
            model = api.model(),
            storage_free = api.storage_free(),
            wifi = api.wifi_on(),
        },
    }
end

return Status
