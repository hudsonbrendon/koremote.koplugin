# koremote.koplugin

KOReader plugin that exposes a token-authed **HTTP REST control API** plus a **UDP
discovery responder** on the e-reader, so a companion app (e.g. a Nintendo Switch
homebrew, inspired by [mister-companion-nx](https://github.com/Anime0t4ku/mister-companion-nx))
can read device/book info and remote-control the reader.

## Install

Copy this folder into KOReader's plugins directory, keeping the `.koplugin` suffix:

```
koreader/plugins/koremote.koplugin/
```

Then copy `koremote_settings.sample.lua` to `koremote_settings.lua` in KOReader's
settings directory, set a long random `token`, and restart KOReader.
Start it from **Menu → KO Remote → Start server**.

## API

All routes require `Authorization: Bearer <token>`.

| Method | Path | Description |
|---|---|---|
| GET | `/status` | battery, charging, version, model, storage_free, wifi |
| GET | `/book` | current book title/author/page/pages/percent/time_spent (204 if none) |
| GET | `/book/cover` | current cover as PNG (204 if none) |
| GET | `/library?limit=&q=` | list of `{path, title, author}` |
| POST | `/open` | `{path}` → open a book |
| POST | `/control/page` | `{dir:"next"\|"prev"}` |
| POST | `/control/frontlight` | `{brightness?, warmth?}` |
| POST | `/control/screenshot` | returns PNG |
| POST | `/control/refresh` | full screen refresh |

### Discovery

Send UDP `KOREMOTE?` to the discovery port (default `8089`); the plugin replies with
`{name, ip, port, version}`.

## Develop

```
busted        # run the unit test suite
```

The request logic (router, parser, handlers, discovery) is fully unit-tested with a fake
KOReader adapter. `koreader_api.lua` is the only file touching KOReader internals and is
verified on-device.
