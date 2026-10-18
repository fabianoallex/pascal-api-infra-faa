# pascal-api-infra-faa — Guide for AI agents

Infrastructure for REST APIs on Horse, **dual-compiler** (Delphi + Lazarus/FPC 3.2.2): query-string
paging and ordering, configuration, file logging, rate limiting, DTO bases, JWT (HS256), the
Horse middlewares (error handler, CORS, request log, Bearer/JWT auth, rate
limit), OpenAPI and an MCP server. Built on pascal-common-faa, pascal-jsonmapper-faa,
pascal-db-faa and Horse.

## Before writing messaging, Redis or IPC code: use the sibling libraries

This library has **no** messaging, cache or inter-process layer, on purpose. When an API built
on it (or this repository) needs one, use these first, and don't write a new client, adapter or
abstraction without saying why none of them fits:

| Need | Library | Units |
|---|---|---|
| Message broker (RabbitMQ / AMQP 0-9-1), or a broker embedded in the program | [pascal-amqp-faa](https://github.com/fabianoallex/pascal-amqp-faa) | `AMQP.*` |
| Redis: cache, locks, counters, Pub/Sub, Streams | [pascal-redis-faa](https://github.com/fabianoallex/pascal-redis-faa) | `Redis.*` |
| Inter-process: Named Pipe / Unix socket, TCP, TLS | [pascal-pipes-faa](https://github.com/fabianoallex/pascal-pipes-faa) | `Pipes.*` |

Same author and dual-compiler rules, and they share pascal-common-faa with this library (one copy
per application). How to add them, the minimum versions, sketches and why there is no layer here
(`PascalApi.Messaging` was removed in 0.6.0): **`docs/related-libraries.md`**; inside an API (one
client per process, spans, a server that is down, measured): `docs/guide/messaging.md`, from
`samples/04-messaging` (FPC only, `build_fpc.sh` with `REDIS_FAA`/`AMQP_FAA`/`PIPES_FAA`; not
in CI, so rebuild it by hand after changing what it uses). JSON DTOs on a queue or a pipe:
`docs/guide/dtos-json.md`; every receiver handles its errors (pascal-amqp-faa 0.4.1 sends a
consumer's exception to `OnConsumerError`, pascal-pipes-faa 0.3.0 a handler's to `OnError`;
older versions lost it silently, measured). The index of every
`*-faa` library is the `dual-compiler-delphi-lazarus` skill's `references/faa-libraries.md`.

For the general dual-compiler rules (project anatomy, `.inc`, mirrored tests, CI), use the
`dual-compiler-delphi-lazarus` skill. This file records only what is specific to this repo. The
plan, the phases and what is still open are in `docs/plan.md`.

**The skill is not in this repository.** It lives in
[pascal-skills-faa](https://github.com/fabianoallex/pascal-skills-faa), a Claude Code plugin and
marketplace. If the skill isn't loaded in this session, ask the user to install it (user scope,
so it also reaches an application that uses this library as a submodule):
`/plugin marketplace add fabianoallex/pascal-skills-faa`, then
`/plugin install pascal-skills-faa@pascal-skills-faa`. Until then, read the index straight from
GitHub: `dual-compiler-delphi-lazarus/references/faa-libraries.md` in that repository.

**Guides for users** live in `docs/guide/` (index and template: `docs/guide/README.md`); the
`docs/*-design.md` files are decision records. A change to a feature with a guide updates the
guide too, and a guide's code comes from a sample that compiles and is tested.

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
| — (removed in 0.6.0; use pascal-amqp-faa, `docs/related-libraries.md`) | `Messaging.Interfaces` + `Messaging.Adapters.Registry` |
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

`external/` holds the dependencies as git submodules, pinned: pascal-common-faa `v1.17.0` (the library itself needs 1.17.0, for `PascalCommon.Random`, `PascalCommon.AesGcm` and `PascalCommon.Crypto`, which `PascalApi.Crypto` wraps; sample 02 uses 1.14.0's
normalizer factories, unit `PascalCommon.Normalizers`, `TNorm = class(TPcStringNormalizers)` in `DbApiSample.Normalizers`; the samples turn on 1.10.0's
`PcSetSafeLogUtf8` and log only through `SafeWriteln`, never plain `Writeln`),
pascal-jsonmapper-faa `v0.6.0` (refuses duplicate members; `EJsonInputError` = 400; exact
`Currency` on FPC), pascal-db-faa `v0.15.0` (`TSQLResult`'s operations
return a copy), pascal-redis-faa `v0.2.0` (only `src/redis` and sample 03's Redis key store
use it), Horse `3.3.12` (`fda6fed`; until 0.4.0
this repository used 3.3.2, `72cc45f`; pascal-dfe-broker moved to 3.3.12 on 2026-10-09, delphi-api-starter is still on 3.3.2). They are **only for this
repository's tests**: a consumer provides its own single copy of each (submodule + search path),
never `pascal-api-infra-faa/external/...`. Clone with `git submodule update --init` (no
`--recursive`: pascal-db-faa's own `external/` is not needed).

- Minimum pascal-common-faa version checked in `PascalApi.Dto` (`PASCALCOMMON_VERSION`).
- Sample 03 also has `src/redis` and `external/pascal-redis-faa/src` (Delphi) or the
  `pascal_redis_faa` package (Lazarus): its Redis key store.
- Delphi search path of a test project: `src`, `external/pascal-common-faa/src`,
  `external/pascal-common-faa/bridges/jsonmapper`, `external/pascal-jsonmapper-faa/src`,
  `external/pascal-db-faa/src`.
- Minimum pascal-db-faa version checked in `PascalApi.Http` (`PASCALDB_VERSION`, 0.15.0).
  pascal-jsonmapper-faa has no version constant: its minimum (0.6.0: `EJsonInputError` from 0.5.0,
  exact `Currency` on FPC) is only in the `.lpk`; on Delphi an older one fails on
  `EJsonInputError` (before 0.5.0) or compiles silently (0.5.0).
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
- Authentication in the document comes from the middleware, never from a second list:
  `TRouteDoc.Serve` asks `TJwtMiddleware`/`TAuthMiddleware` (`Configured`, `Excludes`) and marks
  the excluded paths `NoAuth` (`"security": []`).

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
- A call the executor can't make (API down, wrong base URL, timeout) gives the client the fixed
  `MCP_CALL_FAILED`; the exception's message, which named the API's host and port (measured,
  until 0.13.0), goes to the error log (`TErrorHandlerMiddleware.LogError`). Sample 01's
  `/mcp/unreachable` (port 1) is the check.
- The scenario scripts run under dash in CI: `shift N` past `$#` is fatal there (not in Git
  Bash).

### Multi-tenancy

`PascalApi.Tenancy` (pure, tested in `PascalApi.TenancyTests` with pascal-db-faa's
`TMockDBFactory` and a manual ticker) and `src/horse/PascalApi.Horse.Tenancy`
(`TTenantMiddleware`), proven first in `samples/03-tenants`. Design and the ten decisions taken
with the user: `docs/multitenancy-design.md`.

- **Opt-in**: no other unit uses them; an application without tenants sees no change (the
  samples 01/02 scenarios pass unchanged).
- **The tenant comes only from the token's claim** (`tenant_id`, not `tid`: Entra ID uses that).
  Don't add a header/host/path source without the user (decision 5: later, on a real case).
- **Every repository query goes through `TTenantFilter.Prepare`**: an unbound `:TENANT_ID` is a
  silent 404 on SQLdb/SQLite (measured), so the condition and its parameter are set together.
  SQL with tagged blocks goes through the `TSQLResult` overload (`SqlLoader[...].ProcessTag(...)`
  first), never through `AQuery.Sql :=` by hand.
- Pools are named by mode, never by tenant (metric cardinality); pools sharing a name add up
  and a freed pool gives its series back (pascal-db-faa 0.14.0's `PoolMetricsTests`).
- The cross-tenant checks of `tools/http_scenarios_tenants.sh` are the safety net: a change to
  the tenancy or to sample 03 runs them (`tools/test_http.sh`, CI).

### JWT signing keys

`PascalApi.JwtKeys` (pure, tested in `PascalApi.JwtKeysTests`): keys named by `kid`, so the
secret rotates without invalidating tokens. Design, phases and the user's decisions:
`docs/jwt-keys-design.md` (phase 1 done: the static ring; 2: generated keys in a database or
Redis store, done; 3: one ring per tenant, the tenant inside the `kid`, done).

- `src/redis` is outside the `.lpk`, as `src/horse` is: the core has no Redis code.
- The rotation runs on a request (no thread): a check that waits idle sees no rotation.
  `tools/http_scenarios_jwt_rotation.sh` runs sample 03 twice on one store (db, then Redis;
  `tools/test_http.sh` starts a throwaway Redis container when Docker is there).

- **Opt-in**: `TJwtMiddleware.New(ASecret)` and `TJwt.SignHS256(claims, secret)` don't change;
  sample 01 stays on them (its scenarios are the check). Sample 03 uses the ring.
- The `kid` is read before the signature is checked: input, never trust. It is looked up only
  in memory (never a query per unknown kid), and an unknown or retired kid answers the same
  401 as a bad signature.
- Error messages never contain a secret (`Parse_ErrorsNeverShowTheSecret`), nor a master key.
- Sealed secrets: `TSealedJwtKeyStore` + `TAesGcmSecretCipher` (`JWT_KEYS_MASTER_KEY`). The
  GCM's additional data is `jwt-key|<scope>|<kid>|<generation>`: keep it, or a sealed secret
  could be moved to another tenant's row. The AES is pascal-common-faa's; don't write another.
- Per tenant: `TTenantJwtKeyRing` (`PascalApi.Tenancy`). A key's `Scope` and the ring's
  `ScopeClaim` make `TJwtKeys.Decode` refuse a tenant's key on another tenant's claim. Rings
  only for the catalog's tenants and tenants that sign: never create one, or query anything,
  for the tenant a kid names.

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
  broken (4 of the 65 HTTP checks of the time, Delphi 12 Win32 and Win64; FPC was fine because its string is
  already UTF-8). The unit tests can't see this: only the HTTP scenarios on Delphi do.
- **When no route matches, Horse 3.3.12 runs the router twice** (the path, then `/*`:
  `Horse.Core.RouterTree`, `DoExecuteInternal`), so every global middleware runs twice for one
  request (only when every middleware called `Next`; one that answers, a 401 or a preflight,
  ends it). Seen in samples/02-db's log (two access lines for one `GET /`). `TLoggerMiddleware`,
  `TRateLimitMiddleware`, `TMetricsMiddleware` and `TCorsMiddleware` mark the request
  (`TPascalApiRequestState`) and run once: the limit counted it twice and sent its headers twice
  (measured 2026-10-14, `tools/http_scenarios_tenants.sh` checks it), and CORS sent
  `Access-Control-Allow-Origin` twice on a 404, which a browser refuses (measured 2026-10-18 on
  FPC and Delphi, `tools/http_scenarios.sh` checks it). A new global middleware that adds a
  header or has a side effect must do the same. JWT and the tenant middleware still run twice
  there (the same answer, only the cost). Horse's `THorse.AddOnRequest` hook runs once outside
  both passes, but an application registers the middlewares with `THorse.Use`, so the marks stay.
- **The client's address is `TClientAddress.Resolve`**, for the access log, the server span and
  the rate limit's default key: `TrustedClientIp` trusts `X-Forwarded-For` only from a loopback
  peer or the `TClientAddress.ProxyHops` proxies (one setting per process). Until 0.13.0 all three
  took the header's first address, which the client writes: a new value per request escaped the
  limit, and any address reached the log (both measured). The MCP executor forwards the chain as
  a proxy does (`ForwardedForChain`), so a tool call keeps its caller's address. Don't use
  `ClientIp` (first address) for anything new.
- **A middleware's exception never reaches `THorse.OnError` on FPC**: Horse 3.3.12's FPC router
  (`TRouterTreeExecutor.Run`) re-raises it, and fpWeb sent `500 text/html` with the message and
  stack addresses (measured 2026-10-14). `TLoggerMiddleware` catches it (`NextOrAnswer`) and
  answers through `HandleError`, so it must stay first; `/fail/middleware` in sample 01 is the
  check. A handler's exception goes to `OnError` on both compilers.
- **An internal mark on the request lives in `TPascalApiRequestState`**, which is kept in Horse's
  request scope (`THorseRequest.Services`, freed with the request): the logged/rate-limited/
  metered passes, the trace id, the tenant. Never in a request header: until 0.16.0 the marks
  were headers (`':pascalapi-logged'#10`), and "no client can send a name starting with ':'"
  was false: Indy (Delphi) kept a raw `:pascalapi-logged: 1` line and the logger skipped the
  request (measured on Delphi 12 Win32/Win64). `Services` keys by class name, so the class name
  stays unique. `tools/http_scenarios.sh` and `tools/http_scenarios_tenants.sh` still send such
  raw lines with a socket (curl won't) when the runner gives `SERVER_LOG`.
- **Observability** (`docs/observability-design.md`): the request id is the W3C trace id
  (`ResolveRequestTrace`, from pascal-common-faa's `PascalCommon.TraceContext`); metrics are
  pascal-common-faa's `PascalCommon.Metrics` (`PcMetrics`), named as OpenTelemetry names them;
  the contracts that the sibling libraries will need go to pascal-common-faa, not here.
- **`THorseRequest.MatchedRoute`** (the `http.route` label) is the deepest node the router
  visited, also on a partial match (`GET /cities/1/extra` left `/cities`), and `''` when a global
  middleware answered first (a 401 from JWT). `MetricRoute` drops a template whose segment count
  differs from the path. Never label a metric with the raw path.
- **Spans** are pascal-common-faa's `PascalCommon.Tracing` (`TPcTracing`, `IPcSpan`; they
  were `PascalApi.Tracing` here until 0.11.0, moved in phase D so pascal-db-faa, -redis-faa and
  -amqp-faa can join the trace). This repository keeps only the exporter (`PascalApi.Otlp`) and
  the spans it opens: the logger's server span (a handler's `TPcTracing.StartSpan` is its child)
  and the MCP executor's client span. Tracing tests live in pascal-common-faa; the current span
  is a per-thread pointer there. `TPcTracingOptions.FromEnvironment` reads only the process
  environment: pass `ReadAppConfig` (`PascalApi.Config`) to keep the `.env`. CI checks the spans
  with a real OpenTelemetry Collector (`tools/otlp_check.py`, including sample 02's database
  spans from pascal-db-faa); after changing the OTLP JSON, run `tools/ci-test.sh`.
- **Every metric needs a description**: `promtool check metrics` (run by CI on both samples'
  `/metrics`) exits non-zero on "no help text" even when the format is right. One lint is
  accepted on purpose, through `tools/promtool_check.sh`: the `_count` suffix of pascal-db-faa's
  `db_client_connection_count` (the OpenTelemetry name, kept by the user's decision). Don't widen
  that exception to other names without asking.
- **`THorseRequest.RemoteAddr` is '' with the console provider** (fpWeb on FPC, Indy on Delphi):
  only Horse's raw providers (Epoll, IOCP, HttpSys, Daemon, LCL) call `Populate` with it. Measured
  on FPC 3.2.2/Windows (the access log showed `-`) and on Delphi 12 Win32 (a probe, 2026-10-08);
  `RemoteAddrOf` falls back to `RawWebRequest.RemoteAddr`. The origin used `Req.RemoteAddr`
  directly, so its IP rate limit keyed every client as `unknown`: fixed there in
  delphi-api-infra-faa 0.4.1.

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
- **No `BoolToStr(B, 'a', 'b')`**: FPC has that overload, Delphi doesn't (`E2010`, sample 03
  compiled on FPC and stopped the Delphi build). Use an `if`.
- **Text that leaves the process is UTF-8, measured in bytes on both compilers** (`PascalApi.Text`).
  `Length` counts UTF-16 units on Delphi and bytes on FPC, so anything that cuts or sizes text
  for output (`TLogTruncate`) works on UTF-8 bytes and never splits a character.
- **A `finalization` needs an `initialization` before it on Delphi** (even empty); FPC accepts
  it alone, so only the Delphi build catches it (`PascalApi.Horse.Tenancy`).
- **Shared defaults are created in `initialization`, never lazily** (a lazy default raced in
  pascal-common-faa's `TClock`): `TAppConfig`'s reader and path, the `FileLog` instance, the
  MCP endpoints and the OpenAPI document.
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
exception in a helper and assert on what it returned. An interfaced object goes into an interface
variable (or a helper that returns one) before use: `TX.Create(...).Method`, or one passed to a
`const` parameter that doesn't keep it, is never freed (84 blocks in heaptrc, phase 2 of the JWT
keys). Non-ASCII test data used in an expression goes in a typed `string` constant (FPC warns
4104/4105 on a literal there).

| Command | What |
|---|---|
| `sh tools/test_fpc.sh` | regenerate mirrors, `lazbuild` + run the FPCUnit suite (Windows) |
| `sh tools/test_fpc_docker.sh` | the same suite with plain `fpc` on Linux (Docker, `FPC_IMAGE`) |
| `sh tools/test_http.sh` | build the three samples with lazbuild, start each, run `tools/http_scenarios.sh` / `tools/http_scenarios_db.sh` / `tools/http_scenarios_tenants.sh` (Windows; samples 02 and 03 need sqlite.org's `sqlite3.dll` in `SQLITE_DLL` or `.deps/`) |
| `sh tools/test_http_docker.sh` | the same on Linux with plain `fpc` (Docker; image needs curl and libsqlite3-0) |
| `sh tools/ci-test.sh` | what CI runs: unit suite + HTTP scenarios on Linux (builds the image if needed) |
| Delphi | open `PascalApi.groupproj`, build `PascalApi.UnitTests`, `ApiSample`, `DbApiSample` and `TenantApiSample` (Win32 and Win64); run the tests; start `ApiSample.exe` and run `sh tools/http_scenarios.sh 9310`; start `DbApiSample.exe 9330 --reset` and run `sh tools/http_scenarios_db.sh 9330`; start `TenantApiSample.exe 9350 --reset` and run `sh tools/http_scenarios_tenants.sh 9350` |

The middlewares are tested in two layers: their decisions in `PascalApi.HttpTests` (no server),
and over real HTTP by `tools/http_scenarios.sh` (curl, 190 checks) against `samples/01-api`,
which uses every middleware. In-process servers aren't used: on FPC, Horse's `Listen` blocks in
`THTTPApplication.Run` and there is no `StopListen`.

Sending non-ASCII bodies with curl from Git Bash on Windows: put them in a file with explicit
UTF-8 bytes (`printf 'Macei\303\263'`), since curl.exe gets its arguments in the ANSI code page.
The same for JSON unicode escapes (a backslash, `u` and four hex digits): a test that types them
on the command line may send something else (it did, 2026-10-15, and looked like a mapper bug
that wasn't there).

The samples set `TJsonMapper.Shared.UnknownMembers := umError` (an unknown member is a 400 with
its path). `ParseQueryInt(AName, AText)` answers 400 for anything but digits: never go back to
`TryStrToInt` (it wraps around on FPC 3.2.2 and reads `$3`/`0x3`/`+3`).

Acceptance on every side: 0 errors, 0 failures, 0 leaks (heaptrc / FastMM). Delphi Community
Edition can't build from the command line: the user builds in the IDE, then the executable
can be run from here (`tests/Unit/Win32/Debug/PascalApi.UnitTests.exe`).

Never pipe `lazbuild` into `head`/`Select-Object -First`: the compiler hangs when the pipe closes
(seen in pascal-dfe-broker). Redirect to a file, as the scripts do.

New unit checklist: unit in `src/`, test master in `tests/Unit/`, then add both to
`packages/pascal_api_infra_faa.lpk`, `tests/Unit/PascalApi.UnitTests.dpr` + `.dproj` and
`tests/Unit/fpc/PascalApiUnitTestsFpc.lpr`.
