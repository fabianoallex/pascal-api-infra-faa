# pascal-api-infra-faa — Guide for AI agents

Infrastructure for REST APIs on Horse, **dual-compiler** (Delphi + Lazarus/FPC 3.2.2): query-string
paging and ordering, configuration, file logging, rate limiting, DTO bases, messaging contracts,
JWT (HS256) and the Horse middlewares (error handler, CORS, request log, Bearer/JWT auth, rate
limit). Built on pascal-common-faa, pascal-jsonmapper-faa, pascal-db-faa and Horse.

For the general dual-compiler rules (project anatomy, `.inc`, mirrored tests, CI), use the
`dual-compiler-delphi-lazarus` skill. This file records only what is specific to this repo. The
plan, the phases and what is still open are in `docs/plan.md`.

---

## Language

Everything in this repository is in **English**: code, identifiers, comments, runtime messages,
test names and assertion messages, documentation and commit messages. Test *data* may contain
non-ASCII values on purpose (`'São Paulo → ok'`). One deliberate exception:
`TApiMessages.Portuguese` (`PascalApi.Http`), the client-facing messages in Portuguese, which an
application selects at startup (the default is `TApiMessages.English`).

---

## Origin: delphi-api-infra-faa

The units are ports of `delphi-api-infra-faa` (Delphi only), which **stays separate** and keeps
serving its Delphi consumer; this repository doesn't replace it and isn't a drop-in for it. Fixes
don't flow between the two automatically. Each unit's header says what changed in the port.

