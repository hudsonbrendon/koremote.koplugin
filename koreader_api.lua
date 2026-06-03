local KoreaderApi = {}

-- ---- pure helper (unit-tested) ----

local function basename_noext(path)
    local name = path:match("([^/]+)$") or path
    return (name:gsub("%.[^.]+$", ""))
end

-- entries: list of {file=string} (KOReader ReadHistory shape).
-- limit: number|nil. q: string|nil. Returns list of {path, title, author}.
function KoreaderApi.format_history(entries, limit, q)
    local out = {}
    local needle = q and q:lower() or nil
    for _, e in ipairs(entries) do
        local title = basename_noext(e.file)
        if not needle or title:lower():find(needle, 1, true) then
            out[#out + 1] = { path = e.file, title = title, author = e.author or "" }
        end
        if limit and #out >= limit then break end
    end
    return out
end

-- ---- KOReader global adapters (smoke-tested on device) ----

local function powerd()
    return require("device"):getPowerDevice()
end

function KoreaderApi.battery()
    return powerd():getCapacity()
end

function KoreaderApi.is_charging()
    return powerd():isCharging()
end

function KoreaderApi.version()
    return require("version"):getNormalizedCurrentVersion()
end

function KoreaderApi.model()
    return require("device").model
end

function KoreaderApi.storage_free()
    -- Free bytes on the data partition via KOReader's df-backed helper.
    local util = require("util")
    local home = require("datastorage"):getDataDir()
    local usage = util.diskUsage(home)
    return usage and usage.available or nil
end

-- Write a PNG via `write_fn(path)` to a temp file, return its bytes, then delete it.
-- KOReader's writePNG / Screen:shot write to a file rather than returning bytes.
local function png_via_tempfile(write_fn)
    local path = "/tmp/koremote_png_" .. tostring(os.time()) .. ".png"
    local ok = pcall(write_fn, path)
    if not ok then os.remove(path); return nil end
    local f = io.open(path, "rb")
    if not f then os.remove(path); return nil end
    local data = f:read("*all")
    f:close()
    os.remove(path)
    if not data or #data == 0 then return nil end
    return data
end

function KoreaderApi.wifi_on()
    return require("ui/network/manager"):isWifiOn()
end

function KoreaderApi.current_book()
    local ReaderUI = require("apps/reader/readerui")
    local ui = ReaderUI.instance
    if not ui or not ui.document then return nil end
    local doc = ui.document
    local props = doc:getProps() or {}
    local page = ui.view and ui.view.state and ui.view.state.page or doc:getCurrentPage()
    local pages = doc:getPageCount()
    local stats = ui.statistics and type(ui.statistics.getCurrentStat) == "function" and ui.statistics:getCurrentStat()
    return {
        title = props.title or basename_noext(ui.document.file or ""),
        author = props.authors or props.author or "",
        page = page,
        pages = pages,
        percent = pages and pages > 0 and math.floor((page / pages) * 100) or 0,
        time_spent = stats and stats.total_time or 0,
    }
end

function KoreaderApi.cover_png()
    local ReaderUI = require("apps/reader/readerui")
    local ui = ReaderUI.instance
    if not ui or not ui.document then return nil end
    local cover = ui.document:getCoverPageImage()
    if not cover then return nil end
    local png = png_via_tempfile(function(path) cover:writePNG(path) end)
    if cover.free then cover:free() end
    return png
end

function KoreaderApi.library(limit, q)
    local ReadHistory = require("readhistory")
    return KoreaderApi.format_history(ReadHistory.hist or {}, limit, q)
end

function KoreaderApi.open_book(path)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "file" then return false end
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(path)
    return true
end

function KoreaderApi.turn_page(dir)
    local UIManager = require("ui/uimanager")
    local Event = require("ui/event")
    local rel = dir == "next" and 1 or -1
    UIManager:broadcastEvent(Event:new("GotoViewRel", rel))
end

function KoreaderApi.set_frontlight(brightness, warmth)
    local pd = powerd()
    if brightness ~= nil and pd.setIntensity then pd:setIntensity(brightness) end
    if warmth ~= nil and pd.setWarmth then pd:setWarmth(warmth) end
end

function KoreaderApi.screenshot_png()
    local Screen = require("device").screen
    -- Screen:shot(path) writes a PNG of the current framebuffer to a file.
    if type(Screen.shot) == "function" then
        return png_via_tempfile(function(path) Screen:shot(path) end)
    end
    -- Fallback: dump the framebuffer blitbuffer directly.
    local bb = Screen.bb
    if bb and type(bb.writePNG) == "function" then
        return png_via_tempfile(function(path) bb:writePNG(path) end)
    end
    return nil
end

function KoreaderApi.refresh()
    local UIManager = require("ui/uimanager")
    UIManager:setDirty("all", "full")
end

return KoreaderApi
