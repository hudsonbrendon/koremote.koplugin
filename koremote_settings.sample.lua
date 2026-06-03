-- Copy to koremote_settings.lua (gitignored) and set your own token.
return {
    token = "change-me-to-a-long-random-string",
    http_port = 8080,        -- if KOReader's HTTP Inspector also uses 8080, pick another (e.g. 8081)
    discovery_port = 8089,
    name = "KOReader",
    autostart = false,       -- true = start the control server automatically on plugin load
}