| Here | There |
|---|---|
| `PascalApi.Config` | `Common.Config` (without `SetIniFile`/`IniPath`) |
| `PascalApi.OrderBy` | `Common.OrderBy` |
| `PascalApi.Pagination` (+ pascal-db-faa's `PascalDb.Paging`) | `Common.Pagination` |
| `PascalApi.RateLimitState` | `Common.RateLimitState` |
| `PascalApi.FileLog` | `Common.FileLog` |
| `PascalApi.Dto` | `Common.DTO.Base` |
| `PascalApi.Messaging` | `Messaging.Interfaces` + `Messaging.Adapters.Registry` |
| `PascalApi.Text` | — (new: UTF-8 bytes, MD5, UTF-8 prefix) |
| `PascalApi.Http` | the decisions inside `Horse.Middleware.*` (status mapping, CORS headers, Bearer parsing, client IP, access log line), without Horse |
| `PascalApi.Crypto`, `PascalApi.Jwt` | `TJwtHelper` in `Horse.Middleware.Jwt` (System.Hash/NetEncoding/JSON); now also signs |
| `src/horse/PascalApi.Horse.Middlewares` | `Horse.Middleware.ErrorHandler`/`Cors`/`Logger`/`Auth`/`Jwt`/`RateLimit` |
| pascal-jsonmapper-faa | `Common.JsonMapper` |
| pascal-db-faa | `src/Db`, `Common.Helpers` |

**The DTO convention is different:** JSON is mapped from **published** properties under `{$M+}`
(pascal-jsonmapper-faa's contract), not from public properties read by Delphi's extended RTTI.
Swagger attributes (`[SwagProp]` etc.) don't exist here: FPC 3.2.2 has no custom attributes at
all (measured, skill `references/rtti-gotchas.md`).

---

## Dependencies

`external/` holds the dependencies as git submodules, pinned: pascal-common-faa `v1.4.0`,
pascal-jsonmapper-faa `v0.3.0`, pascal-db-faa `v0.12.1`, Horse `3.3.12` (`fda6fed`; until 0.4.0
this repository used 3.3.2, `72cc45f`, as pascal-dfe-broker and delphi-api-starter still do). They are **only for this
repository's tests**: a consumer provides its own single copy of each (submodule + search path),
never `pascal-api-infra-faa/external/...`. Clone with `git submodule update --init` (no
`--recursive`: pascal-db-faa's own `external/` is not needed).

- Minimum pascal-common-faa version checked in `PascalApi.Dto` (`PASCALCOMMON_VERSION`).
- Delphi search path of a test project: `src`, `external/pascal-common-faa/src`,
  `external/pascal-common-faa/bridges/jsonmapper`, `external/pascal-jsonmapper-faa/src`,
  `external/pascal-db-faa/src`.
- Minimum pascal-db-faa version checked in `PascalApi.Http` (`PASCALDB_VERSION`). pascal-jsonmapper-faa
  has no version constant: its minimum (0.3.0, for `Members`) is only in the `.lpk`.
- Lazarus: `packages/pascal_api_infra_faa.lpk` requires `pascal_common_faa`, `pascaljsonmapper_pkg`
  and `pascal_db_faa` with `DefaultFilename ... Prefer="True"` pointing at `external/`. The test
  project also requires `pascal_common_faa_jsonmapper` (the bridge).

### OpenAPI

`PascalApi.OpenApi` (pure, tested in `PascalApi.OpenApiTests`) builds the document;
`src/horse/PascalApi.Horse.OpenApi` (`TRouteDoc`) registers routes and serves it. Design and the
four decisions taken with the user: `docs/openapi-design.md`. Rules that keep it honest:

- Schemas come from `TJsonMapper.Members` (pascal-jsonmapper-faa 0.3.0): never re-derive JSON
  names here, or the document can name a member the wire doesn't have.
- Types by `PTypeInfo` identity and kind, never by name (names differ between compilers).
- Metadata by Pascal property name, checked at `Describe` time (`EApiSchemaError`).
- Both samples document their routes, and `tools/test_http_docker.sh` (CI) validates each
  document with `openapi-spec-validator`.

### MCP

`PascalApi.Mcp` (pure, tested in `PascalApi.McpTests` with a fake executor) builds the tools
from `TApiDocument` and answers JSON-RPC; `src/horse/PascalApi.Horse.Mcp` (`TMcpEndpoint`) is the
endpoint and the HTTP executor. Design and decisions: `docs/mcp-design.md`.

- Protocol revision **2026-07-28 only**, stateless (decided by the user): `initialize` is an
  unknown method (404, naming the version). Don't add legacy support without asking.
- The official Python SDK (`mcp` 2.0.0, `tools/mcp_client_check.py`, run by CI) is the
  reference: it caught `ttlMs`/`cacheScope` missing from `tools/list`. After changing the wire
  format, run `tools/ci-test.sh`.
- Tool calls go back through the API over HTTP (all middlewares apply), so the provider must be
  threaded (Horse's are). The endpoint registers after every `TRouteDoc` route: the catalog is
  built once, in `Register`.
- The scenario scripts run under dash in CI: `shift N` past `$#` is fatal there (not in Git
  Bash).

### Horse

The core package (`src/`) doesn't use Horse; only `src/horse/PascalApi.Horse.Middlewares` does,
and it is **not** in the `.lpk` (Horse has no Lazarus package): a consumer adds `src/horse` and
its own Horse `src` to the search path.

- **Horse 3.3.3 or later on FPC for Windows.** Horse 3.3.2 picked `const` for its generic
  comparer on Win64, where FPC 3.2.2's `rtl-generics` declares `constref`, and didn't compile
  ("No matching implementation for interface method Equals(constref ...)"); fixed upstream in
  3.3.3 (commit `7a9a9cb`, issue #542). Until 0.4.0 this repository patched a copy of Horse's
  `src` (`tools/prepare_horse.sh`, removed); with 3.3.12 every target uses Horse unchanged.
- **Horse's FPC callbacks are plain procedures** (`Horse.Callback.pas`), so a middleware can't
  capture its settings: each one keeps them in the unit, **one configuration per process**
  (accepted by the user, 2026-10-08). `THorse.OnError` has the same shape on both compilers.
- Returning a handler as `THorseCallback` (a record on FPC): `Result := AProc` reads as a call on
  FPC; `AsCallback` uses `@AProc` there (the code address, what Horse's own `Implicit` stores).
- **JSON goes out through `TJsonSend.Send` (UTF-8 bytes + `charset=utf-8`), never
  `Res.Send(string)`.** On Delphi, `Send(string)` goes through the web response's `Content`, which
  encodes by the Content-Type's charset: with plain `application/json`, accented text arrived
  broken (4 of the 65 HTTP checks, Delphi 12 Win32 and Win64; FPC was fine because its string is
  already UTF-8). The unit tests can't see this: only the HTTP scenarios on Delphi do.
- **`THorseRequest.RemoteAddr` is '' with the console provider** (fpWeb on FPC; by reading Horse's code, Indy on Delphi too):
  only Horse's raw providers (Epoll, IOCP, HttpSys, Daemon, LCL) call `Populate` with it. Measured
  on FPC 3.2.2/Windows (the access log showed `-`); `RemoteAddrOf` falls back to
  `RawWebRequest.RemoteAddr`. Delphi not measured yet. The origin uses `Req.RemoteAddr` directly,
  so its IP rate limit probably keys every client as `unknown` there — not checked on that side.

---

## Code rules (every unit in `src/`)

- **`{$I pascalapi.inc}` right after `unit ...;`** (`{$MODE DELPHI}{$H+}` on FPC,
  `PASCALAPI_WINDOWS`, `PASCALAPI_FUNCREFS`).
- **`uses` without namespaces** (`SysUtils`, `Generics.Collections`). A Delphi-only unit goes
  inside `{$IFNDEF FPC}` (`System.Hash` in `PascalApi.Text`).
- **No anonymous methods** and no `TThread.CreateAnonymousThread`: FPC 3.2.2 has neither. A
  `TThread` subclass (`TFileLogFlushThread`) or a named routine.
- **Public callbacks follow `PASCALAPI_FUNCREFS`**: `reference to` on Delphi, `of object` on FPC
  (same as `PASCALDB_FUNCREFS`). Plain function pointers where no state is captured
  (`TEnvironmentReader`).
- **No string helpers** (`.Split`, `.StartsWith`, `.Substring`): plain `Pos`/`Copy`/`Trim`.
- **Text that leaves the process is UTF-8, measured in bytes on both compilers** (`PascalApi.Text`).
  `Length` counts UTF-16 units on Delphi and bytes on FPC, so anything that cuts or sizes text
  for output (`TLogTruncate`) works on UTF-8 bytes and never splits a character.
- **Shared defaults are created in `initialization`, never lazily** (a lazy default raced in
  pascal-common-faa's `TClock`): `TAppConfig`'s reader and path, the `FileLog` instance, the
  messaging registry.
- **Time through pascal-common-faa's `TClock`/`TTicker`** (replaceable in tests); durations with
  `TTicker`, never `TClock`.
- **GUIDs are generated** (`[guid]::NewGuid()`), never typed; a hook rejects suspicious ones.
- **Top-of-file comment** in every unit, program and test, between `unit X;` (+ `{$I ...}`) and
  `interface`. Plain prose. If it quotes a `}` (a GUID in an example), use `(* ... *)` — a `}`
  closes a `{ }` comment early (this happened in `PascalApi.Dto`: "String exceeds line"). And
  inside `(* ... *)`, never write `*)`: `(Horse.Middleware.*)` closed the comment in
  `PascalApi.Http` ("INTERFACE expected but identifier ONLY found").

---

## Tests

Masters are DUnitX (`tests/Unit/*Tests.pas`), written in FPCUnit's assertion dialect through
`PascalApi.DUnitXCompat`. The FPCUnit mirrors in `tests/Unit/fpc` are **generated**: never edit
them, run `python tools/gen_fpc_mirror.py`. No `Assert.WillRaise` (it takes a closure): catch the
exception in a helper and assert on what it returned.

| Command | What |
|---|---|
| `sh tools/test_fpc.sh` | regenerate mirrors, `lazbuild` + run the FPCUnit suite (Windows) |
| `sh tools/test_fpc_docker.sh` | the same suite with plain `fpc` on Linux (Docker, `FPC_IMAGE`) |
| `sh tools/test_http.sh` | build both samples with lazbuild, start each, run `tools/http_scenarios.sh` / `tools/http_scenarios_db.sh` (Windows; sample 02 needs sqlite.org's `sqlite3.dll` in `SQLITE_DLL` or `.deps/`) |
| `sh tools/test_http_docker.sh` | the same on Linux with plain `fpc` (Docker; image needs curl and libsqlite3-0) |
| `sh tools/ci-test.sh` | what CI runs: unit suite + HTTP scenarios on Linux (builds the image if needed) |
| Delphi | open `PascalApi.groupproj`, build `PascalApi.UnitTests`, `ApiSample` and `DbApiSample` (Win32 and Win64); run the tests; start `ApiSample.exe` and run `sh tools/http_scenarios.sh 9310`; start `DbApiSample.exe 9330 --reset` and run `sh tools/http_scenarios_db.sh 9330` |

The middlewares are tested in two layers: their decisions in `PascalApi.HttpTests` (no server),
and over real HTTP by `tools/http_scenarios.sh` (curl, 65 checks) against `samples/01-api`,
which uses every middleware. In-process servers aren't used: on FPC, Horse's `Listen` blocks in
`THTTPApplication.Run` and there is no `StopListen`.

Sending non-ASCII bodies with curl from Git Bash on Windows: put them in a file with explicit
UTF-8 bytes (`printf 'Macei\303\263'`), since curl.exe gets its arguments in the ANSI code page.

Acceptance on every side: 0 errors, 0 failures, 0 leaks (heaptrc / FastMM). Delphi Community
Edition can't build from the command line: the user builds in the IDE, then the executable
can be run from here (`tests/Unit/Win32/Debug/PascalApi.UnitTests.exe`).

Never pipe `lazbuild` into `head`/`Select-Object -First`: the compiler hangs when the pipe closes
(seen in pascal-dfe-broker). Redirect to a file, as the scripts do.

New unit checklist: unit in `src/`, test master in `tests/Unit/`, then add both to
`packages/pascal_api_infra_faa.lpk`, `tests/Unit/PascalApi.UnitTests.dpr` + `.dproj` and
`tests/Unit/fpc/PascalApiUnitTestsFpc.lpr`.
