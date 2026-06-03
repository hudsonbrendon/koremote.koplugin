# koremote.koplugin — Design (Sub-projeto 1)

**Data:** 2026-06-03
**Status:** Aprovado, pronto para plano de implementação

## Contexto

Projeto inspirado em [mister-companion-nx](https://github.com/Anime0t4ku/mister-companion-nx)
— um homebrew de Nintendo Switch que controla remotamente um MiSTer FPGA por SSH
(perfis de conexão, info do device, reboot, controle remoto, etc).

O objetivo é o equivalente para **KOReader**: um app de Switch que controla
remotamente um e-reader rodando KOReader (Kindle, Kobo, etc).

KOReader é um app de leitura — controle remoto significativo (virar página,
frontlight, abrir livro) exige **comandos semânticos**, não apenas shell por SSH.
Por isso a arquitetura tem dois componentes, e este projeto é a **fundação**:
o e-reader expõe uma **API REST de controle** que o app do Switch consome.

## Decomposição do projeto

Dois sub-projetos independentes, cada um testável sozinho:

1. **`koremote.koplugin`** (ESTE spec) — plugin Lua no e-reader. Servidor HTTP REST
   + responder de descoberta UDP. Testável via `curl`/busted sem nenhum Switch.
2. **`koreader-companion-nx`** (spec futura) — homebrew Switch em C++/libnx. Cliente
   REST: perfis de conexão, scan de descoberta, info do device, livro/progresso,
   browser de biblioteca, tela de controle remoto pelo controle do Switch.

O app do Switch depende inteiramente do contrato da API definido aqui. Ele só será
especificado depois que esta API existir e estiver testada.

## Responsabilidade do koplugin

Expor uma API REST de controle autenticada por token + um responder de descoberta
UDP no e-reader, fazendo a ponte entre a rede e as APIs internas do KOReader.

## Estrutura de arquivos

Uma responsabilidade por arquivo (espelha o layout do `hatelemetry.koplugin`):

| Arquivo | Responsabilidade |
|---|---|
| `main.lua` | Ciclo de vida do plugin: menu em Ferramentas, start/stop do server, settings (token, porta, enable) |
| `httpd.lua` | Servidor HTTP TCP não-bloqueante sobre luasocket, integrado ao loop do UIManager; faz parse de request line + headers + body |
| `router.lua` | Dispatch método+rota → handler; middleware de auth (Bearer token); encode JSON + respostas de erro |
| `discovery.lua` | Responder UDP: escuta ping broadcast, responde `{name, ip, port, version}` |
| `handlers/status.lua` | `GET /status` → bateria, charging, versão, modelo, storage livre, wifi |
| `handlers/book.lua` | `GET /book` → título/autor/página/páginas/percent/tempo; `GET /book/cover` → PNG |
| `handlers/library.lua` | `GET /library` → lista de ReadHistory + diretório; `POST /open {path}` |
| `handlers/control.lua` | `POST /control/page`, `/control/frontlight`, `/control/screenshot`, `/control/refresh` |
| `koreader_api.lua` | Adapter fino sobre os internals do KOReader (Device power, ReaderUI, Screenshoter, dispatch) — **o único arquivo que toca nos globais do KOReader**, deixando o resto unit-testável com mock |

**Por que isolar `koreader_api.lua`:** permite que os testes busted injetem um KOReader
fake, então routing/auth/handlers testam sem device. Mesmo truque que o `hatelemetry`
usa para `ha_client`.

## Contrato da API (v1)

Todas as rotas exigem `Authorization: Bearer <token>` → senão `401`.

```
GET  /status                  → 200 {battery, charging, version, model, storage_free, wifi}
GET  /book                    → 200 {title, author, page, pages, percent, time_spent} | 204 sem livro
GET  /book/cover              → 200 image/png | 204
GET  /library?limit=&q=       → 200 [{path, title, author}]
POST /open      {path}        → 200 {ok:true} | 404 path inexistente
POST /control/page  {dir:"next"|"prev"}            → 200 {ok:true}
POST /control/frontlight {brightness?, warmth?}    → 200 {ok:true}
POST /control/screenshot      → 200 image/png
POST /control/refresh         → 200 {ok:true}
```

### Descoberta UDP

```
UDP :<disc_port>  recebe payload "KOREMOTE?"  → responde JSON {name, ip, port, version}
```

O app do Switch faz broadcast de `"KOREMOTE?"` na LAN; o koplugin responde com seus
dados de conexão. Substitui mDNS/zeroconf com ~40 linhas de luasocket.

## Pontos de integração com o KOReader (em `koreader_api.lua`)

- Bateria/charging: `Device:getPowerDevice():getCapacity()` / `:isCharging()`
- Frontlight: `Device:getPowerDevice():setFrontlightIntensity(n)` / `:setFrontlightWarmth(n)`
- Livro atual: `ReaderUI.instance` (documento, página, total)
- Virar página: dispatch do evento `GotoViewRel` (+1 / -1)
- Abrir livro: `ReaderUI:showReader(path)`
- Histórico/biblioteca: `require("readhistory")`
- Screenshot: dump do framebuffer
- Versão KOReader: variável global de versão
- Wifi: `NetworkMgr`

> **Nota e-ink:** comandos são aplicados quando o wifi está ligado; com a tela
> dormindo o servidor pode não responder. v1 assume device acordado/wifi on durante
> o controle remoto (igual ao modelo "interativo" do mister-companion).

## Auth

Token compartilhado configurado no device (settings do plugin) e enviado pelo cliente
no header `Authorization: Bearer <token>`. Sem token configurado → servidor recusa
iniciar (fail-safe, não abre API aberta por acidente).

## Testes

- **Framework:** busted (setup `.busted` já usado no `hatelemetry`).
- **Estratégia:** mock dos globais do KOReader via `koreader_api` fake injetável.
- **Cobertura por endpoint:** auth 401, shape do JSON, status codes, 404 de `/open`,
  formato do pacote de descoberta, dispatch correto do router, parse de request no `httpd`.
- **TDD:** teste falhando primeiro, implementação mínima, commits frequentes.

## Fora de escopo (v1)

- App do Switch (`koreader-companion-nx`) — spec separada.
- Wallpaper / screensaver management.
- Install-extras.
- Edição de arquivos de config do KOReader.
- Multi-device / múltiplos perfis no lado do device.
- HTTPS/TLS (LAN confiável + token; TLS é melhoria futura).

## Convenções do projeto

- Commits exclusivamente em nome de Hudson Brendon (sem trailer Co-Authored-By).
- Squash do histórico de agente num commit limpo antes do primeiro push público.
